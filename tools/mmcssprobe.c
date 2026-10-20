/* mmcssprobe.c: checks patch 0113 (WINE_MMCSS, MMCSS "Pro Audio" threads as Linux SCHED_FIFO threads) under Wine.
 *
 * A thread names itself (SetThreadDescription reaches /proc/.../comm), then registers for "Pro Audio", raises and
 * lowers its MMCSS priority, starts a child thread, and reverts. After each step the probe reads that thread's Linux
 * scheduling (policy, rt priority: fields 41 and 40 of /proc/<pid>/task/<tid>/stat) through Wine's Z: drive; Wine
 * opens files in the wineserver, so /proc/self would be the wineserver's, and the probe finds its own process by its
 * unix name instead. A "Games" registration must change nothing.
 *   With WINE_MMCSS set (base WINE_MMCSS_RTPRIO, default 10): FIFO base after registering, base+2 for CRITICAL,
 *   base-1 for LOW, the child not realtime (SCHED_RESET_ON_FORK), the starting policy again after the revert.
 *   Without it: the policy never changes (Wine's stubs).
 * Build: x86_64-w64-mingw32-gcc -O2 -Wall -o mmcssprobe.exe tools/mmcssprobe.c
 * Run:   WINE_MMCSS=1 wine mmcssprobe.exe      (exit 0 = PASS; the process needs RLIMIT_RTPRIO >= base + 2)
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef HANDLE (WINAPI *set_fn)(const WCHAR *, DWORD *);
typedef BOOL (WINAPI *prio_fn)(HANDLE, int);
typedef BOOL (WINAPI *revert_fn)(HANDLE);
typedef HRESULT (WINAPI *desc_fn)(HANDLE, const WCHAR *);

static set_fn set_chars;
static prio_fn set_prio;
static revert_fn revert;
static desc_fn set_desc;
static int failures;

static char proc_dir[64];   /* Z:\proc\<this process's unix pid> */

static int read_text(const char *path, char *buf, size_t size)
{
    FILE *f = fopen(path, "r");
    size_t n;

    if (!f) return 0;
    n = fread(buf, 1, size - 1, f);
    fclose(f);
    buf[n] = 0;
    buf[strcspn(buf, "\r\n")] = 0;
    return 1;
}

/* Wine opens files in the wineserver, so Z:\proc\self is the wineserver's: find this process by its unix name */
static int find_proc(void)
{
    WIN32_FIND_DATAA fd;
    HANDLE find = FindFirstFileA("Z:\\proc\\*", &fd);
    char path[MAX_PATH], buf[64];

    if (find == INVALID_HANDLE_VALUE) return 0;
    do
    {
        if (fd.cFileName[0] < '0' || fd.cFileName[0] > '9') continue;
        snprintf(path, sizeof(path), "Z:\\proc\\%s\\comm", fd.cFileName);
        if (read_text(path, buf, sizeof(buf)) && !_stricmp(buf, "mmcssprobe.exe"))
        {
            snprintf(proc_dir, sizeof(proc_dir), "Z:\\proc\\%s", fd.cFileName);
            snprintf(path, sizeof(path), "%s\\task\\*", proc_dir);
            {   /* the right one has the named worker thread */
                WIN32_FIND_DATAA td;
                HANDLE tfind = FindFirstFileA(path, &td);
                int mine = 0;
                if (tfind != INVALID_HANDLE_VALUE)
                {
                    do
                    {
                        char cpath[MAX_PATH];
                        if (td.cFileName[0] < '0' || td.cFileName[0] > '9') continue;
                        snprintf(cpath, sizeof(cpath), "%s\\task\\%s\\comm", proc_dir, td.cFileName);
                        mine = read_text(cpath, buf, sizeof(buf)) && !strcmp(buf, "mmcssprobe-w");
                    } while (!mine && FindNextFileA(tfind, &td));
                    FindClose(tfind);
                }
                if (mine) break;
            }
            proc_dir[0] = 0;
        }
    } while (FindNextFileA(find, &fd));
    FindClose(find);
    return proc_dir[0] != 0;
}

/* policy and rt priority of the thread whose comm is NAME, from /proc/<pid>/task/<tid>/stat */
static int read_sched(const char *name, int *policy, int *prio)
{
    WIN32_FIND_DATAA fd;
    HANDLE find;
    char pattern[MAX_PATH];
    int found = 0;

    if (!proc_dir[0] && !find_proc()) return 0;
    snprintf(pattern, sizeof(pattern), "%s\\task\\*", proc_dir);
    if ((find = FindFirstFileA(pattern, &fd)) == INVALID_HANDLE_VALUE) return 0;
    do
    {
        char path[MAX_PATH], buf[1024];
        FILE *f;
        size_t n;

        if (fd.cFileName[0] < '0' || fd.cFileName[0] > '9') continue;
        snprintf(path, sizeof(path), "%s\\task\\%s\\comm", proc_dir, fd.cFileName);
        if (!(f = fopen(path, "r"))) continue;
        n = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);
        buf[n] = 0;
        buf[strcspn(buf, "\r\n")] = 0;
        if (strcmp(buf, name)) continue;
        snprintf(path, sizeof(path), "%s\\task\\%s\\stat", proc_dir, fd.cFileName);
        if (!(f = fopen(path, "r"))) continue;
        n = fread(buf, 1, sizeof(buf) - 1, f);
        fclose(f);
        buf[n] = 0;
        {
            char *p = strrchr(buf, ')');
            int field = 2;   /* the comm field ends at the last ')' */
            if (!p) continue;
            for (p++; *p && field < 41; )
            {
                while (*p == ' ') p++;
                field++;
                if (field == 40) *prio = atoi(p);
                if (field == 41) *policy = atoi(p);
                while (*p && *p != ' ') p++;
            }
            found = field >= 41;
        }
    } while (!found && FindNextFileA(find, &fd));
    FindClose(find);
    return found;
}

