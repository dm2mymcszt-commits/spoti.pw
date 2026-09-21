#import <os/lock.h>
#import <CoreImage/CoreImage.h>
#import "Core/SGCore.h"
#import "SGRSongColour.h"
#import "SGRBridges.h"
#import "SGRTokens.h"

NSNotificationName const SGRSongColourDidChangeNotification = @"spotifyglass.redesign.songColourDidChange";

// How strongly the blurred cover shows over black behind the screens: the reference theme's screens are
// clearly tinted by the song, not hinted at.
static const CGFloat kGlowOpacity = 0.5;
// The small copy everything is read from, how hard it is blurred at that size (about a tenth of it), and
// how much livelier the glow is made than the cover.
static const size_t kSide = 64;
static const CGFloat kBlur = 7, kGlowSaturation = 1.8, kGlowContrast = 1.1;
// HSL: the accent has to carry on the glow; the text is lighter so a paragraph of it still reads.
static const CGFloat kAccentLightness = 0.55, kTextLightness = 0.74, kMinSaturation = 0.5, kMaxSaturation = 0.9;
// Below this share of vibrant pixels the cover is grey, black and white or nearly so.
static const CGFloat kVibrantShare = 0.03;

static os_unfair_lock sg_lock = OS_UNFAIR_LOCK_INIT;
static BOOL sg_hasColour;
static CGFloat sg_accent[3], sg_text[3];
static UIImage *sg_glow;          // main thread
static NSUInteger sg_generation;  // main thread
static NSHashTable<UIView *> *sg_roots;
static char kGlowKey;

BOOL SGRSongColour(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGRedesignedUI() && SGEnabled(SGRKeySongColour); });
    return on;
}

BOOL SGRSongColourText(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGRSongColour() && SGEnabled(SGRKeySongColourText); });
    return on;
}

static BOOL readColour(CGFloat source[3], CGFloat *r, CGFloat *g, CGFloat *b) {
    os_unfair_lock_lock(&sg_lock);
    BOOL has = sg_hasColour;
    if (has) *r = source[0], *g = source[1], *b = source[2];
    os_unfair_lock_unlock(&sg_lock);
    return has;
}

BOOL SGRSongAccent(CGFloat *r, CGFloat *g, CGFloat *b) {
    return readColour(sg_accent, r, g, b);
}

BOOL SGRSongText(CGFloat *r, CGFloat *g, CGFloat *b) {
    return readColour(sg_text, r, g, b);
}

#pragma mark - colour arithmetic

static void toHSL(CGFloat r, CGFloat g, CGFloat b, CGFloat *h, CGFloat *s, CGFloat *l) {
    CGFloat max = MAX(r, MAX(g, b)), min = MIN(r, MIN(g, b)), d = max - min;
    *l = (max + min) / 2;
    if (d < 1e-6) {
        *h = *s = 0;
        return;
    }
    *s = *l > 0.5 ? d / (2 - max - min) : d / (max + min);
    if (max == r) *h = (g - b) / d + (g < b ? 6 : 0);
    else if (max == g) *h = (b - r) / d + 2;
    else *h = (r - g) / d + 4;
    *h /= 6;
}

static CGFloat channel(CGFloat p, CGFloat q, CGFloat t) {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1.0 / 6) return p + (q - p) * 6 * t;
    if (t < 0.5) return q;
    if (t < 2.0 / 3) return p + (q - p) * (2.0 / 3 - t) * 6;
    return p;
}

static void fromHSL(CGFloat h, CGFloat s, CGFloat l, CGFloat out[3]) {
    if (s < 1e-6) {
        out[0] = out[1] = out[2] = l;
        return;
    }
    CGFloat q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
    out[0] = channel(p, q, h + 1.0 / 3);
    out[1] = channel(p, q, h);
    out[2] = channel(p, q, h - 1.0 / 3);
}

static BOOL components(CGColorRef color, CGFloat rgba[4]) {
    if (!color || CFGetTypeID(color) != CGColorGetTypeID()) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    size_t n = CGColorGetNumberOfComponents(color);
    if (n == 2) rgba[0] = rgba[1] = rgba[2] = c[0], rgba[3] = c[1];
    else if (n == 4) rgba[0] = c[0], rgba[1] = c[1], rgba[2] = c[2], rgba[3] = c[3];
    else return NO;
    return YES;
}

#pragma mark - live colours

