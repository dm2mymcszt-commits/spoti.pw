// Fork: Settings > Account > Your plan reads "Spotify Premium" while Spoof Premium is on; Spotify's row stays
// as it is otherwise, its icon, font and chevron.
//
// Tree (device dump, 2026-09-19): Element_List.CollectionViewCell 428x63 >
// ElementContentView<SubscriptionManagement_SettingsKit.PlanOverviewElement> >
// ElementView<...PlanOverviewElement.Props> >
//   LegacyUI_ECMCoreKit.InteractableLayoutBackingButton 428x63 a11y="Spotify Free"   the row
//     ... > AutoLayoutStackView {67, 16.7} 313x22 > UIView >
//       SPTEncoreLabel 87x22 id=Encore.Label > UILabel "Spotify Free" 16pt #FFFFFF
// The button is Spotify's everywhere, so only one whose element view names PlanOverviewElement is touched,
// and that answer is kept per class.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Shared/AdBlock/AdBlock.h"
#import "Plan.h"

static char kObservedKey;

static BOOL isPlanRow(UIView *button) {
    static NSMutableSet<Class> *yes, *no;
    if (!yes) {
        yes = [NSMutableSet set];
        no = [NSMutableSet set];
    }
    Class cls = object_getClass(button.superview);
    if (!cls || [no containsObject:cls]) return NO;
    if ([yes containsObject:cls]) return YES;
    BOOL plan = [NSStringFromClass(cls) containsString:@"PlanOverviewElement"];
    [(plan ? yes : no) addObject:cls];
    return plan;
}

static void showPremium(UIView *button) {
    static Class labelClass;
    if (!labelClass) labelClass = NSClassFromString(@"SPTEncoreLabel");
    __block UIView *label = nil;
    SGForEachView(button, ^(UIView *v) {
        if (!label && [v isKindOfClass:labelClass]) label = v;
    });
    if (!label) return;
    if (SGRWritePlanName(label)) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"redesign account: the plan reads %@", SGRPremiumPlanName); });
    }
    if (![button.accessibilityLabel isEqualToString:SGRPremiumPlanName]) button.accessibilityLabel = SGRPremiumPlanName;
    // Spotify writes its text again when the row is configured, which lays the label out.
    if (!objc_getAssociatedObject(label, &kObservedKey)) {
        objc_setAssociatedObject(label, &kObservedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGRObserveLayout(label, ^(UIView *view) { SGRWritePlanName(view); });
    }
}

%hook _TtC19LegacyUI_ECMCoreKit31InteractableLayoutBackingButton
- (void)layoutSubviews {
    %orig;
    UIView *button = (UIView *)self;
    if (isPlanRow(button)) showPremium(button);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGHidden(SGKeyFakePremium)) return;
    %init;
    SGRequireClasses(@[@"_TtC19LegacyUI_ECMCoreKit31InteractableLayoutBackingButton"]);
}
