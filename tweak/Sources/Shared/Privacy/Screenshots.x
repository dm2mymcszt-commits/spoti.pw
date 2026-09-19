// Fork: Ignore screenshots. Spotify listens for UIApplicationUserDidTakeScreenshotNotification and answers
// a screenshot of the player, a page or the lyrics with its share sheet (Screenshot_ScreenshotDetectionImpl:
// ScreenshotDetectionService, NPVScreenshotHandler, EntityPageScreenshotHandler, PresentScreenshotShareMenu-
// EffectHandler; the ads' AdScreenshotDetector listens too). No flag turns it off in 9.1.78 -- the only
// screenshot flag is the ads' -- so with the switch on the notification is not delivered in Spotify at all,
// and nothing in it hears of a screenshot. Read at launch.
#import "Core/SGCore.h"
#import "Privacy.h"

static BOOL isScreenshot(NSNotificationName name) {
    if (name != UIApplicationUserDidTakeScreenshotNotification && ![name isEqualToString:UIApplicationUserDidTakeScreenshotNotification]) return NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"privacy: a screenshot kept from Spotify"); });
    return YES;
}

%hook NSNotificationCenter
- (void)postNotification:(NSNotification *)notification {
    if (isScreenshot(notification.name)) return;
    %orig;
}

- (void)postNotificationName:(NSNotificationName)name object:(id)object {
    if (isScreenshot(name)) return;
    %orig;
}

- (void)postNotificationName:(NSNotificationName)name object:(id)object userInfo:(NSDictionary *)userInfo {
    if (isScreenshot(name)) return;
    %orig;
}
%end

%ctor {
    if (!SGHidden(SGKeyIgnoreScreenshots)) return;
    %init;
}
