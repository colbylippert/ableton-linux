/* ntsl_stress.c: ntsync-live's native stress test and fan-out benchmark (profiler/plans/kernel-plan.md K3, gates E1,
 * G2 and G3). It talks to /dev/ntsync directly, like tools/syncbench_native.c, with Live's fan-out pattern: a
 * coordinator sets one manual-reset event per worker; each worker wakes, resets its event, does its share of the work,
 * and the last one sets the coordinator's auto-reset done event.
 *
 *   ntsl_stress torture [workers] [rounds]   the fan-out with 1 s timeouts: a timeout is a lost wake-up, a done event
 *                                            still signaled after its wait a double consumption; exit 1 on either
 *   ntsl_stress pingpong [rounds]            two threads and two auto-reset events, the same checks
 *   ntsl_stress bench [workers] [blocks] [work_us] [rounds_per_block] [period_us]
 *                                            PipeASIO-like: every period (default 1333 us) the coordinator runs
 *                                            rounds_per_block (default 5) rounds; prints the block time p50/p99 and
 *                                            the CPU time per round
 *
 * Threads are named like Live's (coordinator "pipeasio-rt", workers "AudioCalc") so ntsync-live's spin_comm gate
 * matches them, and asked for Live's priorities (SCHED_FIFO 15, SCHED_RR 10; it says so when that is refused). CPUs:
 * the coordinator on 0 and the workers on 2,4,6,8,10 (one per physical P-core), or NTSL_CPUS="c,w1,w2,...".
 * build: cc -O2 -pthread -I<repo>/vendor/ntsync-uapi -o ntsl_stress ntsl_stress.c
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/ntsync.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define MAXW 16
#define TIMEOUT_NS 1000000000ull

static int g_dev = -1;
static int g_cpus[MAXW + 1] = { 0, 2, 4, 6, 8, 10 }, g_ncpus = 6;
static int g_rt_refused;

static uint64_t now_ns( void )
{
    struct timespec ts;
    clock_gettime( CLOCK_MONOTONIC, &ts );
    return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

static uint64_t thread_cpu_ns( void )
{
    struct timespec ts;
    clock_gettime( CLOCK_THREAD_CPUTIME_ID, &ts );
    return (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

/* slot 0: the coordinator; slot i: worker i */
static void become( int slot )
{
    struct sched_param sp = { .sched_priority = slot ? 10 : 15 };
    cpu_set_t set;

    prctl( PR_SET_NAME, slot ? "AudioCalc" : "pipeasio-rt" );
    CPU_ZERO( &set );
    CPU_SET( g_cpus[slot % g_ncpus], &set );
    sched_setaffinity( 0, sizeof(set), &set );
    if (pthread_setschedparam( pthread_self(), slot ? SCHED_RR : SCHED_FIFO, &sp )) g_rt_refused = 1;
}

static int ev_create( int manual )
{
    struct ntsync_event_args args = { .manual = manual, .signaled = 0 };
    int fd = ioctl( g_dev, NTSYNC_IOC_CREATE_EVENT, &args );
    if (fd < 0) { perror( "NTSYNC_IOC_CREATE_EVENT" ); exit( 2 ); }
    return fd;
}

static void ev_set( int fd ) { __u32 prev; ioctl( fd, NTSYNC_IOC_EVENT_SET, &prev ); }
static void ev_reset( int fd ) { __u32 prev; ioctl( fd, NTSYNC_IOC_EVENT_RESET, &prev ); }

static int ev_signaled( int fd )
{
    struct ntsync_event_args args;
    if (ioctl( fd, NTSYNC_IOC_EVENT_READ, &args ) < 0) return -1;
    return args.signaled;
}

/* WAIT_ANY on one event with a 1 s timeout: 0 satisfied, 1 timed out */
static int ev_wait( int fd )
{
    __u32 obj = fd;
    struct ntsync_wait_args args = { .timeout = now_ns() + TIMEOUT_NS, .objs = (uintptr_t)&obj, .count = 1,
                                     .owner = (__u32)syscall( SYS_gettid ) };
    int ret;

    while ((ret = ioctl( g_dev, NTSYNC_IOC_WAIT_ANY, &args )) < 0 && errno == EINTR) ;
    if (ret < 0 && errno == ETIMEDOUT) return 1;
    if (ret < 0) { perror( "NTSYNC_IOC_WAIT_ANY" ); exit( 2 ); }
    return 0;
}

