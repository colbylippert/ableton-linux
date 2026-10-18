/* syncbench.c measures the cost of the Wine calls on Ableton Live's audio hot path
 * (profiler trace diag-D0001, 2026-10-18: per 1.33 ms audio block Live makes about
 * 105 SetEvent, 70 WaitForSingleObject, 70 ResetEvent and 65 QueryPerformanceCounter
 * calls, nearly all from its AudioCalc worker fan-out).
 *
 * Benchmarks (each runs --reps times; the report gives the best and the median):
 *   qpc        QueryPerformanceCounter                         ns per call
 *   tick       GetTickCount (user-mode in Wine; baseline)      ns per call
 *   set        SetEvent on a signaled auto-reset event         ns per call
 *   reset      ResetEvent on a manual-reset event              ns per call
 *   setreset   SetEvent + ResetEvent on a manual-reset event   ns per pair
 *   waitsig    WaitForSingleObject(signaled manual event, 0)   ns per call
 *   pingpong   two threads hand an auto-reset event back and   us per round trip
 *              forth (two wake-ups per round)
 *   fanout     Live's pattern: one dispatcher sets one manual-reset event per
 *              worker; each worker wakes, resets its event, spins --work-ns,
 *              decrements a counter, and the last one sets the dispatcher's
 *              done event                                       us per round
 *
 * Options:
 *   --only NAME      run one benchmark
 *   --iters N        calls per repetition for the per-call benchmarks (default 200000)
 *   --rounds N       rounds per repetition for pingpong and fanout (default 20000)
 *   --reps N         repetitions (default 5)
 *   --workers K      fanout workers (default 15)
 *   --work-ns N      busy work per worker per round in fanout (default 0)
 *   --cpus a,b,...   pin the main thread to a and thread i to the i-th entry (wrapping)
 *   --help
 *
 * The probe is a plain PE without a CRT (kernel32 only). Timing uses
 * QueryPerformanceCounter around whole loops, so its own cost is amortised.
 * Build with build_syncbench.sh; run inside the Ableton prefix, ideally the way the
 * launcher runs Live:
 *   chrt -r 10 taskset -c 0-11 tools/run_in_prefix.sh syncbench.exe
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static HANDLE g_con;
static char   buf[512];

static void emit( const char *s )
{
    DWORD n;
    if (g_con) WriteFile( g_con, s, lstrlenA( s ), &n, NULL );
}
#define P(...) do { wsprintfA( buf, __VA_ARGS__ ); emit( buf ); } while (0)

/* ---------- options ---------- */

static const char *g_only;
static UINT g_iters = 200000, g_rounds = 20000, g_reps = 5, g_workers = 15, g_work_ns;
static UINT g_cpus[64], g_ncpus;   /* --cpus a,b,c: thread i runs on g_cpus[i % g_ncpus] (0 = main) */

static void parse_cpus( const char *s )
{
    UINT v = 0; int have = 0;
    for (;; s++)
    {
        if (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); have = 1; continue; }
        if (have && g_ncpus < 64) g_cpus[g_ncpus++] = v;
        v = 0; have = 0;
        if (*s != ',') break;
    }
}

static void pin_self( UINT slot )
{
    if (!g_ncpus) return;
    SetThreadAffinityMask( GetCurrentThread(), (DWORD_PTR)1 << g_cpus[slot % g_ncpus] );
}

static const char *skip_ws( const char *p ) { while (*p == ' ' || *p == '\t') p++; return p; }

static int same_prefix( const char *a, const char *b, int len )
{
    int i;
    for (i = 0; i < len; i++) if (a[i] != b[i]) return 0;
    return 1;
}

static const char *find_opt( const char *name )
{
    const char *cmd = GetCommandLineA(), *p = cmd;
    int len = lstrlenA( name );
    while ((p = skip_ws( p )) && *p)
    {
        const char *start = p;
        if (*p == '"') { p++; while (*p && *p != '"') p++; if (*p) p++; }
        else while (*p && *p != ' ' && *p != '\t') p++;
        if (p - start >= len && same_prefix( start, name, len ) && (start[len] == 0 || start[len] == ' ' || start[len] == '='))
            return start + len;
    }
    return NULL;
}

static int opt_uint( const char *name, UINT *val )
{
    const char *p = find_opt( name );
    UINT v = 0;
    if (!p) return 0;
    if (*p == '=' || *p == ' ') p++;
    p = skip_ws( p );
    if (*p < '0' || *p > '9') return -1;
    while (*p >= '0' && *p <= '9') v = v * 10 + (*p++ - '0');
    *val = v;
    return 1;
}

static const char *opt_str( const char *name, char *out, int size )
{
    const char *p = find_opt( name );
    int i = 0;
    if (!p) return NULL;
    if (*p == '=' || *p == ' ') p++;
    p = skip_ws( p );
    while (*p && *p != ' ' && *p != '\t' && i < size - 1) out[i++] = *p++;
    out[i] = 0;
    return out;
}

/* ---------- timing ---------- */

static LONGLONG g_freq;

static LONGLONG now( void )
{
    LARGE_INTEGER c;
    QueryPerformanceCounter( &c );
    return c.QuadPart;
}

