// Keeps the areas the redesign stripped transparent when Spotify repaints them, and learns which view
// is the now playing bar's card from the album-colour paint.
#import "Core/SGCore.h"
#import "SGRRepaint.h"

__weak UIView *sgr_nowPlayingRoot = nil;
__weak UIView *sgr_nowPlayingCard = nil;
__weak UIView *sgr_lyricsPageRoot = nil;
__weak UIView *sgr_playlistRoot = nil;
__weak UIView *sgr_albumRoot = nil;
__weak UIView *sgr_artistRoot = nil;

%hook CALayer
- (void)setBackgroundColor:(CGColorRef)color {
    if (color && (sgr_nowPlayingRoot || sgr_lyricsPageRoot || sgr_playlistRoot || sgr_albumRoot || sgr_artistRoot)) {
        UIView *view = (UIView *)self.delegate;
        if ([view isKindOfClass:UIView.class] && view.layer == self && !SGKeepsColor(view)) {
            if (SGIsInside(view, sgr_nowPlayingRoot)) {
                if (SGLooksLikeCard(view, color) && sgr_nowPlayingCard != view) {
                    sgr_nowPlayingCard = view;
                    UIView *bar = sgr_nowPlayingRoot;
                    dispatch_async(dispatch_get_main_queue(), ^{ [bar.superview setNeedsLayout]; });
                }
                color = NULL;
            } else if (SGIsInside(view, sgr_lyricsPageRoot)) {
                color = NULL;
            } else if (SGIsBaseSurface(color) && (SGIsInside(view, sgr_playlistRoot) || SGIsInside(view, sgr_albumRoot) || SGIsInside(view, sgr_artistRoot))) {
                color = NULL;
            }
        } else if (SGIsBaseSurface(color) && ![view isKindOfClass:UIView.class]) {
            // Fork: a layer of its own rather than a view's. Spotify paints parts of the sections under an
            // album's tracks and of an artist's page on plain sublayers, which the checks above never see,
            // and they came out as black bands across the page's field (device, 2026-09-20). The view the
            // layer belongs to is the first one up its chain.
            CALayer *layer = self.superlayer;
            while (layer && ![layer.delegate isKindOfClass:UIView.class]) layer = layer.superlayer;
            UIView *host = (UIView *)layer.delegate;
            if (host && (SGIsInside(host, sgr_playlistRoot) || SGIsInside(host, sgr_albumRoot) || SGIsInside(host, sgr_artistRoot))) {
                color = NULL;
            }
        }
    }
    %orig(color);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
}
