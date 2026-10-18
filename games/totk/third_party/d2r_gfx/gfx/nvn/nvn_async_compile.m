#import "nvn_async_compile.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

static _Atomic int enabled;
static NSString *settingsPath; /* configured and saved by the main thread */
int nvn_async_shaders_enabled(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *value = getenv("TOTK_ASYNC_SHADERS");
        atomic_store(&enabled, value && !strcmp(value, "1"));
    });
    return atomic_load(&enabled);
}
void nvn_async_shaders_configure(const char *profile) {
    (void)nvn_async_shaders_enabled();
    settingsPath = profile && *profile ? [@(profile) stringByAppendingPathComponent:@"graphics-settings.json"] : nil;
    const char *override = getenv("TOTK_ASYNC_SHADERS");
    if (override) { atomic_store(&enabled, !strcmp(override, "1")); return; }
    NSData *data = settingsPath ? [NSData dataWithContentsOfFile:settingsPath] : nil;
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    id value = [json isKindOfClass:NSDictionary.class] ? json[@"async_shaders"] : nil;
    atomic_store(&enabled, [value isKindOfClass:NSNumber.class] && [value boolValue]);
}
int nvn_async_shaders_set(int value, int persist) {
    (void)nvn_async_shaders_enabled();
    atomic_store(&enabled, !!value);
    fprintf(stderr, "[async-shaders] %s: pending render work %s; compute still waits\n",
            value ? "on" : "off", value ? "is skipped" : "waits");
    if (!persist || !settingsPath) return 1;
    NSData *old = [NSData dataWithContentsOfFile:settingsPath];
    id json = old ? [NSJSONSerialization JSONObjectWithData:old options:0 error:nil] : nil;
    NSMutableDictionary *settings = [json isKindOfClass:NSDictionary.class] ? [json mutableCopy] : [NSMutableDictionary dictionary];
    settings[@"async_shaders"] = @(!!value);
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:settings options:NSJSONWritingPrettyPrinted error:&error];
    if (data && [NSFileManager.defaultManager createDirectoryAtPath:settingsPath.stringByDeletingLastPathComponent
                                     withIntermediateDirectories:YES attributes:nil error:&error] &&
        [data writeToFile:settingsPath options:NSDataWritingAtomic error:&error]) return 1;
    fprintf(stderr, "[async-shaders] could not save setting: %s\n", error.localizedDescription.UTF8String);
    return 0;
}

@interface NVNCompileJob : NSObject
@property BOOL done;
@property(strong) id result;
@end
@implementation NVNCompileJob @end

@implementation NVNCompileCache {
    NSCondition *_condition;
    NSMutableDictionary *_jobs;
    dispatch_queue_t _queue;
    NSUInteger _pending, _limit;
}
- (instancetype)initWithLimit:(NSUInteger)limit {
    if ((self = [super init])) {
        _condition = [NSCondition new]; _jobs = [NSMutableDictionary dictionary]; _limit = MAX(1, limit);
        _queue = dispatch_queue_create("mng.shader-compile", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    }
    return self;
}
- (void)finish:(NVNCompileJob *)job build:(id (^)(void))build {
    @autoreleasepool {
        id result = build();
        [_condition lock];
        job.result = result; job.done = YES; --_pending;
        [_condition broadcast]; [_condition unlock];
    }
}
- (BOOL)containsKey:(id<NSCopying>)key {
    [_condition lock]; BOOL found = _jobs[key] != nil; [_condition unlock]; return found;
}
- (id)resultForKey:(id<NSCopying>)key wait:(BOOL)wait build:(id (^)(void))build state:(NVNCompileState *)state {
    [_condition lock];
    NVNCompileJob *job = _jobs[key];
    if (!job) {
        if (!wait && _pending >= _limit) {
            [_condition unlock]; *state = NVNCompilePending; return nil; /* retry next frame */
        }
        job = [NVNCompileJob new]; _jobs[key] = job; ++_pending;
        if (wait) {
            [_condition unlock]; [self finish:job build:build]; [_condition lock];
        } else dispatch_async(_queue, ^{ [self finish:job build:build]; });
    }
    while (wait && !job.done) [_condition wait];
    *state = !job.done ? NVNCompilePending : job.result ? NVNCompileReady : NVNCompileFailed;
    id result = job.result;
    [_condition unlock];
    return result;
}
@end