/* elapsed counter ticks -> tenths of a nanosecond per op (integer, no CRT floats) */
static ULONGLONG tenth_ns_per( LONGLONG ticks, ULONGLONG ops )
{
    return (ULONGLONG)ticks * 10000000000ull / (ULONGLONG)g_freq / ops;
}

static void sort_u64( ULONGLONG *v, UINT n )
{
    UINT i, j;
    for (i = 1; i < n; i++)
        for (j = i; j > 0 && v[j - 1] > v[j]; j--) { ULONGLONG t = v[j]; v[j] = v[j - 1]; v[j - 1] = t; }
}

static void report( const char *name, const char *unit, ULONGLONG *tenths, UINT n, ULONGLONG divisor )
{
    ULONGLONG best, med;
    sort_u64( tenths, n );
    best = tenths[0] / divisor; med = tenths[n / 2] / divisor;
    /* print with one decimal: value is in tenths of the unit */
    P( "%-9s best %5u.%u %s   median %5u.%u %s\n", name,
       (UINT)(best / 10), (UINT)(best % 10), unit, (UINT)(med / 10), (UINT)(med % 10), unit );
}

static volatile LONG g_sink;

static void spin_ns( UINT ns )
{
    LONGLONG end;
    if (!ns) return;
    end = now() + (LONGLONG)ns * g_freq / 1000000000;
    while (now() < end) g_sink++;
}

/* ---------- per-call benchmarks ---------- */

static void bench_qpc( void )
{
    ULONGLONG t[64]; UINT r, i;
    for (r = 0; r < g_reps; r++)
    {
        LARGE_INTEGER c; LONGLONG a = now();
        for (i = 0; i < g_iters; i++) QueryPerformanceCounter( &c );
        t[r] = tenth_ns_per( now() - a, g_iters );
    }
    report( "qpc", "ns", t, g_reps, 1 );
}

static void bench_tick( void )
{
    ULONGLONG t[64]; UINT r, i;
    for (r = 0; r < g_reps; r++)
    {
        LONGLONG a = now();
        for (i = 0; i < g_iters; i++) g_sink += GetTickCount();
        t[r] = tenth_ns_per( now() - a, g_iters );
    }
    report( "tick", "ns", t, g_reps, 1 );
}

static void bench_set( void )
{
    ULONGLONG t[64]; UINT r, i;
    HANDLE ev = CreateEventW( NULL, FALSE, TRUE, NULL );
    for (r = 0; r < g_reps; r++)
    {
        LONGLONG a = now();
        for (i = 0; i < g_iters; i++) SetEvent( ev );
        t[r] = tenth_ns_per( now() - a, g_iters );
    }
    CloseHandle( ev );
    report( "set", "ns", t, g_reps, 1 );
}

static void bench_reset( void )
{
    ULONGLONG t[64]; UINT r, i;
    HANDLE ev = CreateEventW( NULL, TRUE, FALSE, NULL );
    for (r = 0; r < g_reps; r++)
    {
        LONGLONG a = now();
        for (i = 0; i < g_iters; i++) ResetEvent( ev );
        t[r] = tenth_ns_per( now() - a, g_iters );
    }
    CloseHandle( ev );
    report( "reset", "ns", t, g_reps, 1 );
}

static void bench_setreset( void )
{
    ULONGLONG t[64]; UINT r, i;
    HANDLE ev = CreateEventW( NULL, TRUE, FALSE, NULL );
    for (r = 0; r < g_reps; r++)
    {
        LONGLONG a = now();
        for (i = 0; i < g_iters; i++) { SetEvent( ev ); ResetEvent( ev ); }
        t[r] = tenth_ns_per( now() - a, g_iters );
    }
    CloseHandle( ev );
    report( "setreset", "ns", t, g_reps, 1 );
}

static void bench_waitsig( void )
{
    ULONGLONG t[64]; UINT r, i;
    HANDLE ev = CreateEventW( NULL, TRUE, TRUE, NULL );
    for (r = 0; r < g_reps; r++)
    {
        LONGLONG a = now();
        for (i = 0; i < g_iters; i++) WaitForSingleObject( ev, 0 );
        t[r] = tenth_ns_per( now() - a, g_iters );
    }
    CloseHandle( ev );
    report( "waitsig", "ns", t, g_reps, 1 );
}

/* ---------- pingpong ---------- */

static HANDLE g_ping, g_pong;
static volatile LONG g_stop;

static DWORD WINAPI pong_thread( void *arg )
{
    (void)arg;
    pin_self( 1 );
    for (;;)
    {
        WaitForSingleObject( g_ping, INFINITE );
        if (g_stop) break;
        SetEvent( g_pong );
    }
    return 0;
}

