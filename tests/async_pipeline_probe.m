/* Production prediction-slot coordination with a fake compiler; no GPU device
   is created and no command buffers are submitted. */
#import <Metal/Metal.h>
#import "nvn_async_compile.h"
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>

typedef struct { uint64_t id; } pso_key;
typedef NSObject NvShader;
static int g_pso;
static id hm_get_id(const int *map, const pso_key *key) { (void)map; (void)key; return nil; }
static MTLRenderPipelineDescriptor *pso_desc(const pso_key *k, NvShader *vs, NvShader *fs, id fn, int merged) {
    (void)k; (void)vs; (void)fs; (void)fn; (void)merged; return nil;
}
static dispatch_semaphore_t compilerStarted, compilerRelease;
static _Atomic int builds;
static void await_signal(dispatch_semaphore_t signal) {
    assert(!dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)));
}
@interface FakeCompiler : NSObject
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(id)descriptor error:(NSError **)error;
@end
@implementation FakeCompiler
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(id)descriptor error:(NSError **)error {
    (void)descriptor; (void)error; atomic_fetch_add(&builds,1);
    if (compilerStarted) dispatch_semaphore_signal(compilerStarted);
    if (compilerRelease) await_signal(compilerRelease);
    return (id<MTLRenderPipelineState>)[NSObject new];
}
@end
static FakeCompiler *g_dev;
#include "nvn_pso_pending.h"

int main(void) { @autoreleasepool {
    g_dev=[FakeCompiler new]; g_async_pso_cache=[[NVNCompileCache alloc] initWithLimit:64];
    pso_key key={42}, other={43}; NVNCompileState state;
    dispatch_semaphore_t started=dispatch_semaphore_create(0), release=dispatch_semaphore_create(0);
    __block int asyncBuilds=0;
    nvn_async_shaders_set(1,0);
    [g_async_pso_cache resultForKey:pso_async_key(&key) wait:NO build:^{
        asyncBuilds++; dispatch_semaphore_signal(started); await_signal(release); return [NSObject new];
    } state:&state];
    await_signal(started); nvn_async_shaders_set(0,0);
    pso_pend_kick(&key,nil,nil);
    assert(g_pp_kicked==0 && pso_pend_find(&key)==-1 && atomic_load(&builds)==0);
    /* Prediction still compiles unrelated keys and frees their slots. */
    pso_pend_kick(&other,nil,nil); int pending;
    assert(pso_pend_take(&other,YES,&pending) && !pending && pso_pend_find(&other)==-1);
    dispatch_semaphore_signal(release);
    assert([g_async_pso_cache resultForKey:pso_async_key(&key) wait:YES build:^id{ abort(); } state:&state]);
    pso_pend_kick(&key,nil,nil);
    assert(g_pp_kicked==1 && pso_pend_find(&key)==-1 && asyncBuilds==1);
    /* The opposite switch polls an existing prediction without discarding it. */
    pso_key reverse={44}; compilerStarted=dispatch_semaphore_create(0); compilerRelease=dispatch_semaphore_create(0);
    pso_pend_kick(&reverse,nil,nil); await_signal(compilerStarted);
    nvn_async_shaders_set(1,0);
    assert(!pso_pend_take(&reverse,NO,&pending) && pending);
    assert(pso_pend_find(&reverse)>=0);
    pso_pend_kick(&reverse,nil,nil); /* duplicate prediction is also coalesced */
    dispatch_semaphore_signal(compilerRelease);
    assert(pso_pend_take(&reverse,YES,&pending) && !pending);
    assert(pso_pend_find(&reverse)==-1 && g_pp_kicked==2 && atomic_load(&builds)==2);
    puts("pass: mode switches reuse pending work; no duplicate compilation or stranded prediction slots");
    return 0;
}}
