// Fork: the side drawer's plan badge on green glass while Spoof Premium is on. Spotify still draws it as a
// grey rounded rectangle reading "Spotify Free"; it becomes a capsule of glass with a film of Spotify's green
// in it, a green hairline and a soft green glow, and the text goes white. Before iOS 26 the glass is a dark
// ultra thin blur, from iOS 26 Liquid Glass tinted green. Spotify's text is left as it is.
//
// Tree (device dump, 2026-09-19): Element_List.CollectionViewCell 385x48 > ElementContentView > ElementView >
// SubscriptionManagement_YourPlanSideDrawerPluginImpl.YourPlanSideDrawerItemContainerView 385x48 > UIView >
// Encore ListRow id=Components.UI.YourPlanRowSideDrawer a11y="Your plan" > ... > StackView 317x26 >
//   UIView {224.7, 0} 92.7x26 bg=#B3B3B3 r=5.0 clips                 the badge
//     SPTEncoreLabel {10, 4} 72.7x18 id=Components.UI.SideDrawer.BadgeLabel
//       UILabel id=Components.UI.SideDrawer.BadgeLabel-internal "Spotify Free" 13pt #000000
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/AdBlock/AdBlock.h"

static char kBadgeLabelKey, kGlassKey, kObservedKey;

// Spotify's green, #1ED760.
static UIColor *green(CGFloat alpha) {
    return [UIColor colorWithRed:0x1E / 255.0 green:0xD7 / 255.0 blue:0x60 / 255.0 alpha:alpha];
}

static UIVisualEffectView *glassIn(UIView *badge) {
    UIVisualEffectView *glass = objc_getAssociatedObject(badge, &kGlassKey);
    if (glass) return glass;
    UIVisualEffect *effect = nil;
    if (@available(iOS 26.0, *)) {
        effect = SGGlassEffect();
        if ([effect respondsToSelector:@selector(setTintColor:)]) [(id)effect setTintColor:green(0.35)];
    }
    if (!effect) effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    glass.userInteractionEnabled = NO;
    glass.clipsToBounds = YES;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    UIView *film = [[UIView alloc] initWithFrame:glass.contentView.bounds];
    film.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    film.backgroundColor = green(0.28);
    [glass.contentView addSubview:film];
    objc_setAssociatedObject(badge, &kGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return glass;
}

static void styleBadge(UIView *badge) {
    CGRect bounds = badge.bounds;
    if (bounds.size.height < 1) return;
    UIVisualEffectView *glass = glassIn(badge);
    if (glass.superview != badge) [badge insertSubview:glass atIndex:0];
    else if (badge.subviews.firstObject != glass) [badge sendSubviewToBack:glass];
    CGFloat radius = bounds.size.height / 2;
    if (!CGRectEqualToRect(glass.frame, bounds)) glass.frame = bounds;
    glass.layer.cornerRadius = radius;

    if (![badge.backgroundColor isEqual:UIColor.clearColor]) badge.backgroundColor = UIColor.clearColor;
    // The glow is the badge's own shadow, which its clipping would cut off; the glass clips itself.
    if (badge.clipsToBounds) badge.clipsToBounds = NO;
    CALayer *layer = badge.layer;
    layer.cornerRadius = radius;
    layer.cornerCurve = kCACornerCurveContinuous;
    layer.borderWidth = 0.75;
    layer.borderColor = green(0.6).CGColor;
    layer.shadowColor = green(1).CGColor;
    layer.shadowOpacity = 0.45;
    layer.shadowRadius = 6;
    layer.shadowOffset = CGSizeZero;
    layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:radius].CGPath;

    SGForEachView(badge, ^(UIView *v) {
        if (![v isKindOfClass:UILabel.class]) return;
        UILabel *label = (UILabel *)v;
        if (![label.textColor isEqual:UIColor.whiteColor]) label.textColor = UIColor.whiteColor;
    });

    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign drawer: plan badge %.0fx%.0f on green glass", bounds.size.width, bounds.size.height); });
}

static void style(UIView *container) {
    UIView *label = SGRFindByIdentifier(container, @"Components.UI.SideDrawer.BadgeLabel", &kBadgeLabelKey);
    UIView *badge = label.superview;
    if (!badge) return;
    styleBadge(badge);
    // The badge fills in after the row first lays out (a shimmer stands in while the plan loads), and
    // Spotify's text and colour come with it, so it is styled again on each pass of its own.
    if (!objc_getAssociatedObject(badge, &kObservedKey)) {
        objc_setAssociatedObject(badge, &kObservedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGRObserveLayout(badge, ^(UIView *view) { styleBadge(view); });
    }
}

%hook _TtC51SubscriptionManagement_YourPlanSideDrawerPluginImpl35YourPlanSideDrawerItemContainerView
- (void)layoutSubviews {
    %orig;
    style((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGHidden(SGKeyFakePremium)) return;
    %init;
    SGRequireClasses(@[@"_TtC51SubscriptionManagement_YourPlanSideDrawerPluginImpl35YourPlanSideDrawerItemContainerView"]);
}
