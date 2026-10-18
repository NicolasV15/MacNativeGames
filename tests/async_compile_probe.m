#import "nvn_async_compile.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static void await_signal(dispatch_semaphore_t signal) {
    assert(dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 5*NSEC_PER_SEC)) == 0);
}
int main(int argc, const char **argv) { @autoreleasepool {
    assert(argc == 2);
    unsetenv("TOTK_ASYNC_SHADERS");
    nvn_async_shaders_configure(argv[1]); assert(!nvn_async_shaders_enabled());
    NSString *path = [@(argv[1]) stringByAppendingPathComponent:@"graphics-settings.json"];
    [@"{\"other_setting\":42}" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    assert(nvn_async_shaders_set(1, 1)); nvn_async_shaders_set(0, 0);
    nvn_async_shaders_configure(argv[1]); assert(nvn_async_shaders_enabled());
    NSDictionary *settings = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] options:0 error:nil];
    assert([settings[@"other_setting"] intValue] == 42);
    setenv("TOTK_ASYNC_SHADERS", "0", 1); nvn_async_shaders_set(0, 0);
    nvn_async_shaders_configure(argv[1]); assert(!nvn_async_shaders_enabled());
    unsetenv("TOTK_ASYNC_SHADERS");

    NVNCompileCache *cache = [[NVNCompileCache alloc] initWithLimit:1];
    NVNCompileState state;
    dispatch_semaphore_t started=dispatch_semaphore_create(0), release=dispatch_semaphore_create(0);
    __block int builds=0;
    id result = [cache resultForKey:@"a" wait:NO build:^{
        ++builds; dispatch_semaphore_signal(started); await_signal(release); return @"compiled";
    } state:&state];
    assert(!result && state == NVNCompilePending); await_signal(started);
    for (int i=0;i<100;i++) {
        result = [cache resultForKey:@"a" wait:NO build:^id{ abort(); return nil; } state:&state];
        assert(!result && state == NVNCompilePending);
    }
    /* The bounded queue refuses new work without waiting and can retry later. */
    result = [cache resultForKey:@"b" wait:NO build:^id{ abort(); return nil; } state:&state];
    assert(!result && state == NVNCompilePending && ![cache containsKey:@"b"]);
    dispatch_semaphore_t joined=dispatch_semaphore_create(0), joining=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NVNCompileState s; dispatch_semaphore_signal(joining);
        id value=[cache resultForKey:@"a" wait:YES build:^id{ abort(); return nil; } state:&s];
        assert(s==NVNCompileReady && [value isEqual:@"compiled"]); dispatch_semaphore_signal(joined);
    });
    await_signal(joining);
    assert(dispatch_semaphore_wait(joined,dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_MSEC))!=0);
    dispatch_semaphore_signal(release); await_signal(joined);
    result=[cache resultForKey:@"a" wait:NO build:^id{ abort(); return nil; } state:&state];
    assert(state==NVNCompileReady && [result isEqual:@"compiled"] && builds==1);
    result=[cache resultForKey:@"b" wait:YES build:^{ return @"retried"; } state:&state];
    assert(state==NVNCompileReady && [result isEqual:@"retried"]);
    /* Failure is terminal and distinct from an unfinished build. */
    result=[cache resultForKey:@"failed" wait:YES build:^id{ return nil; } state:&state];
    assert(!result && state==NVNCompileFailed);
    result=[cache resultForKey:@"failed" wait:NO build:^id{ abort(); return nil; } state:&state];
    assert(!result && state==NVNCompileFailed);
    puts("pass: nonblocking polls, coalescing, bounded retry, blocking join, ready reuse, terminal failure, settings persistence");
    return 0;
}}
