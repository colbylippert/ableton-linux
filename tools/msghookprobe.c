/* msghookprobe.c — checks window-message delivery on a thread that owns a Direct3D 11 swap chain,
 * and shows the cost of wined3d's Alt+Enter message hook (patch 0111: WINED3D_NO_ALT_ENTER_HOOK=1
 * keeps wined3d from installing it).
 *
 * Build: tools/build_msghookprobe.sh (x86_64-w64-mingw32-gcc).
 * Run:   WINED3D_NO_ALT_ENTER_HOOK=1 tools/run_in_prefix.sh msghookprobe.exe
 *        (and once without the switch, to compare)
 *
 * The probe posts 20,000 messages to its own window and drains them (GetMessage + DispatchMessage), once
 * before it creates a swap chain on the window and once after. wined3d registers the window when the swap
 * chain is created and, unless the switch is set, hooks the thread's messages (WH_GETMESSAGE).
 * Checks (PASS/FAIL, exit status = number of FAILs):
 *   before     every posted message arrives, in order, and no batch takes 10 s or more
 *   after      the same with the swap chain in place
 * and reports the time per message before and after: with the hook each message after the swap chain costs
 * several more wineserver round trips; with the switch it costs about the same as before.
 */

#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdio.h>
#include <stdlib.h>

#define BATCH 5000
#define BATCHES 4

static int g_fail;
static LONG g_seen;
static LONG g_next;
static int g_order_bad;

static void result( BOOL ok, const char *name, const char *detail )
{
    printf( "%s %-9s %s\n", ok ? "PASS" : "FAIL", name, detail );
    if (!ok) g_fail++;
}

static double now_s( void )
{
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency( &f );
    QueryPerformanceCounter( &c );
    return (double)c.QuadPart / (double)f.QuadPart;
}

static LRESULT CALLBACK wndproc( HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam )
{
    if (msg == WM_APP)
    {
        if ((LONG)wparam != g_next) g_order_bad = 1;
        g_next = (LONG)wparam + 1;
        g_seen++;
        return 0;
    }
    return DefWindowProcA( hwnd, msg, wparam, lparam );
}

/* posts BATCHES x BATCH messages and drains each batch; returns microseconds per message, or -1 */
static double round_trip( HWND hwnd, const char *name )
{
    int b, i;
    double t0 = now_s(), worst = 0.0, total;
    char detail[160];
    MSG m;

    g_seen = 0; g_next = 0; g_order_bad = 0;
    for (b = 0; b < BATCHES; b++)
    {
        double b0 = now_s();
        LONG want = (b + 1) * BATCH;

        for (i = 0; i < BATCH; i++) PostMessageA( hwnd, WM_APP, b * BATCH + i, 0 );
        while (g_seen < want && now_s() - b0 < 10.0)
        {
            if (GetMessageA( &m, NULL, 0, 0 ) <= 0) break;
            TranslateMessage( &m );
            DispatchMessageA( &m );
        }
        if (now_s() - b0 > worst) worst = now_s() - b0;
    }
    total = now_s() - t0;
    sprintf( detail, "%ld of %d messages, %s, %.2f us per message (worst batch %.0f ms)",
             (long)g_seen, BATCH * BATCHES, g_order_bad ? "OUT OF ORDER" : "in order",
             total * 1e6 / (BATCH * BATCHES), worst * 1000.0 );
    result( g_seen == BATCH * BATCHES && !g_order_bad && worst < 10.0, name, detail );
    return g_seen == BATCH * BATCHES ? total * 1e6 / (BATCH * BATCHES) : -1.0;
}

int main( void )
{
    const char *env = getenv( "WINED3D_NO_ALT_ENTER_HOOK" );
    WNDCLASSA wc = { 0 };
    DXGI_SWAP_CHAIN_DESC1 desc = { 0 };
    ID3D11Device *dev;
    ID3D11DeviceContext *ctx;
    IDXGIDevice *dxgi_dev;
    IDXGIAdapter *adapter;
    IDXGIFactory2 *factory;
    IDXGISwapChain1 *sc;
    D3D_FEATURE_LEVEL level;
    double before, after;
    HWND hwnd;
    HRESULT hr;

    setvbuf( stdout, NULL, _IONBF, 0 );
    printf( "INFO switch    WINED3D_NO_ALT_ENTER_HOOK=%s\n", env ? env : "(unset)" );
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA( NULL );
    wc.lpszClassName = "msghookprobe";
    RegisterClassA( &wc );
    hwnd = CreateWindowA( "msghookprobe", "msghookprobe", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                          0, 0, 320, 200, NULL, NULL, wc.hInstance, NULL );

    hr = D3D11CreateDevice( NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0,
                            D3D11_SDK_VERSION, &dev, &level, &ctx );
    if (FAILED(hr))
    {
        printf( "SKIP device    D3D11CreateDevice failed (%#lx)\n", (unsigned long)hr );
        return 0;
    }
    before = round_trip( hwnd, "before" );

    ID3D11Device_QueryInterface( dev, &IID_IDXGIDevice, (void **)&dxgi_dev );
    IDXGIDevice_GetAdapter( dxgi_dev, &adapter );
    IDXGIAdapter_GetParent( adapter, &IID_IDXGIFactory2, (void **)&factory );
    desc.Width = 320;
    desc.Height = 200;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    hr = IDXGIFactory2_CreateSwapChainForHwnd( factory, (IUnknown *)dev, hwnd, &desc, NULL, NULL, &sc );
    if (FAILED(hr))
    {
        printf( "SKIP swapchain CreateSwapChainForHwnd failed (%#lx)\n", (unsigned long)hr );
        return g_fail;
    }
    after = round_trip( hwnd, "after" );
    if (before > 0 && after > 0)
        printf( "INFO hook      %.2f us per message before the swap chain, %.2f after (%+.2f)\n",
                before, after, after - before );

    IDXGISwapChain1_Release( sc );
    IDXGIFactory2_Release( factory );
    IDXGIAdapter_Release( adapter );
    IDXGIDevice_Release( dxgi_dev );
    ID3D11DeviceContext_Release( ctx );
    ID3D11Device_Release( dev );
    DestroyWindow( hwnd );
    return g_fail;
}
