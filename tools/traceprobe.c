/* traceprobe.c validates the Wine interface tracer (profiler/tracer, design B
 * section 7). Each phase makes a fixed number of calls of one kind on the main
 * thread; the probe then prints what the tracer must have counted for its
 * threads, so profiler/tracer/validate.py can compare the tracer's output with
 * a known call mix.
 *
 * Phases (default counts; --scale K multiplies phases 1, 2, 3 and 6):
 *   phase1  NtYieldExecution x100              syscall 0x0046; status 0 or
 *                                              STATUS_NO_YIELD_PERFORMED
 *   phase2  QueryPerformanceCounter x200       syscall 0x0031 (11.13 always
 *                                              syscalls; may become user-mode
 *                                              in a later Wine)
 *   phase3  CreateEventW + CloseHandle x50     NtCreateEvent enclosing one
 *                                              create_event request; NtClose
 *                                              enclosing one close_handle
 *   phase4  WaitForSingleObject(ev, 10 ms) x20 NtWaitForSingleObject enclosing
 *           on an unsignaled event             an ntsync WAIT_ANY that times out
 *                                              (-ETIMEDOUT); the first wait
 *                                              fetches get_inproc_sync_fd
 *   phase5  helper thread SetEvent x20 while   20 ntsync EVENT_SET from the
 *           the main thread waits              helper tid; 20 main-thread waits
 *                                              ending 0 with woken_by == helper
 *   phase6  SCardEstablishContext x10          10 unix calls into winscard.so
 *                                              (SKIP when winscard.dll is absent)
 *           GetGlyphIndices x20 +              GetGlyphIndices is served by the
 *           GetDesignGlyphMetrics x20          PE-side cmap; GetDesignGlyphMetrics
 *                                              makes one unix call into dwrite.so
 *                                              per uncached glyph (plus one lazy
 *                                              create_font_object)
 *   phase7  SleepEx(1, TRUE) x10               NtDelayExecution enclosing a
 *                                              server_wait (default route) or an
 *                                              ntsync WAIT_ANY with count=0
 *                                              (WINE_APC_FASTPATH on)
 *
 * Output (traceprobe.txt and standard output): PASS, FAIL, SKIP, info and
 * SUMMARY lines as in apcprobe, plus
 *
 *   EXPECT <kind> <id> <op> <n> [thread=helper]
 *       kind: syscall | server_req | ntsync_wait | ntsync_wake | unixcall |
 *             server_wait
 *       id:   syscall name, server request name, WAIT_ANY, EVENT_SET, the
 *             unix library (winscard.so, dwrite.so) or, for server_wait, the
 *             name of the enclosing syscall (NtDelayExecution)
 *       op:   eq (the tracer must have counted exactly n) or ge (at least n)
 *       The line applies to the main thread unless it ends in thread=helper.
 *       Counts cover the calls made after the settle point (see --settle);
 *       calls made before it (DLL loading, DirectWrite setup, thread naming,
 *       the /proc scan) are reported on the "info presettle" line only.
 *   TID <main windows tid> pid=<windows pid> helper=<helper windows tid>
 *       linux_pid=<n|?> linux_tid=<n|?> linux_helper_tid=<n|?>
 *       comm=traceprobe-main helper_comm=traceprobe-help
 *       The final line. Windows ids come from GetCurrentThreadId and
 *       GetCurrentProcessId. The Linux ids are found by naming the thread
 *       (SetThreadDescription, which Wine 11.13 writes to
 *       /proc/PID/task/TID/comm) and scanning \\?\unix\proc for that comm;
 *       they print as ? when the scan is unavailable (--no-procscan, no
 *       \\?\unix namespace, or a stale name). The same ids are printed early
 *       on an "info ids" line so a wrapper can attach the tracer during the
 *       settle period.
 *
 * Options:
 *   --settle MS     spin (no syscalls) for MS milliseconds after printing the
 *                   "info ids" line, so the tracer can attach with no wait in
 *                   flight; a wait in flight at attach time would surface as
 *                   an unmatched syscall_exit
 *   --only N        run phase N (1-7) only; the other EXPECT lines then report
 *                   0 calls
 *   --scale K       multiply the call counts of phases 1, 2, 3 and 6 by K
 *   --sleep-ms N    SleepEx duration for phase 7 (default 1)
 *   --no-procscan   skip the /proc scan (Linux ids print as ?)
 *   --help          print the usage and exit 0
 *
 * The exit code gives the FAIL count. The probe is a plain PE without a CRT:
 * only kernel32, user32 and ntdll are linked; winscard.dll and dwrite.dll are
 * loaded at run time and their absence is a SKIP, not a failure.
 *
 * Build with build_traceprobe.sh in the current directory. Run inside the
 * Ableton prefix with: tools/run_in_prefix.sh traceprobe.exe [--settle 3000]
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
/* wingdi.h maps the GDI name GetGlyphIndices to its A/W variants; the probe
 * uses the name only for the DirectWrite vtable slot below. */
#undef GetGlyphIndices

/* Manual declarations provide the ntdll entries used by the probe.
 * LONG supplies the NTSTATUS type for the direct entry points. */
#define STATUS_NO_YIELD_PERFORMED ((LONG)0x40000024)
LONG WINAPI NtYieldExecution( void );
LONG WINAPI NtQueryPerformanceCounter( LARGE_INTEGER *counter, LARGE_INTEGER *frequency );

static HANDLE g_out, g_con;
static char   buf[1024];
static int    g_pass, g_fail, g_skip;

