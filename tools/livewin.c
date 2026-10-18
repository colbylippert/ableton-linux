/* livewin.c — minimise or restore Ableton Live's main window from inside its Wine prefix.
 * Runs as a separate Wine process in the same prefix/wineserver session (like
 * liveinject.exe) and finds the main window the same way, by its window class.
 * ShowWindowAsync goes through Live's own UI thread and winex11, which asks the
 * window manager to iconify the X11 window: the same path as a click on the
 * title bar's minimise button. The bench suite uses it for
 * ABLETON_BENCH_LIVE_WINDOW=minimized (no UI rendering during the measurement).
 *
 * CRT-free PE build: tools/build_livewin.sh (x86_64-w64-mingw32-gcc).
 * Run: tools/run_in_prefix.sh livewin.exe <cmd>   (needs the session's DISPLAY)
 *
 * usage: livewin <cmd>
 *   state      print the main window's hwnd, iconic, visible and foreground flags
 *   minimize   ShowWindowAsync(SW_MINIMIZE), then wait up to 5 s for IsIconic
 *   restore    ShowWindowAsync(SW_RESTORE) + SetForegroundWindow, then wait up to
 *              5 s until it is no longer iconic
 * Exit: 0 ok · 1 no Live window, or it did not reach the state · 2 usage.
 */

#include <windows.h>

static HANDLE g_out;
static char obuf[256];
static void emit( const char *s ) { DWORD n; WriteFile( g_out, s, lstrlenA( s ), &n, NULL ); }
#define P(...) do { wsprintfA( obuf, __VA_ARGS__ ); emit( obuf ); } while (0)

static void print_state( const char *cmd, HWND w )
{
    P( "%s: live hwnd=%p iconic=%d visible=%d foreground=%d\n", cmd, w,
       w ? (IsIconic( w ) ? 1 : 0) : 0, w ? (IsWindowVisible( w ) ? 1 : 0) : 0,
       w && GetForegroundWindow() == w ? 1 : 0 );
}

static BOOL wait_iconic( HWND w, BOOL want )
{
    int i;
    for (i = 0; i < 50; i++)
    {
        if ((IsIconic( w ) ? TRUE : FALSE) == want) return TRUE;
        Sleep( 100 );
    }
    return FALSE;
}

void __cdecl mainCRTStartup( void )
{
    char *s = GetCommandLineA();
    char cmd[32];
    int j = 0, ret = 0;
    HWND live;

    g_out = GetStdHandle( STD_OUTPUT_HANDLE );
    /* skip the program name, quoted or not */
    if (*s == '"') { s++; while (*s && *s != '"') s++; if (*s) s++; }
    else while (*s && *s != ' ') s++;
    while (*s == ' ') s++;
    while (*s && *s != ' ' && j < 31) cmd[j++] = *s++;
    cmd[j] = 0;

    live = FindWindowW( L"Ableton Live Window Class", NULL );
    if (!cmd[0] || !lstrcmpA( cmd, "state" ))
    {
        print_state( "state", live );
        ret = live ? 0 : 1;
    }
    else if (!lstrcmpA( cmd, "minimize" ))
    {
        if (live)
        {
            ShowWindowAsync( live, SW_MINIMIZE );
            ret = wait_iconic( live, TRUE ) ? 0 : 1;
        }
        else ret = 1;
        print_state( cmd, live );
    }
    else if (!lstrcmpA( cmd, "restore" ))
    {
        if (live)
        {
            ShowWindowAsync( live, SW_RESTORE );
            SetForegroundWindow( live );
            ret = wait_iconic( live, FALSE ) ? 0 : 1;
        }
        else ret = 1;
        print_state( cmd, live );
    }
    else
    {
        emit( "usage: livewin state|minimize|restore\n" );
        ret = 2;
    }
    ExitProcess( ret );
}
