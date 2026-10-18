/* UI-only integration probe: real frontend controls, no guest and no GPU
   commands. Compile with -undefined dynamic_lookup for unused runtime hooks. */
#include "../games/totk/runtime/frontend.m"
#include <assert.h>

uint64_t runtime_now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
uint64_t dm_nvn_frame_count(void) { return 0; }
void runtime_gamepad_start(void) {}
void runtime_input_clear(void) {}
void runtime_oe_push_message(uint32_t message) { (void)message; }
void hle_signal_system_event(void *event) { (void)event; }
static void no_guest(void) {}

int main(int argc, const char **argv) { @autoreleasepool {
    assert(argc == 2);
    setenv("TOTK_PROFILE_DIR",argv[1],1);
    setenv("TOTK_ASSUME_FOCUS","1",1);
    setenv("TOTK_WINDOW_SIZE","1280x720",1);
    unsetenv("TOTK_ASYNC_SHADERS");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
        assert(asyncShaderCheckbox && asyncShaderMenuItem);
        assert(!nvn_async_shaders_enabled());
        assert([NSApp.mainMenu itemWithTitle:@"图形"].submenu);
        /* Render only the opaque AppKit startup view, never the Metal layer. */
        NSBitmapImageRep *rep=[bootOverlay bitmapImageRepForCachingDisplayInRect:bootOverlay.bounds];
        [bootOverlay cacheDisplayInRect:bootOverlay.bounds toBitmapImageRep:rep];
        NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        assert([png writeToFile:[@(argv[1]) stringByAppendingPathComponent:@"startup-controls.png"] atomically:YES]);
        [asyncShaderCheckbox performClick:nil];
        assert(nvn_async_shaders_enabled() && asyncShaderMenuItem.state==NSControlStateValueOn);
        [graphicsSettings toggleAsyncShaders:asyncShaderMenuItem];
        assert(!nvn_async_shaders_enabled() && asyncShaderCheckbox.state==NSControlStateValueOff);
        [asyncShaderCheckbox performClick:nil];
        runtime_warm_progress(1,100,1,100,0,0);
        front_frame_presented(); /* exercise overlay policy only; no GPU frame */
        dispatch_async(dispatch_get_main_queue(),^{
            assert(bootOverlay.hidden);
            nvn_async_shaders_set(0,0);
            nvn_async_shaders_configure(argv[1]); assert(nvn_async_shaders_enabled());
            puts("pass: startup checkbox, graphics menu, both toggles, persistence, async overlay release (UI only)");
            fflush(stdout); _exit(0);
        });
    });
    runtime_front_run(no_guest);
}}