static void bench_pingpong( void )
{
    ULONGLONG t[64]; UINT r, i;
    HANDLE th;
    g_ping = CreateEventW( NULL, FALSE, FALSE, NULL );
    g_pong = CreateEventW( NULL, FALSE, FALSE, NULL );
    g_stop = 0;
    th = CreateThread( NULL, 0, pong_thread, NULL, 0, NULL );
    for (i = 0; i < 1000; i++) { SetEvent( g_ping ); WaitForSingleObject( g_pong, INFINITE ); }
    for (r = 0; r < g_reps; r++)
    {
        LONGLONG a = now();
        for (i = 0; i < g_rounds; i++) { SetEvent( g_ping ); WaitForSingleObject( g_pong, INFINITE ); }
        t[r] = tenth_ns_per( now() - a, g_rounds );
    }
    g_stop = 1; SetEvent( g_ping );
    WaitForSingleObject( th, INFINITE );
    CloseHandle( th ); CloseHandle( g_ping ); CloseHandle( g_pong );
    report( "pingpong", "us", t, g_reps, 1000 );
}

/* ---------- fanout ---------- */

#define MAX_WORKERS 64
static HANDLE g_work_ev[MAX_WORKERS], g_done_ev;
static volatile LONG g_left;

static DWORD WINAPI fan_worker( void *arg )
{
    UINT idx = (UINT)(ULONG_PTR)arg;
    pin_self( idx + 1 );
    for (;;)
    {
        WaitForSingleObject( g_work_ev[idx], INFINITE );
        ResetEvent( g_work_ev[idx] );
        if (g_stop) break;
        spin_ns( g_work_ns );
        if (!InterlockedDecrement( &g_left )) SetEvent( g_done_ev );
    }
    return 0;
}

static void fan_round( UINT k )
{
    UINT w;
    g_left = k;
    for (w = 0; w < k; w++) SetEvent( g_work_ev[w] );
    WaitForSingleObject( g_done_ev, INFINITE );
}

static void bench_fanout( void )
{
    ULONGLONG t[64]; UINT r, i, w, k = g_workers;
    HANDLE th[MAX_WORKERS];
    if (k < 1) k = 1;
    if (k > MAX_WORKERS) k = MAX_WORKERS;
    g_done_ev = CreateEventW( NULL, FALSE, FALSE, NULL );
    g_stop = 0;
    for (w = 0; w < k; w++)
    {
        g_work_ev[w] = CreateEventW( NULL, TRUE, FALSE, NULL );
        th[w] = CreateThread( NULL, 0, fan_worker, (void *)(ULONG_PTR)w, 0, NULL );
    }
    for (i = 0; i < 500; i++) fan_round( k );
    for (r = 0; r < g_reps; r++)
    {
        LONGLONG a = now();
        for (i = 0; i < g_rounds; i++) fan_round( k );
        t[r] = tenth_ns_per( now() - a, g_rounds );
    }
    g_stop = 1;
    for (w = 0; w < k; w++) SetEvent( g_work_ev[w] );
    WaitForMultipleObjects( k, th, TRUE, INFINITE );
    for (w = 0; w < k; w++) { CloseHandle( th[w] ); CloseHandle( g_work_ev[w] ); }
    CloseHandle( g_done_ev );
    wsprintfA( buf, "fanout%u", k );
    report( buf, "us", t, g_reps, 1000 );
}

/* ---------- main ---------- */

static int want( const char *name )
{
    return !g_only || !lstrcmpA( g_only, name );
}

void mainCRTStartup( void )
{
    char only[32];
    LARGE_INTEGER f;

    g_con = GetStdHandle( STD_OUTPUT_HANDLE );
    if (g_con == INVALID_HANDLE_VALUE) g_con = NULL;
    if (find_opt( "--help" ))
    {
        emit( "usage: syncbench.exe [--only qpc|tick|set|reset|setreset|waitsig|pingpong|fanout] [--iters N]\n"
              "                     [--rounds N] [--reps N] [--workers K] [--work-ns N]\n" );
        ExitProcess( 0 );
    }
    g_only = opt_str( "--only", only, sizeof(only) );
    {
        char cpus[256];
        if (opt_str( "--cpus", cpus, sizeof(cpus) )) parse_cpus( cpus );
        pin_self( 0 );
    }
    if (opt_uint( "--iters", &g_iters ) < 0 || opt_uint( "--rounds", &g_rounds ) < 0 ||
        opt_uint( "--reps", &g_reps ) < 0 || opt_uint( "--workers", &g_workers ) < 0 ||
        opt_uint( "--work-ns", &g_work_ns ) < 0 || !g_iters || !g_rounds || !g_reps || g_reps > 64)
    {
        emit( "syncbench: bad option value\n" );
        ExitProcess( 2 );
    }
    QueryPerformanceFrequency( &f );
    g_freq = f.QuadPart;
    P( "syncbench: iters=%u rounds=%u reps=%u workers=%u work_ns=%u qpc_freq=%u\n",
       g_iters, g_rounds, g_reps, g_workers, g_work_ns, (UINT)g_freq );

    if (want( "qpc" )) bench_qpc();
    if (want( "tick" )) bench_tick();
    if (want( "set" )) bench_set();
    if (want( "reset" )) bench_reset();
    if (want( "setreset" )) bench_setreset();
    if (want( "waitsig" )) bench_waitsig();
    if (want( "pingpong" )) bench_pingpong();
    if (want( "fanout" )) bench_fanout();
    ExitProcess( 0 );
}
