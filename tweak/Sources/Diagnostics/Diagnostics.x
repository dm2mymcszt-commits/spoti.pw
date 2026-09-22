// Screen dumps for FLEX builds. The tree of the visible screen is served over HTTP on the phone's
// loopback (fetched from the Mac through `iproxy` over USB), and also logged when the app goes to
// the background or the full player appears.
#import "Core/SGCore.h"
#import "Diagnostics.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <dlfcn.h>
#import <objc/message.h>

static const uint16_t kTreePort = 8085;

static NSString *hexColor(CGColorRef color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [[UIColor colorWithCGColor:color] getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"#%02X%02X%02X@%.2f", (int)(r * 255), (int)(g * 255), (int)(b * 255), a];
}

static void appendTree(UIView *view, NSUInteger depth, NSMutableString *out) {
    NSMutableString *line = [NSMutableString stringWithFormat:@"%*s%@ %@", (int)depth * 2, "", NSStringFromClass(view.class), NSStringFromCGRect(view.frame)];
    CGColorRef bg = view.layer.backgroundColor;
    if (bg && CGColorGetAlpha(bg) > 0) [line appendFormat:@" bg=%@", hexColor(bg)];
    if (view.layer.cornerRadius > 0) [line appendFormat:@" r=%.1f", view.layer.cornerRadius];
    if (view.alpha < 1) [line appendFormat:@" a=%.2f", view.alpha];
    if (view.hidden) [line appendString:@" hidden"];
    if (view.layer.mask) [line appendString:@" masked"];
    if (view.clipsToBounds) [line appendString:@" clips"];
    if (view.accessibilityIdentifier.length) [line appendFormat:@" id=%@", view.accessibilityIdentifier];
    if ([view isKindOfClass:UIControl.class] && view.accessibilityLabel.length) [line appendFormat:@" a11y=\"%@\"", view.accessibilityLabel];
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        [line appendFormat:@" \"%@\" %.0fpt %@", label.text, label.font.pointSize, hexColor(label.textColor.CGColor)];
    }
    // Fork: what the view's own sublayers paint, which a view's line never showed and which is where
    // black bands over a page's field came from (device, 2026-09-20).
    for (CALayer *sub in view.layer.sublayers) {
        if (sub.delegate) continue;
        CGColorRef subBg = sub.backgroundColor;
        if (subBg && CGColorGetAlpha(subBg) > 0) [line appendFormat:@" sub=%@%@", hexColor(subBg), sub.hidden ? @"(hidden)" : @""];
    }
    if ([view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image) {
        CGSize size = ((UIImageView *)view).image.size;
        [line appendFormat:@" img=%.0fx%.0f", size.width, size.height];
    }
    [out appendString:line];
    [out appendString:@"\n"];
    for (UIView *sub in view.subviews) appendTree(sub, depth + 1, out);
}

BOOL SGIsDebugBuild(void) {
    return NSClassFromString(@"FLEXManager") != nil;
}

// What the mod has set, so a recorded tree says whether it shows Spotify as it came or a screen some
// switch has already changed: the stock marker Reset all settings leaves, then every key of the mod's
// with its value. The counters, the update check, the signing warning, the tour and the Musixmatch
// token belong to the install rather than to a choice, as in About/Backup.m, and are left out.
// scripts/record-session.py reads this section to call a snapshot clean or not.
static NSString *describeValue(id value) {
    if ([value isKindOfClass:NSArray.class] || [value isKindOfClass:NSDictionary.class]) {
        return [NSString stringWithFormat:@"%@%lu", [value isKindOfClass:NSArray.class] ? @"list:" : @"map:", (unsigned long)[value count]];
    }
    if ([value isKindOfClass:NSString.class]) {
        NSString *text = value;
        return [NSString stringWithFormat:@"\"%@\"", text.length > 40 ? [[text substringToIndex:40] stringByAppendingString:@"…"] : text];
    }
    return [value description];
}

static void appendModState(NSMutableString *out) {
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier] ?: @{};
    [out appendFormat:@"== mod\nstock %@\n", [stored[SGKeyStock] boolValue] ? @"yes" : @"no"];
    NSArray<NSString *> *local = @[@"spotifyglass.adblock.counts", @"spotifyglass.privacy.counts", @"spotifyglass.update.",
                                   @"spotifyglass.signing.", @"spotifyglass.onboarding.", @"spotifyglass.navbar.stock", @"spotifyglass.redesign.navbar.stock",
                                   @"spotifyglass.musixmatch.token"];
    for (NSString *key in [stored.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (![key hasPrefix:@"spotifyglass."] || [key isEqualToString:SGKeyStock]) continue;
        BOOL skip = NO;
        for (NSString *prefix in local) skip |= [key hasPrefix:prefix];
        if (!skip) [out appendFormat:@"%@ = %@\n", key, describeValue(stored[key])];
    }
}

