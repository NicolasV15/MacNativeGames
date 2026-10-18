#import "nvn_async_compile.h"
#include <assert.h>
#include <stdio.h>

static void await_signal(dispatch_semaphore_t signal) {
    assert(!dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)));
}
int main(void) { @autoreleasepool {
    NVNCompileCache *cache = [[NVNCompileCache alloc] initWithLimit:64];
    NVNCompileState state;
    __weak id released;
    for (int i=0; i<300; i++) {
        NSString *key=[NSString stringWithFormat:@"warm-%d",i];
        @autoreleasepool {
            id object=[cache transientResultForKey:key build:^{ return [NSObject new]; } state:&state];
            assert(state==NVNCompileReady && object);
            released=object;
        }
        assert(!released && ![cache containsKey:key]);
    }
    /* A render request joining a warm-only job promotes its ownership without
       compiling again. The warm caller may then drop its temporary reference. */
    dispatch_semaphore_t started=dispatch_semaphore_create(0), release=dispatch_semaphore_create(0), done=dispatch_semaphore_create(0);
    __block int builds=0;
    __block __weak id shared;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        @autoreleasepool {
            NVNCompileState s;
            id object=[cache transientResultForKey:@"shared" build:^{
                builds++; dispatch_semaphore_signal(started); await_signal(release); return [NSObject new];
            } state:&s];
            assert(s==NVNCompileReady); shared=object;
        }
        dispatch_semaphore_signal(done);
    });
    await_signal(started);
    assert(![cache resultForKey:@"shared" wait:NO build:^id{ abort(); } state:&state]);
    assert(state==NVNCompilePending);
    dispatch_semaphore_signal(release); await_signal(done);
    id result=[cache resultForKey:@"shared" wait:YES build:^id{ abort(); } state:&state];
    assert(state==NVNCompileReady && result==shared && builds==1);
    /* Transient callers cannot evict an already-resident result or failure. */
    assert([cache transientResultForKey:@"shared" build:^id{ abort(); } state:&state]==result);
    assert([cache containsKey:@"shared"]);
    assert(![cache transientResultForKey:@"warm-failure" build:^id{ return nil; } state:&state]);
    assert(state==NVNCompileFailed && ![cache containsKey:@"warm-failure"]);
    assert(![cache resultForKey:@"failure" wait:YES build:^id{ return nil; } state:&state]);
    assert(![cache transientResultForKey:@"failure" build:^id{ abort(); } state:&state]);
    assert(state==NVNCompileFailed && [cache containsKey:@"failure"]);
    puts("pass: transient warm results release, in-flight render promotion coalesces, resident results survive");
    return 0;
}}