static void emit( const char *s )
{
    DWORD n;
    if (g_out) WriteFile( g_out, s, lstrlenA(s), &n, NULL );
    if (g_con) WriteFile( g_con, s, lstrlenA(s), &n, NULL );
}
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)
#define CHECK(cond, name) do { if (cond) { g_pass++; P( "PASS %s\n", name ); } \
                               else { g_fail++; P( "FAIL %s (line %d, lasterr %u)\n", name, __LINE__, (UINT)GetLastError() ); } } while (0)
#define SKIP(name, why) do { g_skip++; P( "SKIP %s: %s (lasterr %u)\n", name, why, (UINT)GetLastError() ); } while (0)

/* Options. */
static UINT g_only;            /* 0 runs every phase */
static UINT g_scale = 1;
static UINT g_settle_ms;
static UINT g_sleep_ms = 1;
static int  g_no_procscan;

/* Call counters. Every call that an EXPECT line describes goes through a
 * counting wrapper; the counters restart at the settle point. */
static UINT g_c_yield, g_c_qpc, g_c_create_event, g_c_close, g_c_wait_single,
            g_c_event_wait, g_c_set_event, g_c_delay, g_c_scard, g_c_dwrite,
            g_c_helper_set, g_c_helper_wait;
static LONGLONG g_qpc_freq;

/* Identity. */
static UINT g_winpid, g_wintid, g_helper_wintid;
static UINT g_linux_pid, g_linux_tid, g_linux_helper_tid;
static int  g_procscan_ok;
static const char  main_commA[]   = "traceprobe-main";   /* 15 chars: the comm limit */
static const WCHAR main_commW[]   = L"traceprobe-main";
static const char  helper_commA[] = "traceprobe-help";
static const WCHAR helper_commW[] = L"traceprobe-help";

/* Environment. */
static int  g_fastpath;        /* WINE_APC_FASTPATH parsed like dlls/ntdll/unix/sync.c */
static int  g_fastpath_set;
static char g_fastpath_val[64];

/* Timing goes through NtQueryPerformanceCounter directly: one syscall per call,
 * which also returns the frequency, so the QPC count stays exact. */
static LONGLONG ticks( void )
{
    LARGE_INTEGER c, f;
    NtQueryPerformanceCounter( &c, &f );
    g_c_qpc++;
    g_qpc_freq = f.QuadPart;
    return c.QuadPart;
}

static UINT ticks_to_ms( LONGLONG dt )
{
    if (g_qpc_freq <= 0) return 0;
    return (UINT)(dt * 1000 / g_qpc_freq);
}

static UINT ns_per_call( LONGLONG dt, UINT n )
{
    if (g_qpc_freq <= 0 || !n) return 0;
    return (UINT)(dt * 1000000000 / g_qpc_freq / n);
}

/* Counting wrappers. */
static HANDLE probe_create_event( void )
{
    g_c_create_event++;
    return CreateEventW( NULL, FALSE, FALSE, NULL );
}

static BOOL probe_close( HANDLE h )
{
    g_c_close++;
    return CloseHandle( h );
}

static DWORD probe_wait( HANDLE h, DWORD ms, int is_event )
{
    g_c_wait_single++;
    if (is_event) g_c_event_wait++;
    return WaitForSingleObject( h, ms );
}

static BOOL probe_set_event( HANDLE h )
{
    g_c_set_event++;
    return SetEvent( h );
}

static void reset_counters( void )
{
    g_c_yield = g_c_qpc = g_c_create_event = g_c_close = g_c_wait_single = 0;
    g_c_event_wait = g_c_set_event = g_c_delay = g_c_scard = g_c_dwrite = 0;
    g_c_helper_set = g_c_helper_wait = 0;
}

/* Spin without any syscall: GetTickCount reads the shared user data page. */
static void spin_ms( UINT ms )
{
    DWORD t0 = GetTickCount();
    while (GetTickCount() - t0 < ms) YieldProcessor();
}

/* Command line: tokens separated by blanks, no quoting beyond the program name. */
static int tok_eq( const char *tok, const char *name )
{
    int i;
    for (i = 0; name[i]; i++) if (tok[i] != name[i]) return 0;
    return tok[i] == 0 || tok[i] == ' ' || tok[i] == '\t';
}

static const char *next_tok( const char *s )
{
    while (*s && *s != ' ' && *s != '\t') s++;
    while (*s == ' ' || *s == '\t') s++;
    return s;
}

/* Return the token after name, "" when name is the last token, NULL when absent. */
static const char *find_opt( const char *name )
{
    const char *s = GetCommandLineA();
    if (*s == '"')
    {
        s++;
        while (*s && *s != '"') s++;
        if (*s) s++;
    }
    s = next_tok( s );
    while (*s)
    {
        if (tok_eq( s, name )) return next_tok( s );
        s = next_tok( s );
    }
    return NULL;
}

static UINT parse_uint( const char *s )
{
    UINT v = 0;
    while (*s >= '0' && *s <= '9') v = v * 10 + (UINT)(*s++ - '0');
    return v;
}

static int opt_uint( const char *name, UINT *out )
{
    const char *v = find_opt( name );
    if (!v) return 0;
    if (*v < '0' || *v > '9') return -1;
    *out = parse_uint( v );
    return 1;
}

