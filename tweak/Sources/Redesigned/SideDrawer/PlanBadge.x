// Fork: the side drawer's plan badge while Spoof Premium is on. Spotify's own badge stays -- its shape,
// size, font and place -- and turns Spotify's green with a soft sheen across its top, a thin inner
// highlight and a faint green glow, its black text reading "Spotify Premium": Spotify's green buttons, in
// the badge's shape. Two earlier attempts drew a pill of the mod's own over it, which read as foreign and
// sat in the wrong place while the drawer loaded (device, 2026-09-19).
//
// Nothing here waits on a pass to follow the badge: the green is a subview of the badge made the badge's
// size with flexible width and height, so UIKit resizes it with the badge. The badge stops clipping, for
// the glow, so the green rounds itself with the badge's radius. The text is written into Spotify's label
// whenever that label lays out, which it does when Spotify sets its text.
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

// The green: a gradient layer that follows the view's bounds, a white sheen over its top half and a
// hairline of light just inside its edge.
@interface SGRPremiumFill : UIView
@end

@implementation SGRPremiumFill {
    CAGradientLayer *_sheen;
}

+ (Class)layerClass {
    return CAGradientLayer.class;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    CAGradientLayer *base = (CAGradientLayer *)self.layer;
    base.colors = @[(id)[UIColor colorWithRed:0x3A / 255.0 green:0xE3 / 255.0 blue:0x78 / 255.0 alpha:1].CGColor, (id)green(1).CGColor];
    base.cornerCurve = kCACornerCurveContinuous;
    base.masksToBounds = YES;
    base.borderWidth = 0.5;
    base.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
    _sheen = [CAGradientLayer layer];
    _sheen.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.28].CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor];
    [base addSublayer:_sheen];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _sheen.frame = CGRectMake(0, 0, bounds.size.width, bounds.size.height * 0.55);
    [CATransaction commit];
}

@end

// Spotify's label is an SPTEncoreLabel around a UILabel: its own text is set when it has a setter, so
// its size and the badge's follow, and the inner label's otherwise.
static void writePremium(UIView *label) {
    if ([label respondsToSelector:@selector(text)] && [label respondsToSelector:@selector(setText:)]) {
        if (![[(id)label text] isEqual:kPremiumText]) {
            [(id)label setText:kPremiumText];
            [label invalidateIntrinsicContentSize];
            [label.superview.superview setNeedsLayout];
        }
        return;
    }
    SGForEachView(label, ^(UIView *v) {
        if (![v isKindOfClass:UILabel.class]) return;
        UILabel *inner = (UILabel *)v;
        if ([inner.text isEqualToString:kPremiumText]) return;
        inner.text = kPremiumText;
        [label invalidateIntrinsicContentSize];
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
    fill.layer.cornerRadius = badge.layer.cornerRadius;

    // The glow is the badge's own shadow, drawn from its rounded background, which the green covers.
    if (badge.clipsToBounds) badge.clipsToBounds = NO;
    CALayer *layer = badge.layer;
    layer.shadowColor = green(1).CGColor;
    layer.shadowOpacity = 0.35;
    layer.shadowRadius = 6;
    layer.shadowOffset = CGSizeZero;

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
