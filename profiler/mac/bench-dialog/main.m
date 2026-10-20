// BenchDialog: answer Live 12 Trial's start-up dialog with "Save/Export Disabled" (demo mode) in the logged-in user's
// GUI session, as profiler/windows/bench-win.py's dismiss_dialog and profiler/bin/live-trial-dialog do on Windows and
// Linux. Run as an app (open -a BenchDialog.app --args [TIMEOUT_S]) so that macOS's Accessibility permission, which
// clicking another app's window needs, belongs to this app and not to the SSH session that starts it.
//
// It waits up to TIMEOUT_S (default 240) for a window of Live's titled exactly "Ableton Live 12 Trial", brings Live to
// the front and clicks the dialog's button at 23 % of its width and 93.5 % of its height (the layout the Windows and
// Linux clickers use). Exit status: 0 the dialog was answered, 1 it never appeared or stayed, 2 no Accessibility
// permission (the first run asks for it: System Settings > Privacy & Security > Accessibility).
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <unistd.h>

static NSString *const kDialogTitle = @"Ableton Live 12 Trial";

static pid_t live_pid(void)
{
    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications])
        if ([app.bundleIdentifier hasPrefix:@"com.ableton.live"])
            return app.processIdentifier;
    return 0;
}

// The dialog's frame in global display coordinates (origin top left, as CGEvent takes them).
static BOOL dialog_frame(pid_t pid, CGRect *frame)
{
    BOOL found = NO;
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    CFArrayRef windows = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&windows) == kAXErrorSuccess && windows) {
        for (CFIndex i = 0; i < CFArrayGetCount(windows) && !found; i++) {
            AXUIElementRef window = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
            CFStringRef title = NULL;
            if (AXUIElementCopyAttributeValue(window, kAXTitleAttribute, (CFTypeRef *)&title) != kAXErrorSuccess || !title)
                continue;
            if (CFStringCompare(title, (__bridge CFStringRef)kDialogTitle, 0) == kCFCompareEqualTo) {
                AXValueRef position = NULL, size = NULL;
                CGPoint p;
                CGSize s;
                if (AXUIElementCopyAttributeValue(window, kAXPositionAttribute, (CFTypeRef *)&position) == kAXErrorSuccess
                    && AXUIElementCopyAttributeValue(window, kAXSizeAttribute, (CFTypeRef *)&size) == kAXErrorSuccess
                    && AXValueGetValue(position, kAXValueCGPointType, &p) && AXValueGetValue(size, kAXValueCGSizeType, &s)) {
                    *frame = CGRectMake(p.x, p.y, s.width, s.height);
                    found = YES;
                }
                if (position)
                    CFRelease(position);
                if (size)
                    CFRelease(size);
            }
            CFRelease(title);
        }
        CFRelease(windows);
    }
    CFRelease(app);
    return found;
}

static void click(CGPoint point)
{
    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
    CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, down);
    usleep(60000);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(down);
    CFRelease(up);
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        double timeout = argc > 1 ? atof(argv[1]) : 240.0;
        NSDictionary *prompt = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
        if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)prompt)) {
            NSLog(@"BenchDialog: no Accessibility permission (System Settings > Privacy & Security > Accessibility)");
            return 2;
        }
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
        while ([deadline timeIntervalSinceNow] > 0) {
            pid_t pid = live_pid();
            CGRect frame;
            if (pid && dialog_frame(pid, &frame)) {
                usleep(1000000);                                       // let it finish drawing
                [[NSRunningApplication runningApplicationWithProcessIdentifier:pid]
                    activateWithOptions:NSApplicationActivateIgnoringOtherApps];
                usleep(300000);
                click(CGPointMake(frame.origin.x + frame.size.width * 0.23, frame.origin.y + frame.size.height * 0.935));
                usleep(1500000);
                if (!dialog_frame(pid, &frame)) {
                    NSLog(@"BenchDialog: answered Live's dialog");
                    return 0;
                }
            }
            usleep(500000);
        }
        NSLog(@"BenchDialog: the dialog did not appear, or stayed, within %.0f s", timeout);
        return 1;
    }
}