static void usage( void )
{
    emit( "usage: traceprobe.exe [--settle MS] [--only N] [--scale K] [--sleep-ms N] [--no-procscan] [--help]\n"
          "  --settle MS    spin MS ms after the \"info ids\" line so the tracer can attach\n"
          "  --only N       run phase N (1-7) only\n"
          "  --scale K      multiply the call counts of phases 1, 2, 3 and 6 by K\n"
          "  --sleep-ms N   SleepEx duration for phase 7 (default 1)\n"
          "  --no-procscan  do not look up the Linux pid/tid through \\\\?\\unix\\proc\n"
          "Prints PASS/FAIL/SKIP/info/SUMMARY lines, EXPECT lines for validate.py and a final TID line;\n"
          "the exit code is the FAIL count.\n" );
}

/* Thread naming: resolved at run time so the import table stays kernel32-only. */
typedef HRESULT (WINAPI *SETTHREADDESC)( HANDLE, PCWSTR );
static SETTHREADDESC pSetThreadDescription;

static void name_current_thread( const WCHAR *name )
{
    if (pSetThreadDescription) pSetThreadDescription( GetCurrentThread(), name );
}

/* /proc scan through the \??\unix namespace. Opening a file goes through
 * wineserver, so /proc/self would name wineserver; the probe instead names its
 * thread and looks for that comm. */
static int all_digits_w( const WCHAR *s )
{
    if (!*s) return 0;
    for (; *s; s++) if (*s < '0' || *s > '9') return 0;
    return 1;
}

static UINT parse_uint_w( const WCHAR *s )
{
    UINT v = 0;
    while (*s >= '0' && *s <= '9') v = v * 10 + (UINT)(*s++ - '0');
    return v;
}

/* Read a small text file and drop the trailing newline. */
static BOOL read_small_file( const WCHAR *path, char *out, DWORD cap )
{
    HANDLE h;
    DWORD n = 0;

    h = CreateFileW( path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                     NULL, OPEN_EXISTING, 0, NULL );
    if (h == INVALID_HANDLE_VALUE) return FALSE;
    if (!ReadFile( h, out, cap - 1, &n, NULL )) n = 0;
    probe_close( h );
    while (n && (out[n - 1] == '\n' || out[n - 1] == '\r')) n--;
    out[n] = 0;
    return TRUE;
}

