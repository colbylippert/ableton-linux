// live-idle-guard: while Ableton Live runs, Windows' "processor idle state maximum" (IDLESTATEMAX) is 1, so the
// cores idle no deeper than C1; the previous value comes back when Live exits. It is the Windows half of T0031
// (profiler/plans/kernel-plan.md). The other half, C1E off, has no Windows setting and needs a kernel driver to write
// the register, so GRUB turns it off before Windows starts (profiler/kernel/grub/46_profiler-c1e-off). Without C1E
// off, C1 still drops the core's voltage and clock (D0008), so the two belong together.
//
// A Windows service (no window, from boot, restarted on failure) that polls for Live once a second:
//   live-idle-guard install     register the service (LiveIdleGuard, automatic start) and start it; --manual for
//                               demand start
//   live-idle-guard uninstall   stop it (the saved value is restored) and remove it
//   live-idle-guard status      the active scheme's IDLESTATEMAX (AC, DC), whether Live runs, the service's state
//   live-idle-guard run         the same watcher in the foreground, until Ctrl+C
// The values it replaced are kept in %ProgramData%\LiveIdleGuard\state.txt until restored, so a killed instance's
// change is undone at the next start; the log is %ProgramData%\LiveIdleGuard\live-idle-guard.log.
// Build: profiler/windows/live-idle-guard/build.sh (mingw-w64, static).
#include <windows.h>
#include <powrprof.h>
#include <tlhelp32.h>

#include <cstdarg>
#include <cstdio>
#include <cwchar>