static void spin_us( unsigned int us )
{
    uint64_t end = now_ns() + us * 1000ull;
    while (now_ns() < end) ;
}

/* ---------- the fan-out ---------- */

static int g_work[MAXW], g_done, g_k;
static unsigned int g_work_us;
static _Atomic int g_left, g_stop;
static _Atomic long g_lost, g_worker_rounds;
static _Atomic uint64_t g_worker_cpu;

static void *worker( void *arg )
{
    int i = (int)(intptr_t)arg;
    uint64_t c0;

    become( i + 1 );
    c0 = thread_cpu_ns();
    for (;;)
    {
        if (ev_wait( g_work[i] ))
        {
            if (atomic_load( &g_stop )) break;
            atomic_fetch_add( &g_lost, 1 );
            continue;
        }
        if (atomic_load( &g_stop )) break;
        ev_reset( g_work[i] );
        if (g_work_us) spin_us( g_work_us );
        atomic_fetch_add( &g_worker_rounds, 1 );
        if (atomic_fetch_sub( &g_left, 1 ) == 1) ev_set( g_done );
    }
    atomic_fetch_add( &g_worker_cpu, thread_cpu_ns() - c0 );
    return NULL;
}

static void start_workers( pthread_t *th, int k, unsigned int work_us )
{
    int i;
    g_k = k; g_work_us = work_us;
    atomic_store( &g_stop, 0 );
    for (i = 0; i < k; i++) g_work[i] = ev_create( 1 );
    g_done = ev_create( 0 );
    for (i = 0; i < k; i++) pthread_create( &th[i], NULL, worker, (void *)(intptr_t)i );
    usleep( 20000 );
}

static void stop_workers( pthread_t *th )
{
    int i;
    atomic_store( &g_stop, 1 );
    for (i = 0; i < g_k; i++) ev_set( g_work[i] );
    for (i = 0; i < g_k; i++) pthread_join( th[i], NULL );
    for (i = 0; i < g_k; i++) close( g_work[i] );
    close( g_done );
}

/* one round: 0 ok, 1 the done event timed out, 2 it was still signaled afterwards */
static int round_once( void )
{
    int i;
    atomic_store( &g_left, g_k );
    for (i = 0; i < g_k; i++) ev_set( g_work[i] );
    if (ev_wait( g_done )) return 1;
    return ev_signaled( g_done ) == 1 ? 2 : 0;
}

static int cmp_u64( const void *a, const void *b )
{
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return x < y ? -1 : x > y;
}

static int torture( int k, long rounds )
{
    pthread_t th[MAXW];
    long r, timeouts = 0, doubles = 0;
    uint64_t t0;

    become( 0 );
    start_workers( th, k, 0 );
    t0 = now_ns();
    for (r = 0; r < rounds; r++)
    {
        int res = round_once();
        if (res == 1) { timeouts++; usleep( 1000 ); }   /* let the round drain before the next */
        if (res == 2) doubles++;
    }
    printf( "torture: %d workers, %ld rounds in %.2f s (%.2f us/round); lost wake-ups: %ld coordinator + %ld worker; "
            "double consumptions: %ld%s\n", k, rounds, (now_ns() - t0) / 1e9, (now_ns() - t0) / 1e3 / rounds,
            timeouts, (long)atomic_load( &g_lost ), doubles, g_rt_refused ? " (realtime priority refused)" : "" );
    stop_workers( th );
    return timeouts || atomic_load( &g_lost ) || doubles;
}

static int g_ping, g_pong;

static void *ponger( void *arg )
{
    long n = (long)(intptr_t)arg, i;
    become( 1 );
    for (i = 0; i < n; i++)
    {
        if (ev_wait( g_ping )) { atomic_fetch_add( &g_lost, 1 ); continue; }
        ev_set( g_pong );
    }
    return NULL;
}

