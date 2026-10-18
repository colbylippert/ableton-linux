/* qpcprobe.c — checks QueryPerformanceCounter, including the user-mode route of patch
 * 0109 (WINE_QPC_TSC=1: wineserver publishes a TSC-to-QPC mapping in the shared user
 * data and RtlQueryPerformanceCounter reads it without a syscall).
 *
 * CRT-free PE build: tools/build_qpcprobe.sh (x86_64-w64-mingw32-gcc).
 * Run:  tools/run_in_prefix.sh qpcprobe.exe
 *       (the user-mode route needs WINE_QPC_TSC=1 in wineserver's environment, i.e. in
 *       the environment of the first Wine process of the prefix session)
 *
 * Checks (PASS/FAIL, exit status = number of FAILs):
 *   frequency   QueryPerformanceFrequency is 10 MHz (QPC keeps its 100 ns units)
 *   monotonic   2,000,000 values from alternating QueryPerformanceCounter and
 *               NtQueryPerformanceCounter calls never go backwards
 *   agreement   a NtQueryPerformanceCounter value read right after a
 *               QueryPerformanceCounter value is never smaller and at most 5 us larger
 *               on average (both routes read one clock)
 *   rate        over 3 s, QPC advances at the rate of the system time to within 500 ppm
 *               (CLOCK_BOOTTIME and CLOCK_REALTIME share NTP's rate)
 * and reports the cost of each route per call, and which route QueryPerformanceCounter
 * takes (user mode when it costs under half the syscall).
 */

#include <windows.h>

typedef LONG (WINAPI *nt_qpc_fn)( LARGE_INTEGER *, LARGE_INTEGER * );
typedef LONG (WINAPI *nt_qst_fn)( LARGE_INTEGER * );

static HANDLE g_out;
static char   obuf[256];
static int    g_fail;

static void emit( const char *s ) { DWORD n; WriteFile( g_out, s, lstrlenA( s ), &n, NULL ); }
#define P(...) do { wsprintfA( obuf, __VA_ARGS__ ); emit( obuf ); } while (0)

static void result( BOOL ok, const char *name, const char *detail )
{
    P( "%s %-10s %s\n", ok ? "PASS" : "FAIL", name, detail );
    if (!ok) g_fail++;
}

static LONGLONG qpc( void ) { LARGE_INTEGER v; QueryPerformanceCounter( &v ); return v.QuadPart; }

void __cdecl mainCRTStartup( void )
{
    nt_qpc_fn nt_qpc = (nt_qpc_fn)(void *)GetProcAddress( GetModuleHandleA( "ntdll.dll" ), "NtQueryPerformanceCounter" );
    LARGE_INTEGER freq, v;
    LONGLONG prev = 0, back = 0, max_back = 0, gap, gap_sum = 0, max_gap = 0, negative = 0;
    LONGLONG t0, t1, ns_rtl, ns_nt, k0, k1, tick_ms;
    char detail[160];
    int i;

    g_out = GetStdHandle( STD_OUTPUT_HANDLE );
    if (!nt_qpc) { emit( "FAIL setup      NtQueryPerformanceCounter not found\n" ); ExitProcess( 1 ); }

    QueryPerformanceFrequency( &freq );
    wsprintfA( detail, "%u Hz", (UINT)freq.QuadPart );
    result( freq.QuadPart == 10000000, "frequency", detail );

    for (i = 0; i < 2000000; i++)
    {
        if (i & 1) nt_qpc( &v, NULL ); else QueryPerformanceCounter( &v );
        if (v.QuadPart < prev)
        {
            back++;
            if (prev - v.QuadPart > max_back) max_back = prev - v.QuadPart;
        }
        prev = v.QuadPart;
    }
    wsprintfA( detail, "%u backward step(s) in 2000000 values, largest %u tick(s)", (UINT)back, (UINT)max_back );
    result( back == 0, "monotonic", detail );

    for (i = 0; i < 200000; i++)
    {
        LARGE_INTEGER a, b;
        QueryPerformanceCounter( &a );
        nt_qpc( &b, NULL );
        gap = b.QuadPart - a.QuadPart;
        if (gap < 0) negative++;
        gap_sum += gap;
        if (gap > max_gap) max_gap = gap;
    }
    wsprintfA( detail, "mean gap %u.%02u ticks, largest %u, %u negative (Nt read right after Rtl)",
               (UINT)(gap_sum / 200000), (UINT)((gap_sum % 200000) * 100 / 200000), (UINT)max_gap, (UINT)negative );
    result( negative == 0 && gap_sum / 200000 <= 50, "agreement", detail );

    t0 = qpc();
    for (i = 0; i < 2000000; i++) QueryPerformanceCounter( &v );
    t1 = qpc();
    ns_rtl = (t1 - t0) * 100 / 2000000;
    t0 = qpc();
    for (i = 0; i < 2000000; i++) nt_qpc( &v, NULL );
    t1 = qpc();
    ns_nt = (t1 - t0) * 100 / 2000000;
    P( "INFO cost       QueryPerformanceCounter %u ns, NtQueryPerformanceCounter %u ns per call\n",
       (UINT)ns_rtl, (UINT)ns_nt );
    P( "INFO route      %s\n", ns_rtl * 2 < ns_nt
       ? "QueryPerformanceCounter reads the TSC mapping in user mode"
       : "QueryPerformanceCounter takes the syscall (WINE_QPC_TSC unset, or the TSC is not usable)" );

    /* rate: against the system time (CLOCK_REALTIME, 100 ns resolution, read by syscall);
     * GetTickCount64 only moves when wineserver refreshes it (16 ms), so it is shown too */
    {
        LARGE_INTEGER s0, s1;
        LONGLONG sys_us, qpc_us, ppm;
        nt_qst_fn nt_qst = (nt_qst_fn)(void *)GetProcAddress( GetModuleHandleA( "ntdll.dll" ), "NtQuerySystemTime" );

        if (!nt_qst) { emit( "FAIL setup      NtQuerySystemTime not found\n" ); ExitProcess( 1 ); }
        nt_qst( &s0 );
        t0 = qpc();
        k0 = GetTickCount64();
        Sleep( 3000 );
        nt_qst( &s1 );
        t1 = qpc();
        k1 = GetTickCount64();
        qpc_us = (t1 - t0) / 10;
        sys_us = (s1.QuadPart - s0.QuadPart) / 10;
        tick_ms = k1 - k0;
        ppm = sys_us ? (qpc_us - sys_us) * 1000000 / sys_us : 1000000;
        wsprintfA( detail, "QPC %u us vs system time %u us over Sleep(3000): %d ppm (GetTickCount64 %u ms)",
                   (UINT)qpc_us, (UINT)sys_us, (int)ppm, (UINT)tick_ms );
        result( ppm >= -500 && ppm <= 500, "rate", detail );
    }

    ExitProcess( g_fail );
}
