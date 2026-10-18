#pragma once
/* Private renderer coordination, included after pso_key and pso_desc. The
   CPU-only probe substitutes a compiler to exercise the actual slot logic. */
#include <pthread.h>
#include <string.h>
#import "nvn_async_compile.h"

#define PSO_PEND_MAX 384
static NVNCompileCache *g_async_pso_cache;
static NSData *pso_async_key(const pso_key *key) { return [NSData dataWithBytes:key length:sizeof *key]; }
static struct { pso_key k; id<MTLRenderPipelineState> ps; int used, done; } g_pp[PSO_PEND_MAX];
static pthread_mutex_t g_pp_mu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t g_pp_cv = PTHREAD_COND_INITIALIZER;
static uint64_t g_pp_kicked;
static int pso_pend_find(const pso_key *k) { for (int i = 0; i < PSO_PEND_MAX; i++) if (g_pp[i].used && !memcmp(&g_pp[i].k, k, sizeof *k)) return i; return -1; }
static void pso_pend_kick(const pso_key *k, NvShader *vs, NvShader *fs) {   // 提交线程调：没在缓存、没在表里才丢 | Called by the submit thread: kick only if it is neither in the cache nor in the table
    if (hm_get_id(&g_pso, k) || (g_async_pso_cache && [g_async_pso_cache containsKey:pso_async_key(k)])) return;
    pthread_mutex_lock(&g_pp_mu);
    int at = pso_pend_find(k), slot = -1;
    if (at < 0) for (int i = 0; i < PSO_PEND_MAX; i++) if (!g_pp[i].used) { slot = i; break; }
    if (at < 0 && slot >= 0) { g_pp[slot].k = *k; g_pp[slot].ps = nil; g_pp[slot].done = 0; g_pp[slot].used = 1; }
    pthread_mutex_unlock(&g_pp_mu);
    if (at >= 0 || slot < 0) return;
    MTLRenderPipelineDescriptor *d = pso_desc(k, vs, fs, nil, 0); g_pp_kicked++;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *e = nil; id<MTLRenderPipelineState> ps = [g_dev newRenderPipelineStateWithDescriptor:d error:&e];
        pthread_mutex_lock(&g_pp_mu); g_pp[slot].ps = ps; g_pp[slot].done = 1; pthread_cond_broadcast(&g_pp_cv); pthread_mutex_unlock(&g_pp_mu);
    });
}
// A mode switch must also reuse predictions already running. Poll without
// consuming an unfinished slot in async mode; the waiting path joins it.
static id<MTLRenderPipelineState> pso_pend_take(const pso_key *k, BOOL wait, int *pending) {
    pthread_mutex_lock(&g_pp_mu);
    int at = pso_pend_find(k); id<MTLRenderPipelineState> ps = nil;
    *pending = 0;
    if (at >= 0) {
        while (wait && !g_pp[at].done) pthread_cond_wait(&g_pp_cv, &g_pp_mu);
        if (!g_pp[at].done) *pending = 1;
        else { ps = g_pp[at].ps; g_pp[at].ps = nil; g_pp[at].used = 0; }
    }
    pthread_mutex_unlock(&g_pp_mu);
    return ps;
}