NSString *SGScreenTree(void) {
    NSMutableString *out = [NSMutableString string];
    UIViewController *root = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || [NSStringFromClass(window.class) containsString:@"FLEX"]) continue;
            if (!root || window.isKeyWindow) root = window.rootViewController;
            [out appendFormat:@"== window %@ level %.0f\n", window.class, window.windowLevel];
            appendTree(window, 0, out);
        }
    }
    if ([root respondsToSelector:@selector(_printHierarchy)]) {
        [out appendFormat:@"== view controllers\n%@\n", [root _printHierarchy]];
    }
    appendModState(out);
    return out;
}

void SGDumpScreen(NSString *reason) {
    SGLogLong([@"screen dump " stringByAppendingString:reason], SGScreenTree());
}

// GET anything on 127.0.0.1:kTreePort answers with the current screen's tree as text/plain.
static void sendAll(int client, NSData *data) {
    const uint8_t *p = data.bytes;
    size_t left = data.length;
    while (left > 0) {
        ssize_t n = send(client, p, left, 0);
        if (n <= 0) return;
        p += n;
        left -= (size_t)n;
    }
}

static void startTreeServer(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kTreePort);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 4) != 0) {
        SGLog(@"tree server: could not listen on %u", kTreePort);
        close(fd);
        return;
    }
    static dispatch_source_t source;
    source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_event_handler(source, ^{
        int client = accept(fd, NULL, NULL);
        if (client < 0) return;
        struct timeval timeout = {2, 0};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        char request[1024];
        recv(client, request, sizeof(request), 0);
        __block NSString *body = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{ body = SGScreenTree(); });
        NSData *data = [body dataUsingEncoding:NSUTF8StringEncoding];
        NSString *head = [NSString stringWithFormat:@"HTTP/1.0 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)data.length];
        sendAll(client, [head dataUsingEncoding:NSUTF8StringEncoding]);
        sendAll(client, data);
        close(client);
    });
    dispatch_resume(source);
    SGLog(@"tree server on 127.0.0.1:%u; on the Mac: iproxy %u:%u, then GET http://127.0.0.1:%u/tree", kTreePort, kTreePort, kTreePort, kTreePort);
}

#pragma mark - fork: a dump to share, without a Mac

// The last ten minutes of this process's [spotifyglass] lines, read back from the unified log through
// OSLogStore (iOS 15+), looked up at run time since the tweak doesn't link OSLog.framework.
static NSString *recentLog(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dlopen("/System/Library/Frameworks/OSLog.framework/OSLog", RTLD_LAZY); });
    Class storeClass = NSClassFromString(@"OSLogStore");
    if (!storeClass) return @"OSLogStore unavailable\n";
    NSError *error = nil;
    // OSLogStoreCurrentProcessIdentifier
    id store = ((id (*)(Class, SEL, NSInteger, NSError **))objc_msgSend)(storeClass, NSSelectorFromString(@"storeWithScope:error:"), 1, &error);
    if (!store) return [NSString stringWithFormat:@"no log store: %@\n", error];
    id position = ((id (*)(id, SEL, NSTimeInterval))objc_msgSend)(store, NSSelectorFromString(@"positionWithTimeIntervalSinceEnd:"), -600);
    NSEnumerator *entries = ((id (*)(id, SEL, NSUInteger, id, id, NSError **))objc_msgSend)(store,
        NSSelectorFromString(@"entriesEnumeratorWithOptions:position:predicate:error:"), 0, position, nil, &error);
    if (!entries) return [NSString stringWithFormat:@"no log entries: %@\n", error];
    NSDateFormatter *format = [NSDateFormatter new];
    format.dateFormat = @"HH:mm:ss.SSS";
    NSMutableString *out = [NSMutableString string];
    for (id entry in entries) {
        NSString *message = [entry valueForKey:@"composedMessage"];
        if (![message containsString:@"[spotifyglass]"]) continue;
        [out appendFormat:@"%@ %@\n", [format stringFromDate:[entry valueForKey:@"date"]], message];
    }
    return out;
}

