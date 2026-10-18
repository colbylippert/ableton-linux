/* syncbench_native.c: the native-Linux floor for tools/syncbench.exe.
 *
 * Runs Live's worker fan-out pattern (one dispatcher sets one manual-reset event per
 * worker; each worker wakes, resets its event, decrements a counter, and the last one
 * sets the dispatcher's auto-reset done event) and a two-thread ping-pong, with no Wine
 * involved, on two event implementations:
 *   ntsync  the same /dev/ntsync ioctls Wine 11.13 uses (EVENT_SET, EVENT_RESET,
 *           WAIT_ANY), called directly
 *   futex   a minimal futex-based event (the cheapest Linux sleep/wake)
 * Subtracting gives Wine's own share (syncbench.exe minus ntsync) and the driver's share
 * (ntsync minus futex).
 *
 * build: gcc -O2 -pthread -o syncbench_native syncbench_native.c
 * run:   chrt -r 10 taskset -c 0-11 ./syncbench_native [workers] [rounds] [reps]
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/futex.h>
#include <linux/ntsync.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

static uint64_t now_ns( void )
{
    struct timespec ts;
    clock_gettime( CLOCK_MONOTONIC, &ts );
    return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

/* ---------- event implementations ---------- */

struct ev { int fd; _Atomic int word; int manual; };
static int g_dev = -1;
static int g_impl; /* 0 = ntsync, 1 = futex */

static void ev_init( struct ev *e, int manual )
{
    e->manual = manual;
    atomic_store( &e->word, 0 );
    if (!g_impl)
    {
        struct ntsync_event_args args = { .manual = manual, .signaled = 0 };
        e->fd = ioctl( g_dev, NTSYNC_IOC_CREATE_EVENT, &args );
        if (e->fd < 0) { perror( "NTSYNC_IOC_CREATE_EVENT" ); exit( 1 ); }
    }
}

static long futex( _Atomic int *uaddr, int op, int val )
{
    return syscall( SYS_futex, uaddr, op, val, NULL, NULL, 0 );
}

static void ev_set( struct ev *e )
{
    if (!g_impl) { __u32 prev; ioctl( e->fd, NTSYNC_IOC_EVENT_SET, &prev ); return; }
    if (atomic_exchange( &e->word, 1 ) == 0) futex( &e->word, FUTEX_WAKE_PRIVATE, e->manual ? 0x7fffffff : 1 );
}

static void ev_reset( struct ev *e )
{
    if (!g_impl) { __u32 prev; ioctl( e->fd, NTSYNC_IOC_EVENT_RESET, &prev ); return; }
    atomic_store( &e->word, 0 );
}

static void ev_wait( struct ev *e )
{
    if (!g_impl)
    {
        __u32 obj = e->fd;
        struct ntsync_wait_args args = { .timeout = UINT64_MAX, .objs = (uintptr_t)&obj, .count = 1 };
        while (ioctl( g_dev, NTSYNC_IOC_WAIT_ANY, &args ) < 0 && errno == EINTR) ;
        return;
    }
    for (;;)
    {
        if (e->manual) { if (atomic_load( &e->word )) return; }
        else { int one = 1; if (atomic_compare_exchange_strong( &e->word, &one, 0 )) return; }
        futex( &e->word, FUTEX_WAIT_PRIVATE, 0 );
    }
}

/* ---------- fan-out ---------- */

#define MAXW 64
static struct ev g_work[MAXW], g_done;
static _Atomic int g_left, g_stop;

static void *worker( void *arg )
{
    int idx = (int)(intptr_t)arg;
    for (;;)
    {
        ev_wait( &g_work[idx] );
        ev_reset( &g_work[idx] );
        if (atomic_load( &g_stop )) break;
        if (atomic_fetch_sub( &g_left, 1 ) == 1) ev_set( &g_done );
    }
    return NULL;
}

static double fanout( int k, int rounds, int reps )
{
    pthread_t th[MAXW];
    double best = 1e30;
    atomic_store( &g_stop, 0 );
    ev_init( &g_done, 0 );
    for (int w = 0; w < k; w++) { ev_init( &g_work[w], 1 ); pthread_create( &th[w], NULL, worker, (void *)(intptr_t)w ); }
    for (int r = -1; r < reps; r++)
    {
        uint64_t a = now_ns();
        for (int i = 0; i < (r < 0 ? 500 : rounds); i++)
        {
            atomic_store( &g_left, k );
            for (int w = 0; w < k; w++) ev_set( &g_work[w] );
            ev_wait( &g_done );
        }
        if (r >= 0) { double us = (now_ns() - a) / 1000.0 / rounds; if (us < best) best = us; }
    }
    atomic_store( &g_stop, 1 );
    for (int w = 0; w < k; w++) ev_set( &g_work[w] );
    for (int w = 0; w < k; w++) pthread_join( th[w], NULL );
    return best;
}

/* ---------- ping-pong ---------- */

static struct ev g_ping, g_pong;

static void *pong( void *arg )
{
    (void)arg;
    for (;;)
    {
        ev_wait( &g_ping );
        if (atomic_load( &g_stop )) break;
        ev_set( &g_pong );
    }
    return NULL;
}

static double pingpong( int rounds, int reps )
{
    pthread_t th;
    double best = 1e30;
    atomic_store( &g_stop, 0 );
    ev_init( &g_ping, 0 ); ev_init( &g_pong, 0 );
    pthread_create( &th, NULL, pong, NULL );
    for (int r = -1; r < reps; r++)
    {
        uint64_t a = now_ns();
        for (int i = 0; i < (r < 0 ? 1000 : rounds); i++) { ev_set( &g_ping ); ev_wait( &g_pong ); }
        if (r >= 0) { double us = (now_ns() - a) / 1000.0 / rounds; if (us < best) best = us; }
    }
    atomic_store( &g_stop, 1 ); ev_set( &g_ping );
    pthread_join( th, NULL );
    return best;
}

/* ---------- per-call costs (ntsync only) ---------- */

static double per_call( int which, int iters )
{
    struct ev e;
    ev_init( &e, 1 );
    if (which == 2) ev_set( &e );
    uint64_t a = now_ns();
    for (int i = 0; i < iters; i++)
    {
        if (which == 0) ev_set( &e );
        else if (which == 1) ev_reset( &e );
        else ev_wait( &e );
    }
    return (double)(now_ns() - a) / iters;
}

int main( int argc, char **argv )
{
    int k = argc > 1 ? atoi( argv[1] ) : 15;
    int rounds = argc > 2 ? atoi( argv[2] ) : 20000;
    int reps = argc > 3 ? atoi( argv[3] ) : 5;
    if (k < 1 || k > MAXW) k = 15;
    g_dev = open( "/dev/ntsync", O_RDWR | O_CLOEXEC );
    if (g_dev < 0) { perror( "/dev/ntsync" ); return 1; }

    g_impl = 0;
    printf( "ntsync  set %.1f ns  reset %.1f ns  wait(signaled) %.1f ns\n",
            per_call( 0, 200000 ), per_call( 1, 200000 ), per_call( 2, 200000 ) );
    printf( "ntsync  pingpong %.2f us  fanout%d %.2f us\n", pingpong( rounds, reps ), k, fanout( k, rounds, reps ) );
    g_impl = 1;
    printf( "futex   pingpong %.2f us  fanout%d %.2f us\n", pingpong( rounds, reps ), k, fanout( k, rounds, reps ) );
    return 0;
}