/* Return the first numeric entry of dir whose comm file equals name, or 0. */
static UINT scan_comm_dir( const WCHAR *dir, const char *name )
{
    WIN32_FIND_DATAW fd;
    WCHAR pattern[160], path[224];
    char comm[64];
    HANDLE h;
    UINT found = 0;
    DWORD t0 = GetTickCount();

    wsprintfW( pattern, L"%s\\*", dir );
    h = FindFirstFileW( pattern, &fd );
    if (h == INVALID_HANDLE_VALUE) return 0;
    do
    {
        if (!(fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || !all_digits_w( fd.cFileName )) continue;
        wsprintfW( path, L"%s\\%s\\comm", dir, fd.cFileName );
        if (read_small_file( path, comm, sizeof(comm) ) && !lstrcmpA( comm, name ))
        {
            found = parse_uint_w( fd.cFileName );
            break;
        }
    } while (GetTickCount() - t0 < 8000 && FindNextFileW( h, &fd ));
    FindClose( h );
    return found;
}

/* Find the probe's Linux pid: name the main thread uniquely, find the process
 * whose leader comm carries that name, then give the thread its final name. */
static void find_linux_ids( void )
{
    WCHAR tmpW[32];
    char tmpA[32];

    if (g_no_procscan || !pSetThreadDescription) return;
    wsprintfA( tmpA, "tp%u.%u", g_winpid, g_wintid );
    wsprintfW( tmpW, L"tp%u.%u", g_winpid, g_wintid );
    name_current_thread( tmpW );
    g_linux_pid = scan_comm_dir( L"\\\\?\\unix\\proc", tmpA );
    g_linux_tid = g_linux_pid;   /* the thread group leader runs the PE entry point */
    g_procscan_ok = g_linux_pid != 0;
}

static void find_linux_helper_tid( void )
{
    WCHAR dir[96];
    if (!g_procscan_ok) return;
    wsprintfW( dir, L"\\\\?\\unix\\proc\\%u\\task", g_linux_pid );
    g_linux_helper_tid = scan_comm_dir( dir, helper_commA );
}

static void print_ids( const char *tag )
{
    P( "%s %u pid=%u helper=%u ", tag, g_wintid, g_winpid, g_helper_wintid );
    if (g_linux_pid) P( "linux_pid=%u linux_tid=%u ", g_linux_pid, g_linux_tid );
    else emit( "linux_pid=? linux_tid=? " );
    if (g_linux_helper_tid) P( "linux_helper_tid=%u ", g_linux_helper_tid );
    else emit( "linux_helper_tid=? " );
    P( "comm=%s helper_comm=%s\n", main_commA, helper_commA );
}

/* WINE_APC_FASTPATH selects the ntsync alert wait for alertable delays; parse
 * it the way dlls/ntdll/unix/sync.c does ("1", "on", "true", "yes", any case). */
static void read_fastpath_env( void )
{
    DWORD n = GetEnvironmentVariableA( "WINE_APC_FASTPATH", g_fastpath_val, sizeof(g_fastpath_val) );
    if (!n || n >= sizeof(g_fastpath_val)) return;
    g_fastpath_set = 1;
    g_fastpath = !lstrcmpiA( g_fastpath_val, "1" ) || !lstrcmpiA( g_fastpath_val, "on" ) ||
                 !lstrcmpiA( g_fastpath_val, "true" ) || !lstrcmpiA( g_fastpath_val, "yes" );
}

/* Phase 6 entry points. winscard.dll and dwrite.dll are loaded at run time and
 * before the settle point, so their DllMain syscalls and the DirectWrite
 * font-collection build stay outside the traced window. */
typedef LONG (WINAPI *SCARDESTABLISH)( DWORD, const void *, const void *, ULONG_PTR * );
typedef LONG (WINAPI *SCARDRELEASE)( ULONG_PTR );
static HMODULE        g_winscard;
static SCARDESTABLISH pSCardEstablishContext;
static SCARDRELEASE   pSCardReleaseContext;

/* DirectWrite is driven through hand-written vtable prefixes so that no
 * generated dwrite.h is needed by either toolchain route. Slot order follows
 * include/dwrite.idl; only the leading methods are typed. */
typedef struct IDWriteFactory IDWriteFactory;
typedef struct IDWriteFontCollection IDWriteFontCollection;
typedef struct IDWriteFontFamily IDWriteFontFamily;
typedef struct IDWriteFont IDWriteFont;
typedef struct IDWriteFontFace IDWriteFontFace;

typedef struct
{
    INT32  leftSideBearing;
    UINT32 advanceWidth;
    INT32  rightSideBearing;
    INT32  topSideBearing;
    UINT32 advanceHeight;
    INT32  bottomSideBearing;
    INT32  verticalOriginY;
} PROBE_GLYPH_METRICS;   /* DWRITE_GLYPH_METRICS */

#define PROBE_IUNKNOWN(T) \
    HRESULT (WINAPI *QueryInterface)( T *, const GUID *, void ** ); \
    ULONG   (WINAPI *AddRef)( T * ); \
    ULONG   (WINAPI *Release)( T * );

struct IDWriteFactoryVtbl
{
    PROBE_IUNKNOWN(IDWriteFactory)
    HRESULT (WINAPI *GetSystemFontCollection)( IDWriteFactory *, IDWriteFontCollection **, BOOL );
    /* 20 further methods are not used */
};
struct IDWriteFactory { const struct IDWriteFactoryVtbl *lpVtbl; };

struct IDWriteFontCollectionVtbl
{
    PROBE_IUNKNOWN(IDWriteFontCollection)
    UINT32  (WINAPI *GetFontFamilyCount)( IDWriteFontCollection * );
    HRESULT (WINAPI *GetFontFamily)( IDWriteFontCollection *, UINT32, IDWriteFontFamily ** );
    HRESULT (WINAPI *FindFamilyName)( IDWriteFontCollection *, const WCHAR *, UINT32 *, BOOL * );
    void *GetFontFromFontFace;
};
struct IDWriteFontCollection { const struct IDWriteFontCollectionVtbl *lpVtbl; };

struct IDWriteFontFamilyVtbl
{
    PROBE_IUNKNOWN(IDWriteFontFamily)
    void *GetFontCollection;                                          /* IDWriteFontList */
    UINT32  (WINAPI *GetFontCount)( IDWriteFontFamily * );
    HRESULT (WINAPI *GetFont)( IDWriteFontFamily *, UINT32, IDWriteFont ** );
    void *GetFamilyNames;
    HRESULT (WINAPI *GetFirstMatchingFont)( IDWriteFontFamily *, int weight, int stretch, int style, IDWriteFont ** );
    void *GetMatchingFonts;
};
struct IDWriteFontFamily { const struct IDWriteFontFamilyVtbl *lpVtbl; };

struct IDWriteFontVtbl
{
    PROBE_IUNKNOWN(IDWriteFont)
    void *GetFontFamily, *GetWeight, *GetStretch, *GetStyle, *IsSymbolFont, *GetFaceNames,
         *GetInformationalStrings, *GetSimulations, *GetMetrics, *HasCharacter;
    HRESULT (WINAPI *CreateFontFace)( IDWriteFont *, IDWriteFontFace ** );
};
struct IDWriteFont { const struct IDWriteFontVtbl *lpVtbl; };

struct IDWriteFontFaceVtbl
{
    PROBE_IUNKNOWN(IDWriteFontFace)
    void *GetType, *GetFiles, *GetIndex, *GetSimulations, *IsSymbolFont, *GetMetrics;
    UINT16  (WINAPI *GetGlyphCount)( IDWriteFontFace * );
    HRESULT (WINAPI *GetDesignGlyphMetrics)( IDWriteFontFace *, const UINT16 *, UINT32, PROBE_GLYPH_METRICS *, BOOL );
    HRESULT (WINAPI *GetGlyphIndices)( IDWriteFontFace *, const UINT32 *, UINT32, UINT16 * );
    /* TryGetFontTable and later methods are not used */
};
struct IDWriteFontFace { const struct IDWriteFontFaceVtbl *lpVtbl; };

typedef HRESULT (WINAPI *DWRITECREATEFACTORY)( int type, const GUID *iid, void **factory );
static const GUID iid_IDWriteFactory = { 0xb859ee5a, 0xd838, 0x4b5b, { 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 } };
#define DWRITE_FACTORY_TYPE_SHARED  0
#define DWRITE_FONT_WEIGHT_NORMAL   400
#define DWRITE_FONT_STRETCH_NORMAL  5
#define DWRITE_FONT_STYLE_NORMAL    0

static HMODULE                g_dwrite;
static IDWriteFactory        *g_factory;
static IDWriteFontCollection *g_coll;
static IDWriteFontFamily     *g_family;
static IDWriteFont           *g_font;
static IDWriteFontFace       *g_face;
static int                    g_dwrite_ready;
static const char            *g_dwrite_why = "not attempted";

static void setup_winscard( void )
{
    g_winscard = LoadLibraryW( L"winscard.dll" );
    if (!g_winscard) return;
    pSCardEstablishContext = (SCARDESTABLISH)(void *)GetProcAddress( g_winscard, "SCardEstablishContext" );
    pSCardReleaseContext   = (SCARDRELEASE)(void *)GetProcAddress( g_winscard, "SCardReleaseContext" );
}

static void setup_dwrite( void )
{
    DWRITECREATEFACTORY pDWriteCreateFactory;
    UINT32 index = 0, count;
    BOOL exists = FALSE;
    HRESULT hr;

    g_dwrite = LoadLibraryW( L"dwrite.dll" );
    if (!g_dwrite) { g_dwrite_why = "dwrite.dll not loadable"; return; }
    pDWriteCreateFactory = (DWRITECREATEFACTORY)(void *)GetProcAddress( g_dwrite, "DWriteCreateFactory" );
    if (!pDWriteCreateFactory) { g_dwrite_why = "DWriteCreateFactory missing"; return; }
    hr = pDWriteCreateFactory( DWRITE_FACTORY_TYPE_SHARED, &iid_IDWriteFactory, (void **)&g_factory );
    if (FAILED(hr) || !g_factory) { g_dwrite_why = "DWriteCreateFactory failed"; return; }
    hr = g_factory->lpVtbl->GetSystemFontCollection( g_factory, &g_coll, FALSE );
    if (FAILED(hr) || !g_coll) { g_dwrite_why = "GetSystemFontCollection failed"; return; }
    count = g_coll->lpVtbl->GetFontFamilyCount( g_coll );
    if (!count) { g_dwrite_why = "system font collection is empty"; return; }
    hr = g_coll->lpVtbl->FindFamilyName( g_coll, L"Tahoma", &index, &exists );
    if (FAILED(hr) || !exists) index = 0;
    hr = g_coll->lpVtbl->GetFontFamily( g_coll, index, &g_family );
    if (FAILED(hr) || !g_family) { g_dwrite_why = "GetFontFamily failed"; return; }
    hr = g_family->lpVtbl->GetFirstMatchingFont( g_family, DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                                 DWRITE_FONT_STYLE_NORMAL, &g_font );
    if (FAILED(hr) || !g_font) { g_dwrite_why = "GetFirstMatchingFont failed"; return; }
    hr = g_font->lpVtbl->CreateFontFace( g_font, &g_face );
    if (FAILED(hr) || !g_face) { g_dwrite_why = "CreateFontFace failed"; return; }
    g_dwrite_ready = 1;
    P( "info dwrite families=%u family=%s face=ok\n", count, exists ? "Tahoma" : "index-0" );
}

static void release_dwrite( void )
{
    if (g_face)    { g_face->lpVtbl->Release( g_face );       g_face = NULL; }
    if (g_font)    { g_font->lpVtbl->Release( g_font );       g_font = NULL; }
    if (g_family)  { g_family->lpVtbl->Release( g_family );   g_family = NULL; }
    if (g_coll)    { g_coll->lpVtbl->Release( g_coll );       g_coll = NULL; }
    if (g_factory) { g_factory->lpVtbl->Release( g_factory ); g_factory = NULL; }
}

/* Phase 1: NtYieldExecution. */
static void phase1_yield( void )
{
    UINT n = 100 * g_scale, i, yielded = 0, no_yield = 0, other = 0;
    LONGLONG t0, t1;
    LONG st;

    t0 = ticks();
    for (i = 0; i < n; i++)
    {
        st = NtYieldExecution();
        g_c_yield++;
        if (st == 0) yielded++;
        else if (st == STATUS_NO_YIELD_PERFORMED) no_yield++;
        else other++;
    }
    t1 = ticks();
    P( "info phase1 calls=%u yielded=%u no_yield=%u other=%u ns_per_call=%u\n",
       n, yielded, no_yield, other, ns_per_call( t1 - t0, n ) );
    CHECK( other == 0, "phase1-yield-status-set" );
}

/* Phase 2: QueryPerformanceCounter. */
static void phase2_qpc( void )
{
    UINT n = 200 * g_scale, i, failed = 0, backwards = 0;
    LARGE_INTEGER c;
    LONGLONG prev = 0, t0, t1;

    t0 = ticks();
    for (i = 0; i < n; i++)
    {
        g_c_qpc++;
        if (!QueryPerformanceCounter( &c )) { failed++; continue; }
        if (c.QuadPart < prev) backwards++;
        prev = c.QuadPart;
    }
    t1 = ticks();
    P( "info phase2 calls=%u failed=%u backwards=%u ns_per_call=%u\n",
       n, failed, backwards, ns_per_call( t1 - t0, n ) );
    CHECK( failed == 0, "phase2-qpc-succeeds" );
    CHECK( backwards == 0, "phase2-qpc-monotonic" );
}

/* Phase 3: CreateEventW + CloseHandle. */
static void phase3_events( void )
{
    UINT n = 50 * g_scale, i, create_failed = 0, close_failed = 0;
    LONGLONG t0, t1;
    HANDLE h;

    t0 = ticks();
    for (i = 0; i < n; i++)
    {
        h = probe_create_event();
        if (!h) { create_failed++; continue; }
        if (!probe_close( h )) close_failed++;
    }
    t1 = ticks();
    P( "info phase3 pairs=%u create_failed=%u close_failed=%u ns_per_pair=%u\n",
       n, create_failed, close_failed, ns_per_call( t1 - t0, n ) );
    CHECK( create_failed == 0, "phase3-create-event-x50" );
    CHECK( close_failed == 0, "phase3-close-handle-x50" );
}

/* Phase 4: timed waits on an unsignaled event. */
static void phase4_timeouts( void )
{
    UINT i, timeouts = 0, other = 0, ms;
    LONGLONG t0, t1;
    HANDLE ev;
    DWORD r;

    ev = probe_create_event();
    if (!ev)
    {
        g_fail++;
        P( "FAIL phase4-wait-timeout-x20: CreateEventW failed (lasterr %u)\n", (UINT)GetLastError() );
        return;
    }
    t0 = ticks();
    for (i = 0; i < 20; i++)
    {
        r = probe_wait( ev, 10, 1 );
        if (r == WAIT_TIMEOUT) timeouts++;
        else other++;
    }
    t1 = ticks();
    ms = ticks_to_ms( t1 - t0 );
    P( "info phase4 waits=20 timeouts=%u other=%u elapsed=%u-ms\n", timeouts, other, ms );
    CHECK( timeouts == 20, "phase4-wait-timeout-x20" );
    CHECK( ms >= 190 && ms < 3000, "phase4-wait-duration" );
    probe_close( ev );
}

/* Phase 5: a helper thread wakes the main thread 20 times. The helper names
 * itself (the name reaches /proc/PID/task/TID/comm), reports through a flag
 * and starts on a flag, so the only syscalls on its tid in the window are the
 * 20 SetEvent calls and the 20 waits for the acknowledgement. */
static HANDLE        g_ev5, g_ack5;
static volatile LONG g_helper_named, g_go;

static DWORD WINAPI helper_thread( LPVOID arg )
{
    DWORD t0 = GetTickCount();
    UINT i;

    (void)arg;
    name_current_thread( helper_commW );
    InterlockedExchange( &g_helper_named, 1 );
    while (!g_go && GetTickCount() - t0 < 30000) YieldProcessor();
    if (!g_go) return 1;
    for (i = 0; i < 20; i++)
    {
        g_c_helper_set++;
        if (!SetEvent( g_ev5 )) return 2;
        g_c_helper_wait++;
        if (WaitForSingleObject( g_ack5, 10000 ) != WAIT_OBJECT_0) return 3;
    }
    return 0;
}

static void phase5_wakes( void )
{
    UINT i, woken = 0;
    DWORD t0, exit_code = 99, tid = 0;
    HANDLE helper;

    g_ev5 = probe_create_event();
    g_ack5 = probe_create_event();
    InterlockedExchange( &g_helper_named, 0 );
    InterlockedExchange( &g_go, 0 );
    helper = (g_ev5 && g_ack5) ? CreateThread( NULL, 0, helper_thread, NULL, 0, &tid ) : NULL;
    if (!helper)
    {
        g_fail++;
        P( "FAIL phase5-wake-x20: setup failed (lasterr %u)\n", (UINT)GetLastError() );
        if (g_ev5) probe_close( g_ev5 );
        if (g_ack5) probe_close( g_ack5 );
        return;
    }
    g_helper_wintid = tid;
    t0 = GetTickCount();
    while (!g_helper_named && GetTickCount() - t0 < 5000) YieldProcessor();
    find_linux_helper_tid();
    InterlockedExchange( &g_go, 1 );

    for (i = 0; i < 20; i++)
    {
        if (probe_wait( g_ev5, 30000, 1 ) != WAIT_OBJECT_0) break;
        woken++;
        probe_set_event( g_ack5 );
    }
    if (probe_wait( helper, 30000, 0 ) == WAIT_OBJECT_0) GetExitCodeThread( helper, &exit_code );
    else
    {
        TerminateThread( helper, 98 );
        WaitForSingleObject( helper, 5000 );
    }
    P( "info phase5 woken=%u helper_exit=%u helper_wintid=%u linux_helper_tid=%u\n",
       woken, (UINT)exit_code, g_helper_wintid, g_linux_helper_tid );
    CHECK( woken == 20, "phase5-wake-x20" );
    CHECK( exit_code == 0, "phase5-helper-exit-ok" );
    probe_close( helper );
    probe_close( g_ev5 );
    probe_close( g_ack5 );
}

/* Phase 6a: unix calls into winscard.so. Each SCardEstablishContext makes one
 * unix call whatever the pcsc state; a successful context is released (one
 * more unix call). */
static void phase6_winscard( void )
{
    UINT n = 10 * g_scale, i, mismatch = 0, releases = 0;
    LONG rc, first = 0;
    ULONG_PTR ctx;
    LONGLONG t0, t1;

    if (!g_winscard) { SKIP( "phase6-scard-establish-x10", "winscard.dll not loadable" ); return; }
    if (!pSCardEstablishContext || !pSCardReleaseContext)
    {
        SKIP( "phase6-scard-establish-x10", "SCardEstablishContext/SCardReleaseContext missing" );
        return;
    }
    t0 = ticks();
    for (i = 0; i < n; i++)
    {
        ctx = 0;
        rc = pSCardEstablishContext( 0 /* SCARD_SCOPE_USER */, NULL, NULL, &ctx );
        g_c_scard++;
        if (i == 0) first = rc;
        else if (rc != first) mismatch++;
        if (rc == 0 && ctx)
        {
            pSCardReleaseContext( ctx );
            g_c_scard++;
            releases++;
        }
    }
    t1 = ticks();
    P( "info phase6 scard calls=%u first_rc=%08x mismatch=%u releases=%u unixcalls=%u ns_per_call=%u\n",
       n, (UINT)first, mismatch, releases, g_c_scard, ns_per_call( t1 - t0, n ) );
    CHECK( mismatch == 0, "phase6-scard-establish-x10" );
}

/* Phase 6b: GetGlyphIndices (PE side) and GetDesignGlyphMetrics (one unix
 * call per uncached glyph). */
static void phase6_dwrite( void )
{
    static const char alnum[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    UINT n_idx = 20 * g_scale, n_metrics, i, j, filled = 0, nuniq = 0, idx_failed = 0, metrics_failed = 0;
    UINT16 glyph[62], uniq[62], g;
    UINT32 cp;
    PROBE_GLYPH_METRICS m;
    LONGLONG t0, t1;
    HRESULT hr;

    if (!g_dwrite_ready) { SKIP( "phase6-dwrite", g_dwrite_why ); return; }

    for (i = 0; i < n_idx; i++)
    {
        cp = (UINT32)(unsigned char)alnum[i % 62];
        hr = g_face->lpVtbl->GetGlyphIndices( g_face, &cp, 1, &g );
        if (FAILED(hr)) { idx_failed++; continue; }
        if (i < 62) { glyph[i] = g; filled++; }
    }
    for (i = 0; i < filled; i++)
    {
        if (!glyph[i]) continue;
        for (j = 0; j < nuniq; j++) if (uniq[j] == glyph[i]) break;
        if (j == nuniq) uniq[nuniq++] = glyph[i];
    }
    n_metrics = 20 * g_scale;
    if (n_metrics > nuniq) n_metrics = nuniq;

    t0 = ticks();
    for (i = 0; i < n_metrics; i++)
    {
        hr = g_face->lpVtbl->GetDesignGlyphMetrics( g_face, &uniq[i], 1, &m, FALSE );
        g_c_dwrite++;
        if (FAILED(hr)) metrics_failed++;
    }
    t1 = ticks();
    P( "info phase6 dwrite glyph_index_calls=%u failed=%u distinct_glyphs=%u metric_calls=%u failed=%u ns_per_call=%u\n",
       n_idx, idx_failed, nuniq, n_metrics, metrics_failed, ns_per_call( t1 - t0, n_metrics ) );
    CHECK( idx_failed == 0, "phase6-dwrite-glyph-indices-x20" );
    CHECK( nuniq >= (n_idx < 20 ? n_idx : 20), "phase6-dwrite-distinct-glyphs" );
    CHECK( metrics_failed == 0 && n_metrics == (20 * g_scale < nuniq ? 20 * g_scale : nuniq),
           "phase6-dwrite-glyph-metrics-x20" );
    release_dwrite();
}

/* Phase 7: alertable delays. */
static void phase7_sleepex( void )
{
    UINT i, ok = 0, other = 0, ms;
    LONGLONG t0, t1;
    DWORD r;

    t0 = ticks();
    for (i = 0; i < 10; i++)
    {
        g_c_delay++;
        r = SleepEx( g_sleep_ms, TRUE );
        if (r == 0) ok++;
        else other++;
    }
    t1 = ticks();
    ms = ticks_to_ms( t1 - t0 );
    P( "info phase7 sleeps=10 sleep_ms=%u returned_zero=%u other=%u elapsed=%u-ms route=%s\n",
       g_sleep_ms, ok, other, ms, g_fastpath ? "ntsync-alert-wait" : "server-wait" );
    CHECK( ok == 10, "phase7-sleepex-x10" );
    CHECK( ms >= 10 * g_sleep_ms && ms < 2000 + 10 * g_sleep_ms, "phase7-sleepex-duration" );
}

static void expect( const char *kind, const char *id, const char *op, UINT n, const char *extra )
{
    P( "EXPECT %s %s %s %u%s%s\n", kind, id, op, n, extra ? " " : "", extra ? extra : "" );
}

static int ran( UINT phase ) { return !g_only || g_only == phase; }

static void print_expectations( void )
{
    expect( "syscall", "NtYieldExecution", "eq", g_c_yield, NULL );
    expect( "syscall", "NtQueryPerformanceCounter", "eq", g_c_qpc, NULL );
    expect( "syscall", "NtCreateEvent", "eq", g_c_create_event, NULL );
    expect( "server_req", "create_event", "eq", g_c_create_event, NULL );
    expect( "syscall", "NtClose", "ge", g_c_close, NULL );
    expect( "server_req", "close_handle", "ge", g_c_close, NULL );
    expect( "syscall", "NtWaitForSingleObject", "ge", g_c_wait_single, NULL );
    expect( "ntsync_wait", "WAIT_ANY", "ge", g_c_event_wait + (g_fastpath ? g_c_delay : 0), NULL );
    if (ran( 4 ) || ran( 5 )) expect( "server_req", "get_inproc_sync_fd", "ge", 1, NULL );
    expect( "ntsync_wake", "EVENT_SET", "ge", g_c_set_event, NULL );
    if (ran( 5 ) && g_helper_wintid)
    {
        expect( "ntsync_wake", "EVENT_SET", "eq", g_c_helper_set, "thread=helper" );
        expect( "ntsync_wait", "WAIT_ANY", "ge", g_c_helper_wait, "thread=helper" );
    }
    if (g_winscard && pSCardEstablishContext && pSCardReleaseContext)
        expect( "unixcall", "winscard.so", "eq", g_c_scard, NULL );
    if (g_dwrite_ready || g_c_dwrite) expect( "unixcall", "dwrite.so", "ge", g_c_dwrite, NULL );
    expect( "syscall", "NtDelayExecution", "eq", g_c_delay, NULL );
    if (g_fastpath) expect( "server_wait", "NtDelayExecution", "eq", 0, NULL );
    else expect( "server_wait", "NtDelayExecution", "ge", g_c_delay, NULL );
    P( "info counts yield=%u qpc=%u create_event=%u close=%u wait_single=%u event_wait=%u set_event=%u "
       "delay=%u scard=%u dwrite_metrics=%u helper_set=%u helper_wait=%u\n",
       g_c_yield, g_c_qpc, g_c_create_event, g_c_close, g_c_wait_single, g_c_event_wait, g_c_set_event,
       g_c_delay, g_c_scard, g_c_dwrite, g_c_helper_set, g_c_helper_wait );
}

void mainCRTStartup( void )
{
    int rc;

    g_out = CreateFileA( "traceprobe.txt", GENERIC_WRITE, FILE_SHARE_READ, NULL,
                         CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );
    if (g_out == INVALID_HANDLE_VALUE) g_out = NULL;
    g_con = GetStdHandle( STD_OUTPUT_HANDLE );
    if (g_con == INVALID_HANDLE_VALUE) g_con = NULL;

    if (find_opt( "--help" ) || find_opt( "-h" ))
    {
        usage();
        if (g_out) CloseHandle( g_out );
        ExitProcess( 0 );
    }
    g_no_procscan = find_opt( "--no-procscan" ) != NULL;
    if ((rc = opt_uint( "--only", &g_only )) < 0 || g_only > 7 ||
        (rc = opt_uint( "--scale", &g_scale )) < 0 || !g_scale || g_scale > 100000 ||
        (rc = opt_uint( "--settle", &g_settle_ms )) < 0 ||
        (rc = opt_uint( "--sleep-ms", &g_sleep_ms )) < 0)
    {
        emit( "traceprobe: bad option value\n" );
        usage();
        if (g_out) CloseHandle( g_out );
        ExitProcess( 2 );
    }

    pSetThreadDescription = (SETTHREADDESC)(void *)GetProcAddress( GetModuleHandleW( L"kernel32.dll" ),
                                                                   "SetThreadDescription" );
    g_winpid = GetCurrentProcessId();
    g_wintid = GetCurrentThreadId();
    read_fastpath_env();

    P( "traceprobe: wine interface tracer validation probe [fastpath=%s]\n", g_fastpath ? "on" : "off" );
    P( "info options only=%u scale=%u settle_ms=%u sleep_ms=%u procscan=%s\n",
       g_only, g_scale, g_settle_ms, g_sleep_ms, g_no_procscan ? "off" : "on" );
    if (g_fastpath_set) P( "info env WINE_APC_FASTPATH=%s fastpath=%s\n", g_fastpath_val, g_fastpath ? "on" : "off" );
    else emit( "info env WINE_APC_FASTPATH=<unset> fastpath=off\n" );

    /* Setup outside the traced window: DLL loading and the DirectWrite font
     * collection, thread naming, the /proc scan. */
    if (ran( 6 ))
    {
        setup_winscard();
        P( "info load winscard.dll=%s SCardEstablishContext=%s\n", g_winscard ? "ok" : "missing",
           pSCardEstablishContext ? "ok" : "missing" );
        setup_dwrite();
        P( "info load dwrite.dll=%s ready=%s%s%s\n", g_dwrite ? "ok" : "missing", g_dwrite_ready ? "yes" : "no",
           g_dwrite_ready ? "" : " why=", g_dwrite_ready ? "" : g_dwrite_why );
    }
    find_linux_ids();
    name_current_thread( main_commW );
    P( "info thread-description=%s procscan=%s\n", pSetThreadDescription ? "available" : "unavailable",
       g_no_procscan ? "skipped" : g_procscan_ok ? "ok" : "no-match" );
    print_ids( "info ids" );

    if (g_settle_ms)
    {
        P( "info settle spin ms=%u (attach the tracer now)\n", g_settle_ms );
        spin_ms( g_settle_ms );
    }
    P( "info presettle create_event=%u close=%u wait_single=%u set_event=%u qpc=%u (not covered by EXPECT)\n",
       g_c_create_event, g_c_close, g_c_wait_single, g_c_set_event, g_c_qpc );
    reset_counters();

    if (ran( 1 )) phase1_yield();
    if (ran( 2 )) phase2_qpc();
    if (ran( 3 )) phase3_events();
    if (ran( 4 )) phase4_timeouts();
    if (ran( 5 )) phase5_wakes();
    if (ran( 6 )) { phase6_winscard(); phase6_dwrite(); }
    if (ran( 7 )) phase7_sleepex();

    print_expectations();
    P( "SUMMARY pass=%d fail=%d skip=%d\n", g_pass, g_fail, g_skip );
    print_ids( "TID" );
    if (g_out) CloseHandle( g_out );
    ExitProcess( g_fail );
}