// A three-finger long press anywhere, a shake, or the Mod page's timed row: the screen as it is and the log
// so far go into one text file, handed to the share sheet so it can be saved or sent to a computer. Nothing
// listens on the network. The shake and the timer are there for the screens a press does not reach: with a
// text field in use iOS keeps three-finger touches for its own editing gestures (Search's recent searches,
// device, 2026-09-21).
//
// The sheet comes up in a window of its own, over everything. Shown from the top of the app's presented
// controllers it depended on Spotify's: the player's overlay container stays presented with the player shut
// (dumps/1.txt, 2.txt), and once that chain was in a state iOS would not present from, every press and shake
// was dropped without a word (device, 2026-09-22).
static UIWindow *sg_shareWindow;

static UIWindowScene *sceneFor(UIWindow *window) {
    if (window.windowScene) return window.windowScene;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
    }
    return nil;
}

static void presentShare(NSURL *file, UIWindowScene *scene) {
    if (!scene) {
        SGLog(@"dump: no scene to show the share sheet in");
        return;
    }
    if (!sg_shareWindow || sg_shareWindow.windowScene != scene) {
        sg_shareWindow = [[UIWindow alloc] initWithWindowScene:scene];
        sg_shareWindow.windowLevel = UIWindowLevelAlert + 100;
        sg_shareWindow.backgroundColor = UIColor.clearColor;
        UIViewController *root = [UIViewController new];
        root.view.backgroundColor = UIColor.clearColor;
        sg_shareWindow.rootViewController = root;
    }
    UIViewController *root = sg_shareWindow.rootViewController;
    if (root.presentedViewController) [root dismissViewControllerAnimated:NO completion:nil];
    sg_shareWindow.hidden = NO;
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *error) {
        sg_shareWindow.hidden = YES;
    };
    share.popoverPresentationController.sourceView = root.view;
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(root.view.bounds), CGRectGetMidY(root.view.bounds), 0, 0);
    [root presentViewController:share animated:YES completion:^{
        SGLog(@"dump: share sheet up");
    }];
}

static void shareDump(UIWindow *window) {
    static CFTimeInterval last;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - last < 2) return;
    last = now;
    UIWindowScene *scene = sceneFor(window);
    NSString *tree = SGScreenTree();
    NSDateFormatter *format = [NSDateFormatter new];
    format.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *name = [NSString stringWithFormat:@"spoti-dump-%@.txt", [format stringFromDate:NSDate.date]];
    NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *text = [NSString stringWithFormat:@"%@\n== log (last 10 min)\n%@", tree, recentLog()];
        [text writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ presentShare(file, scene); });
    });
    SGLog(@"dump: %@ written", name);
}

void SGShareDumpAfter(NSTimeInterval delay) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *key = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) key = window;
            }
        }
        shareDump(key);
    });
}

@interface SGDumpPress : NSObject
@end

@implementation SGDumpPress
+ (void)pressed:(UILongPressGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan) return;
    shareDump((UIWindow *)press.view);
}
@end

// A shake goes to the first responder and up the chain, where any of Spotify's screens can keep it, so it is
// looked for where every event passes as well: the application's own dispatch.
%group DumpShake
%hook UIWindow
- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    %orig;
    if (motion == UIEventSubtypeMotionShake) shareDump((UIWindow *)self);
}
%end

%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (event.type == UIEventTypeMotion && event.subtype == UIEventSubtypeMotionShake) shareDump(nil);
}
%end
%end

static void addDumpPress(UIWindow *window) {
    static char kPressKey;
    if (!window || objc_getAssociatedObject(window, &kPressKey)) return;
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:SGDumpPress.class action:@selector(pressed:)];
    press.numberOfTouchesRequired = 3;
    press.minimumPressDuration = 1.0;
    press.cancelsTouchesInView = NO;
    [window addGestureRecognizer:press];
    objc_setAssociatedObject(window, &kPressKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook _TtC21NowPlaying_ScrollImpl23NPVScrollViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!SGIsDebugBuild()) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SGDumpScreen(@"now playing view");
        });
    });
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC21NowPlaying_ScrollImpl23NPVScrollViewController"]);
    SGLog(@"loaded, UIGlassEffect %@", NSClassFromString(@"UIGlassEffect") ? @"available" : @"missing");
    if (SGIsDebugBuild()) {
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            SGDumpScreen(@"on background");
        }];
        startTreeServer();
        %init(DumpShake);
        [NSNotificationCenter.defaultCenter addObserverForName:UIWindowDidBecomeKeyNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            addDumpPress(note.object);
        }];
        SGLog(@"debug build: backgrounding the app dumps the visible screen's view tree; a three-finger long press or a shake shares it with the log");
    }
}