// A trait of the mod's own whose value is bumped on every song: a live colour reads it, so UIKit knows that
// colour depends on it and redraws it when it changes.
API_AVAILABLE(ios(17.0))
@interface SGRSongTrait : NSObject <UINSIntegerTraitDefinition>
@end

@implementation SGRSongTrait
+ (NSInteger)defaultValue {
    return 0;
}
+ (NSString *)identifier {
    return @"com.spotifyglass.songColour";
}
+ (NSString *)name {
    return @"SongColour";
}
+ (BOOL)affectsColorAppearance {
    return YES;
}
@end

static NSInteger sg_traitValue;   // main thread

// Made through CoreGraphics rather than +colorWithRed:..., which SGRAccent.x swaps: a song whose accent is
// Spotify's green to the digit must not come back through the swap.
static UIColor *plainColour(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    static CGColorSpaceRef space;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ space = CGColorSpaceCreateDeviceRGB(); });
    CGFloat c[4] = {MIN(1, r), MIN(1, g), MIN(1, b), a};
    CGColorRef cg = CGColorCreate(space, c);
    UIColor *color = [UIColor colorWithCGColor:cg];
    CGColorRelease(cg);
    return color;
}

UIColor *SGRSongLiveAccent(CGFloat factor, CGFloat alpha, UIColor *fallback) {
    if (!SGRSongColour()) return nil;
    if (@available(iOS 17.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            [traits valueForNSIntegerTrait:SGRSongTrait.class];
            CGFloat r, g, b;
            if (!SGRSongAccent(&r, &g, &b)) return fallback;
            return plainColour(r * factor, g * factor, b * factor, alpha);
        }];
    }
    return nil;
}

UIColor *SGRSongLiveText(CGFloat alpha) {
    if (!SGRSongColourText()) return nil;
    if (@available(iOS 17.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            [traits valueForNSIntegerTrait:SGRSongTrait.class];
            CGFloat r, g, b;
            if (!SGRSongText(&r, &g, &b)) return plainColour(1, 1, 1, alpha);
            return plainColour(r, g, b, alpha);
        }];
    }
    return nil;
}

#pragma mark - reading a cover

static dispatch_queue_t readQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("spotifyglass.songcolour", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

// Vibrant's idea on 64x64 pixels: hue bins weighted by how saturated a pixel is and how close to a mid
// lightness, the best bin with its two neighbours, averaged.
static BOOL vibrantIn(const uint8_t *pixels, CGFloat out[3]) {
    CGFloat weights[36] = {0}, sums[36][3] = {{0}}, counted = 0;
    for (size_t i = 0; i < kSide * kSide; i++) {
        const uint8_t *p = pixels + i * 4;
        CGFloat a = p[3] / 255.0;
        if (a < 0.5) continue;
        CGFloat r = p[0] / 255.0 / a, g = p[1] / 255.0 / a, b = p[2] / 255.0 / a, h, s, l;
        toHSL(MIN(1, r), MIN(1, g), MIN(1, b), &h, &s, &l);
        counted += 1;
        if (l < 0.12 || l > 0.92 || s < 0.25) continue;
        CGFloat w = s * (1 - fabs(l - 0.5) * 1.4);
        if (w <= 0) continue;
        int bin = MIN(35, (int)(h * 36));
        weights[bin] += w;
        sums[bin][0] += r * w, sums[bin][1] += g * w, sums[bin][2] += b * w;
    }
    int best = -1;
    CGFloat bestScore = 0;
    for (int i = 0; i < 36; i++) {
        CGFloat score = weights[(i + 35) % 36] + weights[i] + weights[(i + 1) % 36];
        if (score > bestScore) bestScore = score, best = i;
    }
    if (best < 0 || counted < 1 || bestScore / counted < kVibrantShare) return NO;
    CGFloat r = 0, g = 0, b = 0;
    for (int k = -1; k <= 1; k++) {
        int i = (best + k + 36) % 36;
        r += sums[i][0], g += sums[i][1], b += sums[i][2];
    }
    out[0] = r / bestScore, out[1] = g / bestScore, out[2] = b / bestScore;
    return YES;
}

static CGImageRef copyGlow(CGImageRef small) {
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext contextWithOptions:nil]; });
    CIImage *input = [[CIImage imageWithCGImage:small] imageByClampingToExtent];
    CIFilter *controls = [CIFilter filterWithName:@"CIColorControls"];
    [controls setValue:input forKey:kCIInputImageKey];
    [controls setValue:@(kGlowSaturation) forKey:kCIInputSaturationKey];
    [controls setValue:@(kGlowContrast) forKey:kCIInputContrastKey];
    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    [blur setValue:controls.outputImage forKey:kCIInputImageKey];
    [blur setValue:@(kBlur) forKey:kCIInputRadiusKey];
    CGRect extent = CGRectMake(0, 0, kSide, kSide);
    CIImage *output = [blur.outputImage imageByCroppingToRect:extent];
    return output ? [context createCGImage:output fromRect:extent] : NULL;
}

