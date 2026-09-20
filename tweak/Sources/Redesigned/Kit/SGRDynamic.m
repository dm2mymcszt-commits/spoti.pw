#import <os/lock.h>
#import "Core/SGCore.h"
#import "SGRDynamic.h"
#import "SGRPalette.h"
#import "SGRBridges.h"

// How much of the field colour's brightness the app's surfaces keep: the pages already wear the field,
// and everything else is a near black that only hints at the cover.
static const CGFloat kSurfaceBrightness = 0.45;
// An accent has to carry on black, and a cover's own colour rarely does on its own.
static const CGFloat kAccentMinSaturation = 0.55, kAccentMaxSaturation = 0.9, kAccentMinBrightness = 0.85;
// Below this the cover is grey or black and white, and a grey accent reads as a mistake: the stored
// accent stays.
static const CGFloat kGreyCover = 0.08;
// A surface this close to the one before is the same colour to the eye, and repainting is not worth it.
static const CGFloat kSame = 0.004;

static os_unfair_lock sg_lock = OS_UNFAIR_LOCK_INIT;
static BOOL sg_hasSurface, sg_hasAccent;
static CGFloat sg_surface[3], sg_accent[3];

BOOL SGRDynamicColor(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGEnabled(SGRKeyDynamicColor); });
    return on;
}

BOOL SGRDynamicSurface(CGFloat *r, CGFloat *g, CGFloat *b) {
    os_unfair_lock_lock(&sg_lock);
    BOOL has = sg_hasSurface;
    if (has) *r = sg_surface[0], *g = sg_surface[1], *b = sg_surface[2];
    os_unfair_lock_unlock(&sg_lock);
    return has;
}

BOOL SGRDynamicAccent(CGFloat *r, CGFloat *g, CGFloat *b) {
    os_unfair_lock_lock(&sg_lock);
    BOOL has = sg_hasAccent;
    if (has) *r = sg_accent[0], *g = sg_accent[1], *b = sg_accent[2];
    os_unfair_lock_unlock(&sg_lock);
    return has;
}

#pragma mark - repainting what is already on screen

static BOOL nearlyBlack(CGColorRef color) {
    if (!color || CFGetTypeID(color) != CGColorGetTypeID() || CGColorGetAlpha(color) < 0.5) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    size_t n = CGColorGetNumberOfComponents(color);
    if (n == 2) return c[0] <= 0.12;
    return n >= 4 && c[0] <= 0.12 && c[1] <= 0.12 && c[2] <= 0.12;
}

// The surfaces Spotify painted before the track changed keep the last colour until something repaints
// them, so every near black one on screen is taken to the new colour. A cover, a placeholder or a card
// is lighter than this and is left alone.
static void repaint(UIView *view, UIColor *surface) {
    CGColorRef bg = view.layer.backgroundColor;
    if (nearlyBlack(bg) && !SGKeepsColor(view)) {
        view.layer.backgroundColor = [surface colorWithAlphaComponent:CGColorGetAlpha(bg)].CGColor;
    }
    for (CALayer *layer in view.layer.sublayers) {
        if (layer.delegate || ![layer isKindOfClass:CALayer.class]) continue;
        if (nearlyBlack(layer.backgroundColor)) {
            layer.backgroundColor = [surface colorWithAlphaComponent:CGColorGetAlpha(layer.backgroundColor)].CGColor;
        }
    }
    for (UIView *sub in view.subviews) repaint(sub, surface);
}

static void repaintWindows(UIColor *surface) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden) repaint(window, surface);
        }
    }
}

#pragma mark - following the artwork

static void publish(SGRPalette *palette) {
    CGFloat h = 0, s = 0, v = 0, a = 1;
    if (![palette.fieldColor getHue:&h saturation:&s brightness:&v alpha:&a]) return;
    UIColor *surface = [UIColor colorWithHue:h saturation:s brightness:v * kSurfaceBrightness alpha:1];
    CGFloat sr = 0, sg = 0, sb = 0;
    [surface getRed:&sr green:&sg blue:&sb alpha:&a];

    BOOL hasAccent = NO;
    CGFloat ar = 0, ag = 0, ab = 0;
    if ([palette.edgeColor getHue:&h saturation:&s brightness:&v alpha:&a] && s >= kGreyCover) {
        UIColor *accent = [UIColor colorWithHue:h
                                     saturation:MIN(kAccentMaxSaturation, MAX(s, kAccentMinSaturation))
                                     brightness:MAX(v, kAccentMinBrightness) alpha:1];
        hasAccent = [accent getRed:&ar green:&ag blue:&ab alpha:&a];
    }

    os_unfair_lock_lock(&sg_lock);
    BOOL same = sg_hasSurface && fabs(sg_surface[0] - sr) < kSame && fabs(sg_surface[1] - sg) < kSame && fabs(sg_surface[2] - sb) < kSame;
    sg_surface[0] = sr, sg_surface[1] = sg, sg_surface[2] = sb;
    sg_hasSurface = YES;
    if (hasAccent) {
        sg_accent[0] = ar, sg_accent[1] = ag, sg_accent[2] = ab;
        sg_hasAccent = YES;
    }
    os_unfair_lock_unlock(&sg_lock);
    if (same) return;

    repaintWindows(surface);
    static NSUInteger logged;
    if (logged++ < 10) {
        SGLog(@"dynamic colour: surface #%02X%02X%02X, accent %@", (int)(sr * 255), (int)(sg * 255), (int)(sb * 255),
              hasAccent ? [NSString stringWithFormat:@"#%02X%02X%02X", (int)(ar * 255), (int)(ag * 255), (int)(ab * 255)] : @"the stored one (grey cover)");
    }
}

static void readArtwork(void) {
    UIImage *artwork = SGRNowPlayingArtwork(NULL, NULL);
    if (!artwork) return;
    SGRPaletteRequest request = {CGSizeZero, NO, NO};
    [SGRPalette paletteForImage:artwork request:request completion:^(SGRPalette *palette) {
        if (palette) publish(palette);
    }];
}

void SGRDynamicStart(void) {
    [NSNotificationCenter.defaultCenter addObserverForName:SGRNowPlayingArtworkDidChangeNotification object:nil
                                                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        readArtwork();
    }];
    readArtwork();
    SGLog(@"dynamic colour: following the now playing artwork");
}
