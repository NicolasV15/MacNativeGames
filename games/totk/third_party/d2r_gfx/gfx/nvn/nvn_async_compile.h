#pragma once

int nvn_async_shaders_enabled(void);
void nvn_async_shaders_configure(const char *profile);
int nvn_async_shaders_set(int enabled, int persist);

#ifdef __OBJC__
#import <Foundation/Foundation.h>
typedef NS_ENUM(int, NVNCompileState) {
    NVNCompilePending, NVNCompileReady, NVNCompileFailed
};
/* One build per immutable key. Polling never waits for a compiler. A bounded,
   serial worker leaves CPU capacity for the game; blocking callers join an
   existing job, including when the user turns asynchronous mode off. */
@interface NVNCompileCache : NSObject
- (instancetype)initWithLimit:(NSUInteger)limit;
- (BOOL)containsKey:(id<NSCopying>)key;
- (id)resultForKey:(id<NSCopying>)key wait:(BOOL)wait
             build:(id (^)(void))build state:(NVNCompileState *)state;
@end
#endif
