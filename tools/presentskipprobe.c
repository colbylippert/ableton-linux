/* presentskipprobe.c — checks Direct3D 11 presents, including the present skipping of patch 0110
 * (WINED3D_PRESENT_SKIP=N: wined3d shows only every Nth present of a swapchain and returns at once
 * for the others).
 *
 * Build: tools/build_presentskipprobe.sh (x86_64-w64-mingw32-gcc).
 * Run:   WINED3D_PRESENT_SKIP=6 tools/run_in_prefix.sh presentskipprobe.exe
 *        (and once without the switch, to compare the time per frame)
 *
 * Checks (PASS/FAIL, exit status = number of FAILs), each on a visible 640x360 window with a
 * two-buffer flip-model swap chain, 240 frames of clear + Present(1, 0):
 *   plain      every present returns S_OK and no frame takes 1 s or more
 *   waitable   frames paced by the frame-latency waitable object (maximum latency 1): every wait
 *              is signalled within 1 s (a skipped present that did not release the frame-latency
 *              semaphore would hang here) and every present returns S_OK
 * and reports the time per frame of each loop: with the switch on, only every Nth present waits
 * for the display, so the loops finish about N times faster.
 */

#define COBJMACROS
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_3.h>
#include <stdio.h>
#include <stdlib.h>

static int g_fail;

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

static void pump( void )
{
    MSG m;
    while (PeekMessageA( &m, NULL, 0, 0, PM_REMOVE ))
    {
        TranslateMessage( &m );
        DispatchMessageA( &m );
    }
}

static void run( ID3D11Device *dev, ID3D11DeviceContext *ctx, IDXGIFactory2 *factory, HWND hwnd, BOOL waitable )
{
    const char *name = waitable ? "waitable" : "plain";
    DXGI_SWAP_CHAIN_DESC1 desc = { 0 };
    IDXGISwapChain1 *sc = NULL;
    IDXGISwapChain2 *sc2 = NULL;
    ID3D11Texture2D *bb = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    HANDLE wait = NULL;
    int bad = 0, timeouts = 0, i;
    double worst = 0.0, t0, total;
    char detail[200];
    HRESULT hr;

    desc.Width = 640;
    desc.Height = 360;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    desc.Flags = waitable ? DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT : 0;
    hr = IDXGIFactory2_CreateSwapChainForHwnd( factory, (IUnknown *)dev, hwnd, &desc, NULL, NULL, &sc );
    if (FAILED(hr))
    {
        sprintf( detail, "CreateSwapChainForHwnd failed (%#lx)", (unsigned long)hr );
        result( FALSE, name, detail );
        return;
    }
    if (waitable)
    {
        if (FAILED(IDXGISwapChain1_QueryInterface( sc, &IID_IDXGISwapChain2, (void **)&sc2 )))
        {
            result( FALSE, name, "no IDXGISwapChain2" );
            IDXGISwapChain1_Release( sc );
            return;
        }
        IDXGISwapChain2_SetMaximumFrameLatency( sc2, 1 );
        wait = IDXGISwapChain2_GetFrameLatencyWaitableObject( sc2 );
    }
    IDXGISwapChain1_GetBuffer( sc, 0, &IID_ID3D11Texture2D, (void **)&bb );
    ID3D11Device_CreateRenderTargetView( dev, (ID3D11Resource *)bb, NULL, &rtv );

    t0 = now_s();
    for (i = 0; i < 240; i++)
    {
        const FLOAT colour[4] = { (i % 3) / 2.0f, 0.25f, 0.5f, 1.0f };
        double f0 = now_s(), f;

        if (wait && WaitForSingleObject( wait, 1000 ) != WAIT_OBJECT_0)
        {
            timeouts++;
            break;
        }
        ID3D11DeviceContext_OMSetRenderTargets( ctx, 1, &rtv, NULL );
        ID3D11DeviceContext_ClearRenderTargetView( ctx, rtv, colour );
        if (IDXGISwapChain1_Present( sc, 1, 0 ) != S_OK) bad++;
        f = now_s() - f0;
        if (f > worst) worst = f;
        pump();
    }
    total = now_s() - t0;
    sprintf( detail, "%d frames in %.2f s (%.2f ms per frame, worst %.0f ms), %d presents not S_OK%s",
             i, total, total * 1000.0 / (i ? i : 1), worst * 1000.0, bad,
             timeouts ? ", a frame-latency wait timed out" : "" );
    result( !bad && !timeouts && worst < 1.0, name, detail );

    ID3D11DeviceContext_OMSetRenderTargets( ctx, 0, NULL, NULL );
    ID3D11RenderTargetView_Release( rtv );
    ID3D11Texture2D_Release( bb );
    if (wait) CloseHandle( wait );
    if (sc2) IDXGISwapChain2_Release( sc2 );
    IDXGISwapChain1_Release( sc );
}

int main( void )
{
    const char *env = getenv( "WINED3D_PRESENT_SKIP" );
    WNDCLASSA wc = { 0 };
    ID3D11Device *dev;
    ID3D11DeviceContext *ctx;
    IDXGIDevice *dxgi_dev;
    IDXGIAdapter *adapter;
    IDXGIFactory2 *factory;
    D3D_FEATURE_LEVEL level;
    HWND hwnd;
    HRESULT hr;

    printf( "INFO switch    WINED3D_PRESENT_SKIP=%s\n", env ? env : "(unset)" );
    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA( NULL );
    wc.lpszClassName = "presentskipprobe";
    RegisterClassA( &wc );
    hwnd = CreateWindowA( "presentskipprobe", "presentskipprobe", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                          0, 0, 640, 360, NULL, NULL, wc.hInstance, NULL );
    pump();

    hr = D3D11CreateDevice( NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0,
                            D3D11_SDK_VERSION, &dev, &level, &ctx );
    if (FAILED(hr))
    {
        printf( "SKIP device    D3D11CreateDevice failed (%#lx)\n", (unsigned long)hr );
        return 0;
    }
    ID3D11Device_QueryInterface( dev, &IID_IDXGIDevice, (void **)&dxgi_dev );
    IDXGIDevice_GetAdapter( dxgi_dev, &adapter );
    IDXGIAdapter_GetParent( adapter, &IID_IDXGIFactory2, (void **)&factory );

    run( dev, ctx, factory, hwnd, FALSE );
    run( dev, ctx, factory, hwnd, TRUE );

    IDXGIFactory2_Release( factory );
    IDXGIAdapter_Release( adapter );
    IDXGIDevice_Release( dxgi_dev );
    ID3D11DeviceContext_Release( ctx );
    ID3D11Device_Release( dev );
    DestroyWindow( hwnd );
    return g_fail;
}