// One cover's colours, as a struct so a block can carry them to the main thread.
typedef struct {
    BOOL vibrant;
    CGFloat accent[3], text[3];
} SGRReading;

static void publish(SGRReading reading, CGImageRef glow);

static void readCover(UIImage *image) {
    CGImageRef cover = image.CGImage;
    if (!cover) return;
    CGImageRetain(cover);
    NSUInteger generation = ++sg_generation;
    dispatch_async(readQueue(), ^{
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        uint8_t *pixels = calloc(kSide * kSide * 4, 1);
        CGContextRef context = CGBitmapContextCreate(pixels, kSide, kSide, 8, kSide * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
        CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), cover);
        CGImageRelease(cover);
        CGImageRef small = CGBitmapContextCreateImage(context);

        CGFloat found[3] = {0};
        SGRReading reading = {0};
        reading.vibrant = vibrantIn(pixels, found);
        if (reading.vibrant) {
            CGFloat h, s, l;
            toHSL(found[0], found[1], found[2], &h, &s, &l);
            CGFloat saturation = MIN(kMaxSaturation, MAX(s, kMinSaturation));
            fromHSL(h, saturation, kAccentLightness, reading.accent);
            fromHSL(h, saturation, kTextLightness, reading.text);
        }
        CGImageRef glow = small ? copyGlow(small) : NULL;

        if (small) CGImageRelease(small);
        CGContextRelease(context);
        free(pixels);
        CGColorSpaceRelease(space);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == sg_generation) publish(reading, glow);
            if (glow) CGImageRelease(glow);
        });
    });
}

#pragma mark - recolouring what is on screen

// A colour of the same family as `ref`: saturated, and of its hue. Spotify blends its green into darker
// states, which keep the hue and lose brightness.
static BOOL sameFamily(CGFloat c[4], CGFloat ref[3]) {
    CGFloat h, s, l, rh, rs, rl;
    toHSL(c[0], c[1], c[2], &h, &s, &l);
    toHSL(ref[0], ref[1], ref[2], &rh, &rs, &rl);
    if (s < 0.3 || l < 0.08 || l > 0.95) return NO;
    CGFloat dh = fabs(h - rh);
    dh = MIN(dh, 1 - dh);
    return dh < 0.045 && fabs(s - rs) < 0.35;
}

static BOOL white(CGFloat c[4]) {
    return c[0] > 0.93 && c[1] > 0.93 && c[2] > 0.93 && c[3] > 0.9;
}

// `c` taken from the family of `from` into the family of `to`, keeping how much lighter or darker than
// `from` it was, and its alpha.
static UIColor *mapped(CGFloat c[4], CGFloat from[3], CGFloat to[3]) {
    CGFloat h, s, l, fh, fs, fl, th, ts, tl, out[3];
    toHSL(c[0], c[1], c[2], &h, &s, &l);
    toHSL(from[0], from[1], from[2], &fh, &fs, &fl);
    toHSL(to[0], to[1], to[2], &th, &ts, &tl);
    CGFloat lightness = MIN(0.95, MAX(0.05, tl + (l - fl)));
    fromHSL(th, ts, lightness, out);
    return [UIColor colorWithRed:out[0] green:out[1] blue:out[2] alpha:c[3]];
}

typedef struct {
    CGFloat oldAccent[3], newAccent[3], oldText[3], newText[3];
    BOOL hadText, text;
} SGRRecolour;