static void check(const char *step, const char *name, int want_policy, int want_prio)
{
    int policy = -1, prio = -1;

    if (!read_sched(name, &policy, &prio))
    {
        printf("FAIL %-34s thread %s not found in /proc/self/task\n", step, name);
        failures++;
        return;
    }
    if ((policy & 0xff) != want_policy || prio != want_prio)
    {
        printf("FAIL %-34s policy %d priority %d, expected %d / %d\n", step, policy & 0xff, prio, want_policy, want_prio);
        failures++;
    }
    else
        printf("ok   %-34s policy %d priority %d\n", step, policy & 0xff, prio);
}

static int rt, base;
static int start_policy, start_prio;

static DWORD WINAPI child(void *arg)
{
    set_desc(GetCurrentThread(), L"mmcssprobe-c");
    Sleep(200);
    return 0;
}

static DWORD WINAPI worker(void *arg)
{
    DWORD index = 0;
    HANDLE h, games, kid;

    set_desc(GetCurrentThread(), L"mmcssprobe-w");
    Sleep(50);
    if (!read_sched("mmcssprobe-w", &start_policy, &start_prio))
    {
        printf("FAIL the probe thread is not in /proc/self/task (thread names do not reach comm?)\n");
        failures++;
        return 1;
    }
    printf("     starting scheduling: policy %d priority %d\n", start_policy & 0xff, start_prio);

    games = set_chars(L"Games", &index);
    check("register \"Games\" (no change)", "mmcssprobe-w", start_policy & 0xff, start_prio);
    revert(games);

    h = set_chars(L"Pro Audio", &index);
    if (!h)
    {
        printf("FAIL AvSetMmThreadCharacteristicsW(\"Pro Audio\") returned NULL (error %lu)\n", GetLastError());
        failures++;
        return 1;
    }
    check("register \"Pro Audio\"", "mmcssprobe-w", rt ? 1 : start_policy & 0xff, rt ? base : start_prio);
    set_prio(h, 2);
    check("AvSetMmThreadPriority CRITICAL", "mmcssprobe-w", rt ? 1 : start_policy & 0xff, rt ? base + 2 : start_prio);
    set_prio(h, -1);
    check("AvSetMmThreadPriority LOW", "mmcssprobe-w", rt ? 1 : start_policy & 0xff, rt ? base - 1 : start_prio);

    kid = CreateThread(NULL, 0, child, NULL, 0, NULL);
    Sleep(100);
    /* with WINE_MMCSS the registered thread has SCHED_RESET_ON_FORK: a thread it starts comes up normal, also under
     * the launcher's chrt; without it the child inherits the starting policy */
    check("a thread it starts (not realtime)", "mmcssprobe-c", rt ? 0 : start_policy & 0xff, rt ? 0 : start_prio);
    WaitForSingleObject(kid, INFINITE);
    CloseHandle(kid);

    revert(h);
    check("AvRevertMmThreadCharacteristics", "mmcssprobe-w", start_policy & 0xff, start_prio);
    return 0;
}

int main(void)
{
    HMODULE avrt = LoadLibraryA("avrt.dll"), k32 = GetModuleHandleA("kernel32.dll");
    char value[16];
    HANDLE t;

    if (!avrt || !k32)
    {
        printf("FAIL avrt.dll or kernel32.dll not loaded\n");
        return 2;
    }
    set_chars = (set_fn)GetProcAddress(avrt, "AvSetMmThreadCharacteristicsW");
    set_prio = (prio_fn)GetProcAddress(avrt, "AvSetMmThreadPriority");
    revert = (revert_fn)GetProcAddress(avrt, "AvRevertMmThreadCharacteristics");
    set_desc = (desc_fn)GetProcAddress(k32, "SetThreadDescription");
    if (!set_chars || !set_prio || !revert || !set_desc)
    {
        printf("FAIL missing exports\n");
        return 2;
    }
    rt = GetEnvironmentVariableA("WINE_MMCSS", value, sizeof(value)) > 0 &&
         (!strcmp(value, "1") || !_stricmp(value, "true") || !_stricmp(value, "yes") || !_stricmp(value, "on"));
    base = GetEnvironmentVariableA("WINE_MMCSS_RTPRIO", value, sizeof(value)) > 0 ? atoi(value) : 10;
    if (base < 1 || base > 98) base = 10;
    printf("mmcssprobe: WINE_MMCSS %s, base %d\n", rt ? "set" : "unset (expect no change)", base);

    t = CreateThread(NULL, 0, worker, NULL, 0, NULL);
    WaitForSingleObject(t, INFINITE);
    CloseHandle(t);
    printf("%s (%d failure%s)\n", failures ? "FAIL" : "PASS", failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
