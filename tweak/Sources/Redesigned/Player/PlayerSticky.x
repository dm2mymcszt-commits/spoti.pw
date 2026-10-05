// Fork: the bar that comes down over a player that scrolls. With its cards kept under it (the Player
// workaround, Kit/SGRWorkaround.h) the redesigned player scrolls the way Spotify's does, and Spotify's sticky
// header slides in over it: first a strip the height of the status bar, then a bar with the title, the add
// button and play. Spotify paints both its own colour for the track under a film of black, which over the
// redesign's field was a grey band, and a pale strip across the top of the cover as it went under it (device,
// 2026-10-05). They take the field's colour instead, with no film, so the bar is the player's own background
// with the page going under it. Upstream's player has nothing under it and never shows this header.
//
// Tree (dumps/spoti-dump-20261005-100227.txt:647-706): id=now-playing-sticky-header, the view of
// NowPlaying_ViewImpl.StickyHeaderViewControllerImpl, holds a stack whose first arranged view is the bar (a
// UIStackView painted Spotify's colour, #E8D8E0 there, with a UIView of black at 0.60 for its first subview)
// and, last, the strip (a UIView in the same colour whose alpha Spotify moves with the scroll, around the
// same film). The player's own background is that colour too (:636), under the field.
//
// The colour is put on in the header's pass and whenever the field's changes, and held when Spotify paints the
// header again for the next track.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Kit/SGRWorkaround.h"
#import "Player.h"

static __weak UIView *sg_sticky;

static UIColor *fieldColour(void) {
    return SGRPlayerField().fieldColor ?: SGRNeutralField();
}

// What a paint of Spotify's becomes in the header, into `to`: nothing for the film (black, partly see
// through), the field's colour for anything opaque. NO for what is left as it is.
static BOOL restyled(CGColorRef color, CGColorRef *to) {
    if (!color || CFGetTypeID(color) != CGColorGetTypeID()) return NO;
    CGFloat alpha = CGColorGetAlpha(color);
    if (alpha < 0.05) return NO;
    if (alpha < 0.95) {
        size_t count = CGColorGetNumberOfComponents(color);
        const CGFloat *c = CGColorGetComponents(color);
        for (size_t i = 0; i + 1 < count; i++) {
            if (c[i] > 0.06) return NO;
        }
        *to = NULL;
        return YES;
    }
    *to = fieldColour().CGColor;
    return YES;
}

static void restyleAll(UIView *header) {
    if (!header) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    SGForEachView(header, ^(UIView *view) {
        if (SGKeepsColor(view)) return;
        CGColorRef to = NULL;
        if (restyled(view.layer.backgroundColor, &to)) view.layer.backgroundColor = to;
    });
    [CATransaction commit];
}

%hook _TtC19NowPlaying_ViewImpl30StickyHeaderViewControllerImpl
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *header = ((UIViewController *)self).viewIfLoaded;
    if (sg_sticky != header) {
        sg_sticky = header;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"redesign player: the sticky header takes the field's colour (cards kept, the player scrolls)"); });
    }
    restyleAll(header);
}
%end

%hook CALayer
- (void)setBackgroundColor:(CGColorRef)color {
    UIView *header = sg_sticky;
    if (color && header.window) {
        UIView *view = (UIView *)self.delegate;
        if ([view isKindOfClass:UIView.class] && view.layer == self && !SGKeepsColor(view) && SGIsInside(view, header)) {
            CGColorRef to = NULL;
            if (restyled(color, &to)) color = to;
        }
    }
    %orig(color);
}
%end

%ctor {
    // Only a player that scrolls: with its cards collapsed the list is pinned (PlayerScroll.x) and the header
    // never comes down.
    if (!SGRedesignedUI() || SGRResizesListCells(@"player")) return;
    %init;
    [NSNotificationCenter.defaultCenter addObserverForName:SGRFieldColorDidChangeNotification object:nil
                                                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        if (note.object == SGRPlayerField()) restyleAll(sg_sticky);
    }];
    SGRequireClasses(@[@"_TtC19NowPlaying_ViewImpl30StickyHeaderViewControllerImpl"]);
}
