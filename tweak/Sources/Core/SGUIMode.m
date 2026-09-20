#import "SGUIMode.h"
#import "SGLog.h"
#import "SGPrefs.h"

// Fork: the redesign is offered below iOS 26 as well. Upstream holds it at 26 because that is where
// UIGlassEffect is and because it hung an iOS 17 layout (#37); here the glass falls back to a blur and the
// hang is answered part by part in the Workaround section (Redesigned/Kit/SGRWorkaround.h), which is the
// whole point of this fork. Everything else upstream ships still applies.
BOOL SGRedesignAvailable(void) {
    return YES;
}

BOOL SGRedesignedUI(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        on = SGRedesignedUIStored();
        SGLog(@"ui: %@%@", on ? @"redesigned" : @"native", SGRedesignAvailable() ? @"" : @" (the redesign needs iOS 26)");
    });
    return on;
}

BOOL SGNativeUI(void) {
    return !SGRedesignedUI();
}

BOOL SGRedesignedUIStored(void) {
    // The stored switch is left alone rather than turned off: a phone updated to iOS 26 gets the
    // redesign it was last asked for back.
    return SGRedesignAvailable() && SGFlag(SGKeyRedesign, NO);
}
