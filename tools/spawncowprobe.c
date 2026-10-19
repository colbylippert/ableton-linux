/* spawncowprobe.c — does creating a process make the parent's memory fault on its next write?
 *
 * Wine's spawn_process() (dlls/ntdll/unix/process.c) starts every new process with fork(). fork() write-protects
 * every private writable page of the parent for copy-on-write; after the short-lived child is gone the parent's
 * pages are its own again, but the first write to each one still takes a page fault. In Ableton Live that turns
 * the first write to a buffer after Live has spawned its helpers into a storm of ~1,500 faults inside one audio
 * block (diagnostic D0003).
 *
 * Build: tools/build_spawncowprobe.sh (x86_64-w64-mingw32-gcc).
 * Run:   WINE_POSIX_SPAWN=1 tools/run_in_prefix.sh spawncowprobe.exe   (exit status = number of failed checks;
 *        patch 0112: with the switch the check passes, without it Wine's fork() makes it fail)
 *
 * The probe commits 128 MiB as 1 MiB chunks separated by uncommitted gaps, so every chunk is its own small
 * mapping that transparent huge pages cannot back (Live's heap pieces fault per 4 KiB page the same way; a single
 * large region would be backed by 2 MiB pages and hide the effect). It writes every page once (populate), times a
 * second write pass (one byte per page), then starts a child process (itself with "child", which exits at once),
 * waits for it, and times a third pass.
 * Checks (PASS/FAIL):
 *   warm       the second pass takes no page faults worth measuring (under 0.1 us per page)
 *   spawn      the pass after the child process costs at most 0.1 us per page more than the warm pass
 * An INFO line reports how long the child took to start, run and exit.
 */

#include <windows.h>
#include <stdio.h>
#include <string.h>

#define CHUNK ((SIZE_T)1 << 20)
#define GAP ((SIZE_T)64 << 10)
#define CHUNKS 128
#define SIZE (CHUNK * CHUNKS)
#define PAGES (SIZE / 4096)

static unsigned char *chunks[CHUNKS];

static int g_fail;

static double now_ms( void )
{
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency( &f );
    QueryPerformanceCounter( &c );
    return (double)c.QuadPart * 1000.0 / (double)f.QuadPart;
}

static double write_pass( unsigned char value )
{
    double t0 = now_ms();
    SIZE_T i;
    int c;
    for (c = 0; c < CHUNKS; c++)
    {
        volatile unsigned char *p = chunks[c];
        for (i = 0; i < CHUNK; i += 4096) p[i] = value;
    }
    return now_ms() - t0;
}

static void result( BOOL ok, const char *name, const char *detail )
{
    printf( "%s %-6s %s\n", ok ? "PASS" : "FAIL", name, detail );
    if (!ok) g_fail++;
}

int main( int argc, char **argv )
{
    STARTUPINFOA si = { 0 };
    PROCESS_INFORMATION pi;
    char path[MAX_PATH], cmd[MAX_PATH + 16], detail[200];
    unsigned char *base;
    double warm, after, spawn_ms, t0;
    int c;

    if (argc > 1 && !strcmp( argv[1], "child" )) return 0;
    setvbuf( stdout, NULL, _IONBF, 0 );
    si.cb = sizeof(si);

    base = VirtualAlloc( NULL, (CHUNK + GAP) * CHUNKS, MEM_RESERVE, PAGE_NOACCESS );
    for (c = 0; base && c < CHUNKS; c++)
        if (!(chunks[c] = VirtualAlloc( base + c * (CHUNK + GAP), CHUNK, MEM_COMMIT, PAGE_READWRITE ))) base = NULL;
    if (!base)
    {
        printf( "SKIP alloc  VirtualAlloc of %d x 1 MiB failed (%lu)\n", CHUNKS, GetLastError() );
        return 0;
    }
    write_pass( 1 );                            /* populate */
    warm = write_pass( 2 );
    sprintf( detail, "%.1f ms for %lu pages (%.3f us per page)", warm, (unsigned long)PAGES, warm * 1000.0 / PAGES );
    result( warm * 1000.0 / PAGES < 0.1, "warm", detail );

    GetModuleFileNameA( NULL, path, sizeof(path) );
    sprintf( cmd, "\"%s\" child", path );
    t0 = now_ms();
    if (!CreateProcessA( NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi ))
    {
        printf( "SKIP spawn  CreateProcess failed (%lu)\n", GetLastError() );
        return g_fail;
    }
    WaitForSingleObject( pi.hProcess, 60000 );
    spawn_ms = now_ms() - t0;
    CloseHandle( pi.hThread );
    CloseHandle( pi.hProcess );

    after = write_pass( 3 );
    sprintf( detail, "%.1f ms for %lu pages after the child (%.3f us per page, %+.3f vs warm)",
             after, (unsigned long)PAGES, after * 1000.0 / PAGES, (after - warm) * 1000.0 / PAGES );
    result( (after - warm) * 1000.0 / PAGES <= 0.1, "spawn", detail );
    printf( "INFO child  created, ran and exited in %.1f ms\n", spawn_ms );

    VirtualFree( base, 0, MEM_RELEASE );
    return g_fail;
}