static void recolourLayer(CALayer *layer, const SGRRecolour *m, NSUInteger depth) {
    if (depth > 6) return;
    CGFloat c[4];
    if (components(layer.backgroundColor, c) && sameFamily(c, (CGFloat *)m->oldAccent)) {
        layer.backgroundColor = mapped(c, (CGFloat *)m->oldAccent, (CGFloat *)m->newAccent).CGColor;
    }
    if ([layer isKindOfClass:CAShapeLayer.class]) {
        CAShapeLayer *shape = (CAShapeLayer *)layer;
        if (components(shape.fillColor, c) && sameFamily(c, (CGFloat *)m->oldAccent)) shape.fillColor = mapped(c, (CGFloat *)m->oldAccent, (CGFloat *)m->newAccent).CGColor;
        if (components(shape.strokeColor, c) && sameFamily(c, (CGFloat *)m->oldAccent)) shape.strokeColor = mapped(c, (CGFloat *)m->oldAccent, (CGFloat *)m->newAccent).CGColor;
    }
    for (CALayer *sub in layer.sublayers) {
        if (sub.delegate) continue;
        recolourLayer(sub, m, depth + 1);
    }
}

static void recolourView(UIView *view, const SGRRecolour *m) {
    CGFloat c[4];
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        if (components(label.textColor.CGColor, c)) {
            UIColor *live = m->text && white(c) ? SGRSongLiveText(c[3]) : nil;
            if (live) {
                label.textColor = live;
            } else if (sameFamily(c, (CGFloat *)m->oldAccent)) {
                label.textColor = mapped(c, (CGFloat *)m->oldAccent, (CGFloat *)m->newAccent);
            }
        }
    } else if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        if (components([button titleColorForState:UIControlStateNormal].CGColor, c) && sameFamily(c, (CGFloat *)m->oldAccent)) {
            [button setTitleColor:mapped(c, (CGFloat *)m->oldAccent, (CGFloat *)m->newAccent) forState:UIControlStateNormal];
        }
    }
    if (![view isKindOfClass:SGRSongGlowView.class]) recolourLayer(view.layer, m, 0);
    for (UIView *sub in view.subviews) recolourView(sub, m);
}

static void recolourWindows(const SGRRecolour *m) {
    UIColor *tint = plainColour(m->newAccent[0], m->newAccent[1], m->newAccent[2], 1);
    if (@available(iOS 17.0, *)) sg_traitValue++;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if ([NSStringFromClass(window.class) containsString:@"FLEX"]) continue;
            // Every live colour in the window, and in whatever joins it later, resolves again.
            if (@available(iOS 17.0, *)) [window.traitOverrides setNSIntegerValue:sg_traitValue forTrait:SGRSongTrait.class];
            window.tintColor = tint;
            if (!window.hidden) recolourView(window, m);
        }
    }
}

static void publish(SGRReading reading, CGImageRef glow) {
    BOOL vibrant = reading.vibrant;
    CGFloat *accent = reading.accent, *text = reading.text;
    if (glow) sg_glow = [UIImage imageWithCGImage:glow];
    SGRRecolour m = {0};
    if (vibrant) {
        CGFloat r, g, b;
        m.hadText = SGRSongText(&r, &g, &b);
        if (m.hadText) {
            m.oldText[0] = r, m.oldText[1] = g, m.oldText[2] = b;
            SGRSongAccent(&r, &g, &b);
            m.oldAccent[0] = r, m.oldAccent[1] = g, m.oldAccent[2] = b;
        } else {
            // Before the first song, what is on screen wears the accent Appearance set (or Spotify's green).
            CGFloat a;
            [SGRAccent() getRed:&m.oldAccent[0] green:&m.oldAccent[1] blue:&m.oldAccent[2] alpha:&a];
        }
        memcpy(m.newAccent, accent, sizeof(m.newAccent));
        memcpy(m.newText, text, sizeof(m.newText));
        m.text = SGRSongColourText();
        os_unfair_lock_lock(&sg_lock);
        memcpy(sg_accent, accent, sizeof(sg_accent));
        memcpy(sg_text, text, sizeof(sg_text));
        sg_hasColour = YES;
        os_unfair_lock_unlock(&sg_lock);
    }
    [NSNotificationCenter.defaultCenter postNotificationName:SGRSongColourDidChangeNotification object:nil];
    if (vibrant) recolourWindows(&m);

    static NSUInteger logged;
    if (logged++ < 12) {
        SGLog(@"song colour: glow %@, accent %@", glow ? @"ready" : @"none",
              vibrant ? [NSString stringWithFormat:@"#%02X%02X%02X", (int)(accent[0] * 255), (int)(accent[1] * 255), (int)(accent[2] * 255)] : @"kept (grey cover)");
    }
}