static int pingpong( long rounds )
{
    pthread_t th;
    long i, timeouts = 0, doubles = 0;
    uint64_t t0;

    become( 0 );
    g_ping = ev_create( 0 ); g_pong = ev_create( 0 );
    pthread_create( &th, NULL, ponger, (void *)(intptr_t)rounds );
    usleep( 20000 );
    t0 = now_ns();
    for (i = 0; i < rounds; i++)
    {
        ev_set( g_ping );
        if (ev_wait( g_pong )) timeouts++;
        else if (ev_signaled( g_pong ) == 1) doubles++;
    }
    pthread_join( th, NULL );
    printf( "pingpong: %ld round trips in %.2f s (%.2f us each); lost wake-ups: %ld + %ld; double consumptions: %ld%s\n",
            rounds, (now_ns() - t0) / 1e9, (now_ns() - t0) / 1e3 / rounds, timeouts, (long)atomic_load( &g_lost ),
            doubles, g_rt_refused ? " (realtime priority refused)" : "" );
    close( g_ping ); close( g_pong );
    return timeouts || atomic_load( &g_lost ) || doubles;
}

static int bench( int k, long blocks, unsigned int work_us, int per_block, unsigned int period_us )
{
    pthread_t th[MAXW];
    uint64_t *t = calloc( blocks, sizeof(*t) ), next, c0, ccpu;
    long b, bad = 0;
    struct timespec ts;

    become( 0 );
    start_workers( th, k, work_us );
    atomic_store( &g_worker_cpu, 0 );
    c0 = thread_cpu_ns();
    next = now_ns() + 10000000ull;
    for (b = 0; b < blocks; b++)
    {
        uint64_t s;
        int r;
        ts.tv_sec = next / 1000000000ull; ts.tv_nsec = next % 1000000000ull;
        clock_nanosleep( CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL );
        s = now_ns();
        for (r = 0; r < per_block; r++) bad += round_once() != 0;
        t[b] = now_ns() - s;
        next += period_us * 1000ull;
    }
    ccpu = thread_cpu_ns() - c0;
    stop_workers( th );
    qsort( t, blocks, sizeof(*t), cmp_u64 );
    printf( "bench: %d workers, %ld blocks of %d rounds, %u us work per round, period %u us: block p50 %.1f us, p99 %.1f us, "
            "max %.1f us; CPU per round %.2f us (coordinator %.2f); bad rounds %ld%s\n", k, blocks, per_block, work_us,
            period_us, t[blocks / 2] / 1e3, t[blocks * 99 / 100] / 1e3, t[blocks - 1] / 1e3,
            (atomic_load( &g_worker_cpu ) + ccpu) / 1e3 / (blocks * per_block), ccpu / 1e3 / (blocks * per_block), bad,
            g_rt_refused ? " (realtime priority refused)" : "" );
    free( t );
    return bad != 0;
}

int main( int argc, char **argv )
{
    const char *mode = argc > 1 ? argv[1] : "torture", *cpus = getenv( "NTSL_CPUS" );

    if (cpus)
    {
        char *dup = strdup( cpus ), *tok, *save;
        g_ncpus = 0;
        for (tok = strtok_r( dup, ",", &save ); tok && g_ncpus <= MAXW; tok = strtok_r( NULL, ",", &save ))
            g_cpus[g_ncpus++] = atoi( tok );
        free( dup );
    }
    if ((g_dev = open( "/dev/ntsync", O_CLOEXEC | O_RDONLY )) < 0) { perror( "/dev/ntsync" ); return 2; }
    if (!strcmp( mode, "torture" ))
        return torture( argc > 2 ? atoi( argv[2] ) : 5, argc > 3 ? atol( argv[3] ) : 1000000 );
    if (!strcmp( mode, "pingpong" ))
        return pingpong( argc > 2 ? atol( argv[2] ) : 1000000 );
    if (!strcmp( mode, "bench" ))
        return bench( argc > 2 ? atoi( argv[2] ) : 5, argc > 3 ? atol( argv[3] ) : 20000, argc > 4 ? atoi( argv[4] ) : 10,
                      argc > 5 ? atoi( argv[5] ) : 5, argc > 6 ? atoi( argv[6] ) : 1333 );
    fprintf( stderr, "usage: ntsl_stress torture [workers] [rounds] | pingpong [rounds] | "
             "bench [workers] [blocks] [work_us] [rounds_per_block] [period_us]\n" );
    return 2;
}