namespace {

const GUID kSubProcessor = {0x54533251, 0x82be, 0x4824, {0x96, 0xc1, 0x47, 0xb6, 0x0b, 0x74, 0x0d, 0x00}};
const GUID kIdleStateMax = {0x9943e905, 0x9a30, 0x4ec1, {0x9b, 0x99, 0x44, 0xdd, 0x3b, 0x76, 0xf7, 0xa2}};
const wchar_t kServiceName[] = L"LiveIdleGuard";
const DWORD kLiveIdleStateMax = 1;  // C1

SERVICE_STATUS_HANDLE g_status_handle = nullptr;
SERVICE_STATUS g_status = {};
HANDLE g_stop = nullptr;
wchar_t g_dir[MAX_PATH];

void init_dir() {
    DWORD n = GetEnvironmentVariableW(L"ProgramData", g_dir, MAX_PATH);
    if (n == 0 || n >= MAX_PATH - 20) wcscpy(g_dir, L"C:\\ProgramData");
    wcscat(g_dir, L"\\LiveIdleGuard");
    CreateDirectoryW(g_dir, nullptr);
}

void path_of(const wchar_t *name, wchar_t *out) { _snwprintf(out, MAX_PATH, L"%ls\\%ls", g_dir, name); }

void log(const char *fmt, ...) {
    wchar_t path[MAX_PATH];
    path_of(L"live-idle-guard.log", path);
    FILE *f = _wfopen(path, L"a");
    if (!f) return;
    SYSTEMTIME t;
    GetLocalTime(&t);
    fprintf(f, "%04u-%02u-%02u %02u:%02u:%02u ", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

bool live_running() {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return false;
    PROCESSENTRY32W e = {};
    e.dwSize = sizeof e;
    bool found = false;
    for (BOOL ok = Process32FirstW(snap, &e); ok && !found; ok = Process32NextW(snap, &e)) {
        size_t n = wcslen(e.szExeFile);
        found = _wcsnicmp(e.szExeFile, L"Ableton Live", 12) == 0 && n > 4 && _wcsicmp(e.szExeFile + n - 4, L".exe") == 0;
    }
    CloseHandle(snap);
    return found;
}

bool active_scheme(GUID *scheme) {
    GUID *p = nullptr;
    if (PowerGetActiveScheme(nullptr, &p) != ERROR_SUCCESS) return false;
    *scheme = *p;
    LocalFree(p);
    return true;
}

bool read_value(const GUID &scheme, DWORD *ac, DWORD *dc) {
    return PowerReadACValueIndex(nullptr, &scheme, &kSubProcessor, &kIdleStateMax, ac) == ERROR_SUCCESS &&
           PowerReadDCValueIndex(nullptr, &scheme, &kSubProcessor, &kIdleStateMax, dc) == ERROR_SUCCESS;
}

bool write_value(const GUID &scheme, DWORD ac, DWORD dc) {
    DWORD e1 = PowerWriteACValueIndex(nullptr, &scheme, &kSubProcessor, &kIdleStateMax, ac);
    DWORD e2 = PowerWriteDCValueIndex(nullptr, &scheme, &kSubProcessor, &kIdleStateMax, dc);
    DWORD e3 = PowerSetActiveScheme(nullptr, &scheme);  // a changed value of the active scheme takes effect on re-apply
    if (e1 || e2 || e3) log("write IDLESTATEMAX %lu/%lu failed: %lu %lu %lu", ac, dc, e1, e2, e3);
    return !(e1 || e2 || e3);
}

struct Saved {
    GUID scheme;
    DWORD ac, dc;
};

bool save_state(const Saved &s) {
    wchar_t path[MAX_PATH];
    path_of(L"state.txt", path);
    FILE *f = _wfopen(path, L"wb");
    if (!f) return false;
    bool ok = fwrite(&s, sizeof s, 1, f) == 1;
    fclose(f);
    return ok;
}

bool load_state(Saved *s) {
    wchar_t path[MAX_PATH];
    path_of(L"state.txt", path);
    FILE *f = _wfopen(path, L"rb");
    if (!f) return false;
    bool ok = fread(s, sizeof *s, 1, f) == 1;
    fclose(f);
    return ok;
}

void clear_state() {
    wchar_t path[MAX_PATH];
    path_of(L"state.txt", path);
    DeleteFileW(path);
}

// The watcher: apply while Live runs, restore when it exits or when stop is signalled.
void watch(HANDLE stop) {
    Saved saved = {};
    bool applied = load_state(&saved);  // an earlier instance died with the change in place
    if (applied) log("found a saved value (%lu/%lu) from an earlier run", saved.ac, saved.dc);
    log("watching for Ableton Live");
    for (;;) {
        bool live = live_running();
        if (live && !applied) {
            DWORD ac = 0, dc = 0;
            if (active_scheme(&saved.scheme) && read_value(saved.scheme, &ac, &dc)) {
                saved.ac = ac;
                saved.dc = dc;
                save_state(saved);
                if (write_value(saved.scheme, kLiveIdleStateMax, kLiveIdleStateMax)) {
                    applied = true;
                    log("Live started: IDLESTATEMAX %lu/%lu -> %lu (C1 only)", ac, dc, kLiveIdleStateMax);
                } else {
                    clear_state();
                }
            } else {
                log("could not read the active scheme's IDLESTATEMAX");
            }
        } else if (!live && applied) {
            if (write_value(saved.scheme, saved.ac, saved.dc)) {
                clear_state();
                applied = false;
                log("Live exited: IDLESTATEMAX restored to %lu/%lu", saved.ac, saved.dc);
            }
        }
        if (WaitForSingleObject(stop, 1000) == WAIT_OBJECT_0) break;
    }
    if (applied && write_value(saved.scheme, saved.ac, saved.dc)) {
        clear_state();
        log("stopping: IDLESTATEMAX restored to %lu/%lu", saved.ac, saved.dc);
    }
    log("stopped");
}

void set_status(DWORD state) {
    g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;
    g_status.dwCurrentState = state;
    g_status.dwControlsAccepted = state == SERVICE_RUNNING ? SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN : 0;
    g_status.dwWaitHint = state == SERVICE_RUNNING || state == SERVICE_STOPPED ? 0 : 5000;
    SetServiceStatus(g_status_handle, &g_status);
}

void WINAPI ctrl_handler(DWORD ctrl) {
    if (ctrl == SERVICE_CONTROL_STOP || ctrl == SERVICE_CONTROL_SHUTDOWN) {
        set_status(SERVICE_STOP_PENDING);
        SetEvent(g_stop);
    }
}

void WINAPI service_main(DWORD, LPWSTR *) {
    g_status_handle = RegisterServiceCtrlHandlerW(kServiceName, ctrl_handler);
    if (!g_status_handle) return;
    g_stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    set_status(SERVICE_RUNNING);
    watch(g_stop);
    set_status(SERVICE_STOPPED);
}

BOOL WINAPI console_handler(DWORD) {
    SetEvent(g_stop);
    return TRUE;
}

int install(bool manual) {
    wchar_t exe[MAX_PATH], cmd[MAX_PATH + 2];
    GetModuleFileNameW(nullptr, exe, MAX_PATH);
    _snwprintf(cmd, MAX_PATH + 2, L"\"%ls\"", exe);
    SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CREATE_SERVICE);
    if (!scm) { wprintf(L"open the service manager: error %lu (run as administrator)\n", GetLastError()); return 1; }
    SC_HANDLE svc = CreateServiceW(scm, kServiceName, L"Live idle guard (C1 idle while Ableton Live runs)",
                                   SERVICE_ALL_ACCESS, SERVICE_WIN32_OWN_PROCESS,
                                   manual ? SERVICE_DEMAND_START : SERVICE_AUTO_START, SERVICE_ERROR_NORMAL, cmd,
                                   nullptr, nullptr, nullptr, nullptr, nullptr);
    if (!svc) { wprintf(L"create the service: error %lu\n", GetLastError()); CloseServiceHandle(scm); return 1; }
    SERVICE_DESCRIPTIONW desc = {(LPWSTR)L"Sets Windows' processor idle state maximum to C1 while Ableton Live runs "
                                         L"and restores it after (ableton-linux profiler, T0031)."};
    ChangeServiceConfig2W(svc, SERVICE_CONFIG_DESCRIPTION, &desc);
    SC_ACTION restart[3] = {{SC_ACTION_RESTART, 5000}, {SC_ACTION_RESTART, 5000}, {SC_ACTION_RESTART, 5000}};
    SERVICE_FAILURE_ACTIONSW fa = {86400, nullptr, nullptr, 3, restart};
    ChangeServiceConfig2W(svc, SERVICE_CONFIG_FAILURE_ACTIONS, &fa);
    bool started = StartServiceW(svc, 0, nullptr);
    wprintf(L"installed %ls (%ls start)%ls\n", kServiceName, manual ? L"demand" : L"automatic", started ? L" and started" : L"");
    CloseServiceHandle(svc);
    CloseServiceHandle(scm);
    return 0;
}

int uninstall() {
    SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    SC_HANDLE svc = scm ? OpenServiceW(scm, kServiceName, SERVICE_STOP | SERVICE_QUERY_STATUS | DELETE) : nullptr;
    if (!svc) { wprintf(L"open %ls: error %lu\n", kServiceName, GetLastError()); if (scm) CloseServiceHandle(scm); return 1; }
    SERVICE_STATUS st;
    if (ControlService(svc, SERVICE_CONTROL_STOP, &st)) {
        for (int i = 0; i < 100 && QueryServiceStatus(svc, &st) && st.dwCurrentState != SERVICE_STOPPED; i++) Sleep(100);
    }
    bool ok = DeleteService(svc);
    wprintf(ok ? L"removed %ls\n" : L"remove %ls: error %lu\n", kServiceName, GetLastError());
    CloseServiceHandle(svc);
    CloseServiceHandle(scm);
    return ok ? 0 : 1;
}

int status() {
    GUID scheme;
    DWORD ac = 0, dc = 0;
    if (active_scheme(&scheme) && read_value(scheme, &ac, &dc))
        wprintf(L"active scheme IDLESTATEMAX: AC %lu, DC %lu (0 = no limit, 1 = C1)\n", ac, dc);
    else
        wprintf(L"could not read IDLESTATEMAX\n");
    wprintf(L"Ableton Live running: %ls\n", live_running() ? L"yes" : L"no");
    const wchar_t *state = L"not installed";
    SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    SC_HANDLE svc = scm ? OpenServiceW(scm, kServiceName, SERVICE_QUERY_STATUS) : nullptr;
    SERVICE_STATUS st;
    if (svc && QueryServiceStatus(svc, &st))
        state = st.dwCurrentState == SERVICE_RUNNING ? L"running" : st.dwCurrentState == SERVICE_STOPPED ? L"stopped" : L"changing";
    if (svc) CloseServiceHandle(svc);
    if (scm) CloseServiceHandle(scm);
    wprintf(L"service %ls: %ls\n", kServiceName, state);
    Saved s;
    if (load_state(&s)) wprintf(L"saved value to restore: AC %lu, DC %lu\n", s.ac, s.dc);
    return 0;
}

}  // namespace

int wmain(int argc, wchar_t **argv) {
    init_dir();
    if (argc < 2) {
        SERVICE_TABLE_ENTRYW table[] = {{(LPWSTR)kServiceName, service_main}, {nullptr, nullptr}};
        if (!StartServiceCtrlDispatcherW(table)) {
            wprintf(L"usage: live-idle-guard install [--manual] | uninstall | status | run\n");
            return 2;
        }
        return 0;
    }
    if (!wcscmp(argv[1], L"install")) return install(argc > 2 && !wcscmp(argv[2], L"--manual"));
    if (!wcscmp(argv[1], L"uninstall")) return uninstall();
    if (!wcscmp(argv[1], L"status")) return status();
    if (!wcscmp(argv[1], L"run")) {
        g_stop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        SetConsoleCtrlHandler(console_handler, TRUE);
        wprintf(L"watching for Ableton Live (log: %ls\\live-idle-guard.log); Ctrl+C stops and restores\n", g_dir);
        watch(g_stop);
        return 0;
    }
    wprintf(L"usage: live-idle-guard install [--manual] | uninstall | status | run\n");
    return 2;
}
