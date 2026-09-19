#import "Core/SGCore.h"
#import "Plan.h"

NSString *const SGRPremiumPlanName = @"Spotify Premium";

BOOL SGRWritePlanName(UIView *label) {
    __block BOOL changed = NO;
    SGForEachView(label, ^(UIView *v) {
        if (![v isKindOfClass:UILabel.class]) return;
        UILabel *inner = (UILabel *)v;
        NSAttributedString *current = inner.attributedText;
        if (!current.length || [current.string isEqualToString:SGRPremiumPlanName]) return;
        NSDictionary *attributes = [current attributesAtIndex:0 effectiveRange:NULL];
        inner.attributedText = [[NSAttributedString alloc] initWithString:SGRPremiumPlanName attributes:attributes];
        [inner invalidateIntrinsicContentSize];
        changed = YES;
    });
    if (changed) {
        [label invalidateIntrinsicContentSize];
        [label setNeedsLayout];
        [label.superview setNeedsLayout];
        [label.superview.superview setNeedsLayout];
    }
    return changed;
}
