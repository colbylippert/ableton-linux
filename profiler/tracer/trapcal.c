/* trapcal.c -- the timed workload of the uprobe trap calibration of the Wine interface tracer
 * (profiler/tracer/calibrate.py, run by `profiler/bin/wine-trace calibrate`).
 *
 *   trapcal.exe [--iterations N] [--repeats R] [--warmup N] [--go-file PATH] [--idle-ms MS]
 *
 * Prints "info ready winpid=P" first.  With --go-file it then sleeps in 5 ms steps until that
 * (Windows) path exists, so the tracer can attach before anything is timed.  Then it makes
 * --warmup untimed NtYieldExecution calls and R times N NtYieldExecution calls between two
 * NtQueryPerformanceCounter readings, one line per repeat:
 *
 *   RESULT r=<i> calls=<N> ns_per_call=<ns>.<thousandths>
 *
 * Every call is one syscall through Wine's dispatcher, i.e. one wine:syscall_entry and one
 * wine:syscall_exit probe hit when traced.  --idle-ms MS only sleeps (a traced process that
 * makes no calls: one more uprobe consumer for the extra-consumer measurement).
 *
 * A plain PE without a CRT (kernel32 + ntdll), like tools/traceprobe.exe:
 *   x86_64-w64-mingw32-gcc -Wall -Wextra -O1 -nostartfiles -Wl,-e,mainCRTStartup \
 *       -o trapcal.exe trapcal.c -lkernel32 -lntdll
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

LONG WINAPI NtYieldExecution( void );
LONG WINAPI NtQueryPerformanceCounter( LARGE_INTEGER *counter, LARGE_INTEGER *frequency );

static HANDLE g_out;
static char   buf[256];

static void emit( const char *s )
{
    DWORD n;
    if (g_out) WriteFile( g_out, s, lstrlenA( s ), &n, NULL );
}
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)

/* Command line: tokens separated by blanks; the program name may be quoted. */
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

static UINT opt_uint( const char *name, UINT dflt )
{
    const char *v = find_opt( name );
    UINT n = 0;
    if (!v || *v < '0' || *v > '9') return dflt;
    while (*v >= '0' && *v <= '9') n = n * 10 + (UINT)(*v++ - '0');
    return n;
}

/* the token after name copied into out (no blanks in paths: calibrate.py makes sure) */
static int opt_str( const char *name, char *out, int size )
{
    const char *v = find_opt( name );
    int i = 0;
    if (!v || !*v) return 0;
    while (v[i] && v[i] != ' ' && v[i] != '\t' && i < size - 1) { out[i] = v[i]; i++; }
    out[i] = 0;
    return i > 0;
}

void mainCRTStartup( void )
{
    UINT iterations = opt_uint( "--iterations", 200000 );
    UINT repeats = opt_uint( "--repeats", 7 );
    UINT warmup = opt_uint( "--warmup", 20000 );
    UINT idle_ms = opt_uint( "--idle-ms", 0 );
    char go[MAX_PATH];
    LARGE_INTEGER c0, c1, f;
    UINT i, r;

    g_out = GetStdHandle( STD_OUTPUT_HANDLE );
    P( "info ready winpid=%u\n", (UINT)GetCurrentProcessId() );
    if (opt_str( "--go-file", go, sizeof(go) ))
    {
        UINT waited = 0;
        while (GetFileAttributesA( go ) == INVALID_FILE_ATTRIBUTES)
        {
            Sleep( 5 );
            if ((waited += 5) > 120000) { P( "info go-file timeout\n" ); ExitProcess( 2 ); }
        }
    }
    if (idle_ms)
    {
        Sleep( idle_ms );
        P( "info idle done\n" );
        ExitProcess( 0 );
    }
    if (!iterations) iterations = 1;
    for (i = 0; i < warmup; i++) NtYieldExecution();
    for (r = 0; r < repeats; r++)
    {
        LONGLONG ns, ps;
        NtQueryPerformanceCounter( &c0, &f );
        for (i = 0; i < iterations; i++) NtYieldExecution();
        NtQueryPerformanceCounter( &c1, &f );
        if (f.QuadPart <= 0) { P( "info no performance counter\n" ); ExitProcess( 3 ); }
        ns = (c1.QuadPart - c0.QuadPart) * 1000000000 / f.QuadPart;
        ps = ns * 1000 / iterations;
        P( "RESULT r=%u calls=%u ns_per_call=%u.%03u\n", r, iterations, (UINT)(ps / 1000), (UINT)(ps % 1000) );
    }
    ExitProcess( 0 );
}
