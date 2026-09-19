// Fork: the side drawer's plan badge while Spoof Premium is on. Spotify's own badge stays -- its shape,
// size, font and place -- and turns flat Spotify green, #1ED760, with its black text reading "Spotify
// Premium": the style of Spotify's own green buttons. Two earlier attempts drew a pill of the mod's own over
// it, which read as foreign and sat in the wrong place while the drawer loaded, and a green with a sheen and
// a glow was not Spotify's style either (device, 2026-09-19).
//
// Nothing here waits on a pass to follow the badge: the green is a subview of the badge made the badge's
// size with flexible width and height, so UIKit resizes it with the badge, which clips it to its own
// rounded rectangle. The text is written into Spotify's label whenever that label lays out.
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

static char kBadgeLabelKey, kFillKey, kLabelObservedKey;
static NSString *const kPremiumText = @"Spotify Premium";

// Spotify's green, #1ED760.
static UIColor *green(CGFloat alpha) {
    return [UIColor colorWithRed:0x1E / 255.0 green:0xD7 / 255.0 blue:0x60 / 255.0 alpha:alpha];
}

// The green, flat.
@interface SGRPremiumFill : UIView
@end

@implementation SGRPremiumFill

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundColor = green(1);
    return self;
}

@end

// Spotify's label is an SPTEncoreLabel around a UILabel. Only the UILabel is written, through UIKit's own
// attributedText with the attributes Spotify set on its first character, so the font, colour and tracking
// stay Spotify's. The SPTEncoreLabel's own -setText: takes something other than an NSString: handed one it
// raised an unrecognized selector inside SpotifyShared the moment the drawer opened (device crash log,
// 2026-09-19), so nothing of its API is called.
static void writePremium(UIView *label) {
    SGForEachView(label, ^(UIView *v) {
        if (![v isKindOfClass:UILabel.class]) return;
        UILabel *inner = (UILabel *)v;
        NSAttributedString *current = inner.attributedText;
        if ([current.string isEqualToString:kPremiumText]) return;
        NSDictionary *attributes = current.length ? [current attributesAtIndex:0 effectiveRange:NULL] : @{};
        inner.attributedText = [[NSAttributedString alloc] initWithString:kPremiumText attributes:attributes];
        [inner invalidateIntrinsicContentSize];
        [label invalidateIntrinsicContentSize];
        [label setNeedsLayout];
        [label.superview setNeedsLayout];
        [label.superview.superview setNeedsLayout];
    });
}

static void premium(UIView *container) {
    UIView *label = SGRFindByIdentifier(container, @"Components.UI.SideDrawer.BadgeLabel", &kBadgeLabelKey);
    UIView *badge = label.superview;
    if (!badge) return;

    SGRPremiumFill *fill = objc_getAssociatedObject(badge, &kFillKey);
    if (!fill) {
        fill = [[SGRPremiumFill alloc] initWithFrame:badge.bounds];
        objc_setAssociatedObject(badge, &kFillKey, fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGLog(@"redesign drawer: plan badge %@ turned Premium green", NSStringFromCGRect(badge.frame));
    }
    if (fill.superview != badge) [badge insertSubview:fill atIndex:0];
    else if (badge.subviews.firstObject != fill) [badge sendSubviewToBack:fill];
    if (!CGRectEqualToRect(fill.frame, badge.bounds)) fill.frame = badge.bounds;
    if (!badge.clipsToBounds) badge.clipsToBounds = YES;

    writePremium(label);
    if (!objc_getAssociatedObject(label, &kLabelObservedKey)) {
        objc_setAssociatedObject(label, &kLabelObservedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGRObserveLayout(label, ^(UIView *view) { writePremium(view); });
    }
}

%hook _TtC51SubscriptionManagement_YourPlanSideDrawerPluginImpl35YourPlanSideDrawerItemContainerView
- (void)layoutSubviews {
    %orig;
    premium((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGHidden(SGKeyFakePremium)) return;
    %init;
    SGRequireClasses(@[@"_TtC51SubscriptionManagement_YourPlanSideDrawerPluginImpl35YourPlanSideDrawerItemContainerView"]);
}