void SGRSongColourStart(void) {
    [NSNotificationCenter.defaultCenter addObserverForName:SGRNowPlayingArtworkDidChangeNotification object:nil
                                                     queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        UIImage *image = SGRNowPlayingArtwork(NULL, NULL);
        if (image) readCover(image);
    }];
    UIImage *image = SGRNowPlayingArtwork(NULL, NULL);
    if (image) readCover(image);
    SGLog(@"song colour: following the now playing artwork%@", SGRSongColourText() ? @", text tinted" : @"");
}

#pragma mark - the glow

static NSDictionary *noActions(void) {
    static NSDictionary *none;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNull *off = NSNull.null;
        none = @{@"bounds": off, @"position": off, @"frame": off, @"contents": off, @"backgroundColor": off, @"hidden": off};
    });
    return none;
}

@implementation SGRSongGlowView {
    CALayer *_black, *_glow;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    self.clipsToBounds = YES;
    // On sublayers of its own, which the repaint hooks leave alone (SGRRepaint.x).
    _black = [CALayer layer];
    _black.actions = noActions();
    _black.backgroundColor = UIColor.blackColor.CGColor;
    [self.layer addSublayer:_black];
    _glow = [CALayer layer];
    _glow.actions = noActions();
    _glow.contentsGravity = kCAGravityResizeAspectFill;
    _glow.opacity = kGlowOpacity;
    _glow.contents = (__bridge id)sg_glow.CGImage;
    [self.layer addSublayer:_glow];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sgr_songColourDidChange)
                                               name:SGRSongColourDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)sgr_songColourDidChange {
    id contents = (__bridge id)sg_glow.CGImage;
    if (_glow.contents == contents) return;
    if (self.window) {
        CATransition *fade = [CATransition animation];
        fade.type = kCATransitionFade;
        fade.duration = SGRCrossfade;
        [_glow addAnimation:fade forKey:@"contents"];
    }
    _glow.contents = contents;
}

// A glow that was off screen while the song changed catches up as it comes back.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) return;
    id contents = (__bridge id)sg_glow.CGImage;
    if (_glow.contents != contents) _glow.contents = contents;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _black.frame = bounds;
    // Wider than the screen, as the reference draws it, so the blur's edges are never seen.
    _glow.frame = CGRectInset(bounds, -bounds.size.width * 0.2, 0);
    [CATransaction commit];
}

@end

#pragma mark - screens

static BOOL isOwn(UIView *view) {
    return [view isKindOfClass:SGRSongGlowView.class];
}

static void clearBase(UIView *view) {
    if (isOwn(view)) return;
    if (!SGKeepsColor(view) && SGIsBaseSurface(view.layer.backgroundColor)) view.layer.backgroundColor = NULL;
    for (CALayer *layer in view.layer.sublayers) {
        if (!layer.delegate && SGIsBaseSurface(layer.backgroundColor)) layer.backgroundColor = NULL;
    }
    for (UIView *sub in view.subviews) clearBase(sub);
}

void SGRSongColourAdopt(UIView *root) {
    if (!root || !SGRSongColour()) return;
    if (!sg_roots) sg_roots = [NSHashTable weakObjectsHashTable];
    BOOL fresh = ![sg_roots containsObject:root];
    if (fresh) [sg_roots addObject:root];
    if ([root isKindOfClass:UITableView.class] || [root isKindOfClass:UICollectionView.class]) {
        UIView *background = [(UITableView *)root backgroundView];
        if (!isOwn(background)) [(UITableView *)root setBackgroundView:[SGRSongGlowView new]];
    } else {
        SGRSongGlowView *glow = objc_getAssociatedObject(root, &kGlowKey);
        if (!glow) {
            glow = [SGRSongGlowView new];
            objc_setAssociatedObject(root, &kGlowKey, glow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (glow.superview != root) [root insertSubview:glow atIndex:0];
        else if (root.subviews.firstObject != glow) [root sendSubviewToBack:glow];
        if (!CGRectEqualToRect(glow.frame, root.bounds)) glow.frame = root.bounds;
    }
    if (fresh) clearBase(root);
}

BOOL SGRSongColourClears(UIView *view) {
    if (!sg_roots.count || !NSThread.isMainThread) return NO;
    for (UIView *v = view; v; v = v.superview) {
        if (isOwn(v)) return NO;
        if ([sg_roots containsObject:v]) return YES;
    }
    return NO;
}
