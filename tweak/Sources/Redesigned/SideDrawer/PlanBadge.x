// Fork: the side drawer's plan badge while Spoof Premium is on. Spotify's badge (a grey rounded rectangle
// reading "Spotify Free") is concealed, and a pill of the mod's own reading "Spotify Premium" takes its
// place: a dark capsule with a film of Spotify's green, a green hairline and a soft green glow, white text
// in Spotify's own font. Before iOS 26 its material is a dark ultra thin blur, from iOS 26 Liquid Glass.
//
// Spotify's badge is not restyled: it is laid out by Encore's stacks and repainted on their passes, which
// a restyle has to catch every time (a first attempt was caught once, too early, and left a green blob in
// the corner of a grey badge, device 2026-09-19). The pill is pinned to the badge by Auto Layout instead
// -- trailing edges, centres and heights -- from the plain UIView the row is drawn in, so it goes wherever
// the badge goes without a pass of ours; the badge is concealed by an empty mask, which neither the stack
// nor Spotify's repaints touch.
//
// Tree (device dump, 2026-09-19): Element_List.CollectionViewCell 385x48 > ElementContentView > ElementView >
// SubscriptionManagement_YourPlanSideDrawerPluginImpl.YourPlanSideDrawerItemContainerView 385x48 >
//   UIView 385x48                                                    where the pill goes
//     Encore ListRow id=Components.UI.YourPlanRowSideDrawer a11y="Your plan" > ... > StackView 317x26 >
//       UIView {224.7, 0} 92.7x26 bg=#B3B3B3 r=5.0 clips              the badge
//         SPTEncoreLabel {10, 4} 72.7x18 id=Components.UI.SideDrawer.BadgeLabel
//           UILabel id=Components.UI.SideDrawer.BadgeLabel-internal "Spotify Free" 13pt #000000
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/AdBlock/AdBlock.h"

static char kBadgeLabelKey, kPillKey;

// Spotify's green, #1ED760.
static UIColor *green(CGFloat alpha) {
    return [UIColor colorWithRed:0x1E / 255.0 green:0xD7 / 255.0 blue:0x60 / 255.0 alpha:alpha];
}

@interface SGRPremiumPill : UIView
@property (nonatomic, readonly) UILabel *label;
@end

@implementation SGRPremiumPill {
    UIVisualEffectView *_glass;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.isAccessibilityElement = NO;
    self.translatesAutoresizingMaskIntoConstraints = NO;

    UIVisualEffect *effect = nil;
    if (@available(iOS 26.0, *)) effect = SGGlassEffect();
    if (!effect) effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    _glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    _glass.frame = self.bounds;
    _glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _glass.clipsToBounds = YES;
    _glass.layer.cornerCurve = kCACornerCurveContinuous;
    // A dark base under the green, so the capsule reads the same on any background.
    UIView *base = [[UIView alloc] initWithFrame:_glass.contentView.bounds];
    base.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    base.backgroundColor = [UIColor colorWithWhite:0.07 alpha:0.55];
    [_glass.contentView addSubview:base];
    UIView *film = [[UIView alloc] initWithFrame:_glass.contentView.bounds];
    film.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    film.backgroundColor = green(0.2);
    [_glass.contentView addSubview:film];
    [self addSubview:_glass];

    _label = [UILabel new];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.text = @"Spotify Premium";
    _label.textColor = UIColor.whiteColor;
    _label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [self addSubview:_label];
    [NSLayoutConstraint activateConstraints:@[
        [_label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_label.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [_label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];

    CALayer *layer = self.layer;
    layer.cornerCurve = kCACornerCurveContinuous;
    layer.borderWidth = 0.75;
    layer.borderColor = green(0.5).CGColor;
    layer.shadowColor = green(1).CGColor;
    layer.shadowOpacity = 0.3;
    layer.shadowRadius = 5;
    layer.shadowOffset = CGSizeZero;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat radius = self.bounds.size.height / 2;
    self.layer.cornerRadius = radius;
    _glass.layer.cornerRadius = radius;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius].CGPath;
}

@end

static void attach(UIView *container) {
    UIView *label = SGRFindByIdentifier(container, @"Components.UI.SideDrawer.BadgeLabel", &kBadgeLabelKey);
    UIView *badge = label.superview;
    UIView *host = container.subviews.firstObject;
    if (!badge || !host || ![badge isDescendantOfView:host]) return;

    SGRPremiumPill *pill = objc_getAssociatedObject(container, &kPillKey);
    if (!pill) {
        pill = [SGRPremiumPill new];
        objc_setAssociatedObject(container, &kPillKey, pill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (pill.superview != host) {
        [pill removeFromSuperview];
        [host addSubview:pill];
        [NSLayoutConstraint activateConstraints:@[
            [pill.trailingAnchor constraintEqualToAnchor:badge.trailingAnchor],
            [pill.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
            [pill.heightAnchor constraintEqualToAnchor:badge.heightAnchor],
        ]];
        SGLog(@"redesign drawer: premium pill over the plan badge %@", NSStringFromCGRect(badge.frame));
    } else if (host.subviews.lastObject != pill) {
        [host bringSubviewToFront:pill];
    }
    // Spotify's own font for the text, once its label has one.
    __block UIFont *font = nil;
    SGForEachView(label, ^(UIView *v) {
        if (!font && [v isKindOfClass:UILabel.class]) font = ((UILabel *)v).font;
    });
    if (font && ![pill.label.font isEqual:font]) pill.label.font = font;
    if (!badge.layer.mask) badge.layer.mask = [CALayer layer];
}

%hook _TtC51SubscriptionManagement_YourPlanSideDrawerPluginImpl35YourPlanSideDrawerItemContainerView
- (void)layoutSubviews {
    %orig;
    attach((UIView *)self);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGHidden(SGKeyFakePremium)) return;
    %init;
    SGRequireClasses(@[@"_TtC51SubscriptionManagement_YourPlanSideDrawerPluginImpl35YourPlanSideDrawerItemContainerView"]);
}
