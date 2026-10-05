#import <os/lock.h>
#import <CoreImage/CoreImage.h>
#import "Core/SGCore.h"
#import "SGRSongColour.h"
#import "SGRBridges.h"
#import "SGRTokens.h"
#import "SGRAccent.h"
#import "SGRVibrant.h"

NSNotificationName const SGRSongColourDidChangeNotification = @"spotifyglass.redesign.songColourDidChange";

// How strongly the blurred cover shows over black behind the screens: the reference theme's screens are
// clearly tinted by the song, not hinted at.
static const CGFloat kGlowOpacity = 0.5;
// The small copy everything is read from, how hard it is blurred at that size (about a tenth of it), and
// how much livelier the glow is made than the cover.
static const size_t kSide = 64;
static const CGFloat kBlur = 7, kGlowSaturation = 1.8, kGlowContrast = 1.1;
// HSL: the accent has to carry on the glow; the text is lighter so a paragraph of it still reads. The hue and
// the saturation are the cover's, as DefaultDynamic picks them (SGRVibrant.h).
static const CGFloat kAccentLightness = 0.55, kTextLightness = 0.74;
// Moving glow: each copy is this much of the view's longer side across, sits at its centre below (a share
// of the view's size), and shows this strongly; the two together come out about as bright as the still
// glow. The second turns the other way and this much more slowly, so the two never line up.
static const CGFloat kBlobSide = 1.3, kBlobOpacity[2] = {0.42, 0.32}, kSecondTurn = 4.0 / 3;
static const CGPoint kBlobCentre[2] = {{0.3, 0.35}, {0.7, 0.7}};
// Accents remembered besides the playing one; the Appearance accent is always the first of them.
enum { kWornMax = 32 };

static os_unfair_lock sg_lock = OS_UNFAIR_LOCK_INIT;
static BOOL sg_hasColour;
static CGFloat sg_accent[3], sg_text[3];
static UIImage *sg_glow, *sg_blob; // main thread
static NSUInteger sg_generation;   // main thread
static NSUInteger sg_songs;        // main thread: how many songs have given colours
static CGFloat sg_worn[kWornMax][3];
static NSUInteger sg_wornCount;    // main thread
static NSHashTable<UIView *> *sg_roots;
static char kGlowKey, kLiveKey, kIconSongKey, kGlyphInfoKey, kGlyphWearKey, kGlyphOriginalKey, kGlyphSongKey, kGlyphPaintKey, kKeepWhiteKey, kPatchKey;

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

BOOL SGRSongColourMotion(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGRSongColour() && SGFlag(SGRKeySongColourMotion, NO); });
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

// A live colour carries what it is (its factor, or -1 for the text), so one can be told from a colour fixed
// in the song's accent, and made again (SPTEncoreIconView below).
static UIColor *tagged(UIColor *color, CGFloat factor) {
    if (color) objc_setAssociatedObject(color, &kLiveKey, @(factor), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return color;
}

UIColor *SGRSongLiveAccent(CGFloat factor, CGFloat alpha, UIColor *fallback) {
    if (!SGRSongColour()) return nil;
    if (@available(iOS 17.0, *)) {
        return tagged([UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            [traits valueForNSIntegerTrait:SGRSongTrait.class];
            CGFloat r, g, b;
            if (!SGRSongAccent(&r, &g, &b)) return fallback ?: plainColour(1, 1, 1, alpha);
            return plainColour(r * factor, g * factor, b * factor, alpha);
        }], factor);
    }
    return nil;
}

UIColor *SGRSongLiveText(CGFloat alpha) {
    if (!SGRSongColourText()) return nil;
    if (@available(iOS 17.0, *)) {
        return tagged([UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
            [traits valueForNSIntegerTrait:SGRSongTrait.class];
            CGFloat r, g, b;
            if (!SGRSongText(&r, &g, &b)) return plainColour(1, 1, 1, alpha);
            return plainColour(r, g, b, alpha);
        }], -1);
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

// Moving glow: the glow in a disc that fades out towards its rim, so a turning copy never shows an edge.
static CGImageRef copyBlob(CGImageRef glow) {
    CGRect rect = CGRectMake(0, 0, kSide, kSide);
    CGColorSpaceRef grey = CGColorSpaceCreateDeviceGray();
    CGContextRef maskContext = CGBitmapContextCreate(NULL, kSide, kSide, 8, 0, grey, (CGBitmapInfo)kCGImageAlphaNone);
    CGContextSetGrayFillColor(maskContext, 0, 1);
    CGContextFillRect(maskContext, rect);
    // Full to half the radius, then eased out to nothing at the rim.
    CGFloat stops[] = {1, 1, 1, 1, 0.75, 1, 0.3, 1, 0, 1};
    CGFloat locations[] = {0, 0.5, 0.7, 0.85, 1};
    CGGradientRef falloff = CGGradientCreateWithColorComponents(grey, stops, locations, 5);
    CGPoint middle = CGPointMake(kSide / 2.0, kSide / 2.0);
    CGContextDrawRadialGradient(maskContext, falloff, middle, 0, middle, kSide / 2.0, 0);
    CGImageRef mask = CGBitmapContextCreateImage(maskContext);

    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, kSide, kSide, 8, 0, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextClearRect(context, rect);
    if (mask) CGContextClipToMask(context, rect, mask);
    CGContextDrawImage(context, rect, glow);
    CGImageRef blob = CGBitmapContextCreateImage(context);

    CGContextRelease(context);
    CGColorSpaceRelease(space);
    if (mask) CGImageRelease(mask);
    CGGradientRelease(falloff);
    CGContextRelease(maskContext);
    CGColorSpaceRelease(grey);
    return blob;
}

// One cover's colours, as a struct so a block can carry them to the main thread.
typedef struct {
    CGFloat accent[3], text[3];
} SGRReading;

static void publish(SGRReading reading, CGImageRef glow, CGImageRef blob);
static void appearanceAccent(CGFloat out[3]);

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
        CGImageRef small = CGBitmapContextCreateImage(context);

        // Every cover gives a colour, as in the reference theme: a grey one a grey, and one where nothing
        // fits the Appearance accent, as the theme falls back to Spotify's green. A song never wears the last
        // one's (device, 2026-09-21: Dis-le in Backrooms' yellow, a dark cover in the song before's blue).
        CGFloat hue, saturation, l;
        if (!SGRVibrantPick(cover, &hue, &saturation)) {
            CGFloat appearance[3];
            appearanceAccent(appearance);
            toHSL(appearance[0], appearance[1], appearance[2], &hue, &saturation, &l);
        }
        CGImageRelease(cover);
        SGRReading reading = {0};
        fromHSL(hue, saturation, kAccentLightness, reading.accent);
        fromHSL(hue, saturation, kTextLightness, reading.text);
        CGImageRef glow = small ? copyGlow(small) : NULL;
        CGImageRef blob = glow && SGRSongColourMotion() ? copyBlob(glow) : NULL;

        if (small) CGImageRelease(small);
        CGContextRelease(context);
        free(pixels);
        CGColorSpaceRelease(space);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation == sg_generation) publish(reading, glow, blob);
            if (glow) CGImageRelease(glow);
            if (blob) CGImageRelease(blob);
        });
    });
}

#pragma mark - accents worn

// What wears an accent is told by its colour alone, so the test has to be exact. Three things are handed
// out: the accent, the accent darkened (Spotify's older green is 0.86 of the token, and it blends the token
// towards black for its pressed and disabled states), and the accent's text shade. A colour wears an accent
// when it is one of those to within rounding.
//
// It was once any saturated colour near the accent's hue. With a dozen accents remembered their hues
// covered most of the wheel, and colours that were never the accent went with them: a verified badge came
// out mint green (device, 2026-10-05).
typedef struct {
    BOOL text;        // the text shade, else the accent at `factor` of its brightness
    CGFloat factor;
} SGRWear;

// A grey accent is not looked for: every grey would wear it.
static const CGFloat kMinChroma = 0.12, kMinFactor = 0.3, kMaxFactor = 1.04;

static void textShade(const CGFloat accent[3], CGFloat out[3]) {
    CGFloat h, s, l;
    toHSL(accent[0], accent[1], accent[2], &h, &s, &l);
    fromHSL(h, s, kTextLightness, out);
}

static BOOL wears(const CGFloat c[4], const CGFloat accent[3], SGRWear *wear) {
    CGFloat top = MAX(accent[0], MAX(accent[1], accent[2])), low = MIN(accent[0], MIN(accent[1], accent[2]));
    if (top - low < kMinChroma) return NO;
    CGFloat text[3];
    textShade(accent, text);
    if (fabs(c[0] - text[0]) < 0.03 && fabs(c[1] - text[1]) < 0.03 && fabs(c[2] - text[2]) < 0.03) {
        *wear = (SGRWear){YES, 1};
        return YES;
    }
    CGFloat factor = MAX(c[0], MAX(c[1], c[2])) / top;
    if (factor < kMinFactor || factor > kMaxFactor) return NO;
    // Tighter the darker it is: at a third of the accent's brightness the channels are a third as far apart.
    CGFloat slack = 0.015 + 0.03 * factor;
    for (int i = 0; i < 3; i++) {
        if (fabs(c[i] - accent[i] * factor) > slack) return NO;
    }
    *wear = (SGRWear){NO, MIN(1, factor)};
    return YES;
}

// Before the first song the app wears the accent Appearance set, or Spotify's green.
static void appearanceAccent(CGFloat out[3]) {
    UIColor *accent = SGRAccentColor();
    CGFloat a;
    if (!accent || ![accent getRed:&out[0] green:&out[1] blue:&out[2] alpha:&a]) {
        out[0] = 0x1E / 255.0, out[1] = 0xD7 / 255.0, out[2] = 0x60 / 255.0;
    }
}

// The accent worn until now joins the worn ones. The Appearance accent, the first, is never dropped: what
// was painted before the first song can turn up any time.
static void remember(const CGFloat accent[3]) {
    for (NSUInteger i = 0; i < sg_wornCount; i++) {
        if (fabs(sg_worn[i][0] - accent[0]) < 0.004 && fabs(sg_worn[i][1] - accent[1]) < 0.004 && fabs(sg_worn[i][2] - accent[2]) < 0.004) return;
    }
    if (sg_wornCount == kWornMax) {
        memmove(sg_worn[1], sg_worn[2], sizeof(sg_worn[0]) * (kWornMax - 2));
        sg_wornCount--;
    }
    memcpy(sg_worn[sg_wornCount++], accent, sizeof(sg_worn[0]));
}

// How `c` wears an accent, into `wear`: the playing one when `current` allows it, else the latest earlier
// one it matches. Main thread.
static BOOL wornBy(const CGFloat c[4], BOOL current, SGRWear *wear) {
    if (!sg_hasColour || c[3] < 0.05) return NO;
    // Greys first, cheaply: most colours asked about are.
    if (MAX(c[0], MAX(c[1], c[2])) - MIN(c[0], MIN(c[1], c[2])) < 0.03) return NO;
    if (wears(c, sg_accent, wear)) return current;
    for (NSInteger i = (NSInteger)sg_wornCount - 1; i >= 0; i--) {
        if (wears(c, sg_worn[i], wear)) return YES;
    }
    return NO;
}

#pragma mark - recolouring what is on screen

static BOOL white(CGFloat c[4]) {
    return c[0] > 0.93 && c[1] > 0.93 && c[2] > 0.93 && c[3] > 0.9;
}

// What wore an accent as `wear` says, in the playing song's colours.
static UIColor *mapped(SGRWear wear, CGFloat alpha) {
    if (wear.text) return plainColour(sg_text[0], sg_text[1], sg_text[2], alpha);
    return plainColour(sg_accent[0] * wear.factor, sg_accent[1] * wear.factor, sg_accent[2] * wear.factor, alpha);
}

// The same as a live colour, so it follows every song from now on.
static UIColor *liveFor(SGRWear wear, CGFloat alpha) {
    UIColor *fixed = mapped(wear, alpha);
    if (wear.text) return SGRSongLiveText(alpha) ?: fixed;
    return SGRSongLiveAccent(wear.factor, alpha, fixed) ?: fixed;
}

// An earlier accent's CGColor taken to the playing one, retained; NULL when it wears no earlier accent.
static CGColorRef copyRemapped(CGColorRef color) {
    CGFloat c[4];
    SGRWear wear;
    if (!components(color, c) || !wornBy(c, NO, &wear)) return NULL;
    return CGColorRetain(mapped(wear, c[3]).CGColor);
}

static id remappedValue(id value) {
    if (!value || CFGetTypeID((__bridge CFTypeRef)value) != CGColorGetTypeID()) return nil;
    CGColorRef copy = copyRemapped((__bridge CGColorRef)value);
    return copy ? (__bridge_transfer id)copy : nil;
}

// Lottie gives its shapes their colours as animations, even a colour that never changes, and the model
// value under them is not what is drawn. Only on layers of their own, whose animations have no delegate:
// replacing one of UIKit's would end it early and run its completion.
static void recolourAnimations(CALayer *layer) {
    for (NSString *key in layer.animationKeys) {
        CAAnimation *animation = [layer animationForKey:key];
        if (animation.delegate || ![animation isKindOfClass:CAPropertyAnimation.class]) continue;
        NSString *path = ((CAPropertyAnimation *)animation).keyPath;
        if (![path isEqualToString:@"fillColor"] && ![path isEqualToString:@"strokeColor"] && ![path isEqualToString:@"backgroundColor"]) continue;
        CAAnimation *copy = nil;
        if ([animation isKindOfClass:CAKeyframeAnimation.class]) {
            NSArray *values = ((CAKeyframeAnimation *)animation).values;
            NSMutableArray *remapped = nil;
            for (NSUInteger i = 0; i < values.count; i++) {
                id value = remappedValue(values[i]);
                if (!value) continue;
                if (!remapped) remapped = [values mutableCopy];
                remapped[i] = value;
            }
            if (remapped) {
                CAKeyframeAnimation *keyframes = [animation copy];
                keyframes.values = remapped;
                copy = keyframes;
            }
        } else if ([animation isKindOfClass:CABasicAnimation.class]) {
            CABasicAnimation *basic = (CABasicAnimation *)animation;
            id from = remappedValue(basic.fromValue), to = remappedValue(basic.toValue);
            if (from || to) {
                CABasicAnimation *replacement = [basic copy];
                if (from) replacement.fromValue = from;
                if (to) replacement.toValue = to;
                copy = replacement;
            }
        }
        if (copy) [layer addAnimation:copy forKey:key];
    }
}

static void recolourLayer(CALayer *layer, NSUInteger depth) {
    // Lottie nests a shape's fill a good way down.
    if (depth > 12) return;
    CGColorRef copy = copyRemapped(layer.backgroundColor);
    if (copy) {
        layer.backgroundColor = copy;
        CGColorRelease(copy);
    }
    if ([layer isKindOfClass:CAShapeLayer.class]) {
        CAShapeLayer *shape = (CAShapeLayer *)layer;
        if ((copy = copyRemapped(shape.fillColor))) {
            shape.fillColor = copy;
            CGColorRelease(copy);
        }
        if ((copy = copyRemapped(shape.strokeColor))) {
            shape.strokeColor = copy;
            CGColorRelease(copy);
        }
    }
    if (!layer.delegate) recolourAnimations(layer);
    for (CALayer *sub in layer.sublayers) {
        if (sub.delegate) continue;
        recolourLayer(sub, depth + 1);
    }
}

#pragma mark - Spotify's icons

// SPTEncoreIconView (SpotifyShared) draws its glyph in a colour of its own, the accent when it is on:
// shuffle and repeat, the checkmarks. It kept the Appearance green an hour of songs in, or an earlier song's
// colour (device, 2026-09-21), so it is handed live colours, made new on every song so it draws again
// whatever it compares. Its colours are Objective-C properties, UIColor, in the binary's class data.
@protocol SGREncoreIcon <NSObject>
@property (nonatomic, strong) UIColor *foregroundColor;
@property (nonatomic, strong) UIColor *activeForegroundColor;
@end

static Class iconClass(void) {
    static Class icon;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ icon = NSClassFromString(@"SPTEncoreIconView"); });
    return icon;
}

// What an icon should draw with instead of `color`: a new live colour when it is one, or when it wears an
// accent, this song's or an earlier one; nil when it is none of those (white, grey, another colour).
static UIColor *iconColour(UIColor *color) {
    if (!color) return nil;
    CGFloat alpha = CGColorGetAlpha(color.CGColor);
    NSNumber *live = objc_getAssociatedObject(color, &kLiveKey);
    if (live) return live.doubleValue < 0 ? SGRSongLiveText(alpha) : SGRSongLiveAccent(live.doubleValue, alpha, nil);
    CGFloat c[4];
    SGRWear wear;
    if (!components(color.CGColor, c) || !wornBy(c, YES, &wear)) return nil;
    return liveFor(wear, c[3]);
}

static void recolourIcon(UIView *view) {
    NSNumber *seen = objc_getAssociatedObject(view, &kIconSongKey);
    if (seen && seen.unsignedIntegerValue == sg_songs) return;
    objc_setAssociatedObject(view, &kIconSongKey, @(sg_songs), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id<SGREncoreIcon> icon = (id<SGREncoreIcon>)view;
    if ([icon respondsToSelector:@selector(foregroundColor)] && [icon respondsToSelector:@selector(setForegroundColor:)]) {
        UIColor *next = iconColour(icon.foregroundColor);
        if (next) icon.foregroundColor = next;
    }
    if ([icon respondsToSelector:@selector(activeForegroundColor)] && [icon respondsToSelector:@selector(setActiveForegroundColor:)]) {
        UIColor *next = iconColour(icon.activeForegroundColor);
        if (next) icon.activeForegroundColor = next;
    }
}

#pragma mark - glyphs painted in the accent

// Spotify draws some glyphs into images already in their colour: shuffle and repeat in the player and on the
// pages (LegacyUI_ECMCoreKit's EncoreButton, a UIImageView of 24x24), once per state, and hands out that image
// again whatever song plays (device, 2026-09-21: repeat always an old song's red, repeat-one always another's
// gold). An image of the kind is painted again in the playing song's colour as it is set, and again on every
// song. Only a small image whose opaque pixels are all one colour, of an accent this song or an earlier one
// wore: artwork, white and grey glyphs, and anything drawn in two colours stay as they are.
@interface SGRWeak : NSObject
@property (nonatomic, weak) id object;
@end

@implementation SGRWeak
@end

// The one colour of `image`'s opaque pixels, into `out`; NO when it is not a glyph of one colour. Worked out
// once per image.
static BOOL glyphColour(UIImage *image, CGFloat out[4]) {
    NSArray<NSNumber *> *known = objc_getAssociatedObject(image, &kGlyphInfoKey);
    if (!known) {
        known = @[];
        CGSize size = image.size;
        CGImageRef cg = image.CGImage;
        BOOL candidate = cg && !image.isSymbolImage && image.renderingMode != UIImageRenderingModeAlwaysTemplate && !image.images
            && size.width >= 8 && size.height >= 8 && size.width <= 44 && size.height <= 44
            && UIEdgeInsetsEqualToEdgeInsets(image.capInsets, UIEdgeInsetsZero);
        if (candidate) {
            enum { kProbe = 16 };
            uint8_t pixels[kProbe * kProbe * 4] = {0};
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            CGContextRef context = CGBitmapContextCreate(pixels, kProbe, kProbe, 8, kProbe * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
            CGColorSpaceRelease(space);
            CGContextDrawImage(context, CGRectMake(0, 0, kProbe, kProbe), cg);
            CGContextRelease(context);
            CGFloat sum[3] = {0};
            int opaque = 0;
            for (int i = 0; i < kProbe * kProbe; i++) {
                const uint8_t *p = pixels + i * 4;
                if (p[3] < 128) continue;
                for (int c = 0; c < 3; c++) sum[c] += p[c] / (CGFloat)p[3];
                opaque++;
            }
            if (opaque >= 8) {
                CGFloat mean[3] = {sum[0] / opaque, sum[1] / opaque, sum[2] / opaque};
                int alike = 0;
                for (int i = 0; i < kProbe * kProbe; i++) {
                    const uint8_t *p = pixels + i * 4;
                    if (p[3] < 128) continue;
                    CGFloat far = 0;
                    for (int c = 0; c < 3; c++) far = MAX(far, fabs(p[c] / (CGFloat)p[3] - mean[c]));
                    if (far < 0.1) alike++;
                }
                if (alike >= opaque * 0.85) known = @[@(MIN(1, mean[0])), @(MIN(1, mean[1])), @(MIN(1, mean[2])), @1];
            }
        }
        objc_setAssociatedObject(image, &kGlyphInfoKey, known, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (known.count != 4) return NO;
    for (int i = 0; i < 4; i++) out[i] = known[i].doubleValue;
    return YES;
}

// `image` with every pixel `colour`, its alpha kept.
static UIImage *painted(UIImage *image, UIColor *colour) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = image.scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format];
    UIImage *result = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGRect rect = {CGPointZero, image.size};
        [image drawInRect:rect];
        [colour setFill];
        UIRectFillUsingBlendMode(rect, kCGBlendModeSourceIn);
    }];
    if (image.flipsForRightToLeftLayoutDirection) result = [result imageFlippedForRightToLeftLayoutDirection];
    return result;
}

UIImage *SGRSongColourGlyph(UIImage *image) {
    if (!sg_hasColour || !image || !NSThread.isMainThread) return nil;
    UIImage *original = objc_getAssociatedObject(image, &kGlyphOriginalKey);
    if (original) {
        if ([objc_getAssociatedObject(image, &kGlyphSongKey) unsignedIntegerValue] == sg_songs) return nil;
        image = original;
    }
    // One painting per image and song, however often Spotify sets the image again (a button does on each pass).
    UIImage *cached = ((SGRWeak *)objc_getAssociatedObject(image, &kGlyphPaintKey)).object;
    if (cached && [objc_getAssociatedObject(cached, &kGlyphSongKey) unsignedIntegerValue] == sg_songs) return cached;
    // How the image wears an accent is found once and kept on it: by the time Spotify shows it again the
    // accent it was drawn in may have left the worn ones, and the image would keep the last colour it was
    // painted for good.
    NSArray<NSNumber *> *known = objc_getAssociatedObject(image, &kGlyphWearKey);
    SGRWear wear;
    if (known.count == 2) {
        wear = (SGRWear){known[0].boolValue, known[1].doubleValue};
    } else {
        CGFloat c[4];
        if (!glyphColour(image, c)) return nil;
        BOOL current = wears(c, sg_accent, &wear);
        if (!current && !wornBy(c, NO, &wear)) return nil;
        objc_setAssociatedObject(image, &kGlyphWearKey, @[@(wear.text), @(wear.factor)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Drawn in the playing song's colour already: nothing to paint until the next song.
        if (current) return nil;
    }
    UIImage *paint = painted(image, mapped(wear, 1));
    objc_setAssociatedObject(paint, &kGlyphOriginalKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(paint, &kGlyphSongKey, @(sg_songs), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGRWeak *box = [SGRWeak new];
    box.object = paint;
    objc_setAssociatedObject(image, &kGlyphPaintKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return paint;
}

#pragma mark - text that stays white

void SGRSongColourKeepWhite(UILabel *label) {
    if (!label || !SGRSongColourText()) return;
    if (!objc_getAssociatedObject(label, &kKeepWhiteKey)) objc_setAssociatedObject(label, &kKeepWhiteKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSNumber *live = objc_getAssociatedObject(label.textColor, &kLiveKey);
    if (live && live.doubleValue < 0) label.textColor = [UIColor colorWithWhite:1 alpha:CGColorGetAlpha(label.textColor.CGColor)];
    NSAttributedString *text = label.attributedText;
    if (!text.length) return;
    __block NSMutableAttributedString *copy = nil;
    [text enumerateAttribute:NSForegroundColorAttributeName inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
        NSNumber *tag = [value isKindOfClass:UIColor.class] ? objc_getAssociatedObject(value, &kLiveKey) : nil;
        if (!tag || tag.doubleValue >= 0) return;
        if (!copy) copy = [text mutableCopy];
        [copy addAttribute:NSForegroundColorAttributeName value:[UIColor colorWithWhite:1 alpha:CGColorGetAlpha(((UIColor *)value).CGColor)] range:range];
    }];
    if (copy) label.attributedText = copy;
}

BOOL SGRSongColourKeepsWhite(UILabel *label) {
    return objc_getAssociatedObject(label, &kKeepWhiteKey) != nil;
}

#pragma mark - views

// What one view wears itself, and its layer's. A label or a title in an earlier accent takes a live colour.
static void recolourOne(UIView *view) {
    CGFloat c[4];
    SGRWear wear;
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        UIColor *color = label.textColor;
        if (!objc_getAssociatedObject(color, &kLiveKey) && components(color.CGColor, c) && wornBy(c, NO, &wear)) {
            label.textColor = liveFor(wear, c[3]);
        }
    } else if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        if (components([button titleColorForState:UIControlStateNormal].CGColor, c) && wornBy(c, NO, &wear)) {
            [button setTitleColor:liveFor(wear, c[3]) forState:UIControlStateNormal];
        }
    } else if ([view isKindOfClass:UIImageView.class]) {
        UIImageView *imageView = (UIImageView *)view;
        UIImage *glyph = SGRSongColourGlyph(imageView.image);
        if (glyph) imageView.image = glyph;
        // A glyph drawn in its tint: what the tint is, only a template shows.
        UIImage *image = imageView.image;
        if (image && (image.renderingMode == UIImageRenderingModeAlwaysTemplate || image.isSymbolImage)
            && components(imageView.tintColor.CGColor, c) && wornBy(c, NO, &wear)) {
            imageView.tintColor = liveFor(wear, c[3]);
        }
    } else if (iconClass() && [view isKindOfClass:iconClass()]) {
        recolourIcon(view);
    }
    recolourLayer(view.layer, 0);
}

// The lyrics draw in the player's colours, not the accent, and hold a label for every word in sight.
static BOOL skipped(UIView *view) {
    return [view isKindOfClass:SGRSongGlowView.class] || strncmp(class_getName(object_getClass(view)), "SGRKaraoke", 10) == 0;
}

static void recolourView(UIView *view) {
    if (skipped(view)) return;
    CGFloat c[4];
    if (SGRSongColourText() && [view isKindOfClass:UILabel.class] && !SGRSongColourKeepsWhite((UILabel *)view)) {
        UILabel *label = (UILabel *)view;
        if (components(label.textColor.CGColor, c) && white(c)) label.textColor = SGRSongLiveText(c[3]);
    }
    recolourOne(view);
    for (UIView *sub in view.subviews) recolourView(sub);
}

void SGRSongColourCatchUp(UIView *view) {
    if (!sg_hasColour || !NSThread.isMainThread || skipped(view)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    recolourOne(view);
    [CATransaction commit];
}

static void recolourWindows(void) {
    UIColor *tint = plainColour(sg_accent[0], sg_accent[1], sg_accent[2], 1);
    tint = SGRSongLiveAccent(1, 1, tint) ?: tint;
    if (@available(iOS 17.0, *)) sg_traitValue++;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if ([NSStringFromClass(window.class) containsString:@"FLEX"]) continue;
            // Every live colour in the window, and in whatever joins it later, resolves again.
            if (@available(iOS 17.0, *)) [window.traitOverrides setNSIntegerValue:sg_traitValue forTrait:SGRSongTrait.class];
            window.tintColor = tint;
            if (!window.hidden) recolourView(window);
        }
    }
}

static void publish(SGRReading reading, CGImageRef glow, CGImageRef blob) {
    CGFloat *accent = reading.accent, *text = reading.text;
    if (glow) sg_glow = [UIImage imageWithCGImage:glow];
    if (blob) sg_blob = [UIImage imageWithCGImage:blob];
    CGFloat before[3];
    if (sg_hasColour) memcpy(before, sg_accent, sizeof(before));
    else appearanceAccent(before);
    if (!sg_wornCount) {
        CGFloat appearance[3];
        appearanceAccent(appearance);
        remember(appearance);
    }
    remember(before);
    os_unfair_lock_lock(&sg_lock);
    memcpy(sg_accent, accent, sizeof(sg_accent));
    memcpy(sg_text, text, sizeof(sg_text));
    sg_hasColour = YES;
    os_unfair_lock_unlock(&sg_lock);
    sg_songs++;
    [NSNotificationCenter.defaultCenter postNotificationName:SGRSongColourDidChangeNotification object:nil];
    recolourWindows();

    static NSUInteger logged;
    if (logged++ < 40) {
        SGLog(@"song colour: glow %@, accent #%02X%02X%02X", glow ? @"ready" : @"none",
              (int)(accent[0] * 255), (int)(accent[1] * 255), (int)(accent[2] * 255));
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

#pragma mark - the glow's clock

// Moving glow keeps one clock for every glow, so going from one screen to another does not jump, and a new
// speed carries on from where each disc is rather than jumping to where the new one would have it.
NSNotificationName const SGRSongColourMotionSpeedDidChangeNotification = @"spotifyglass.redesign.songColourMotionSpeedDidChange";
static CFTimeInterval sg_turnEpoch, sg_turnPeriod[2];   // main thread
static CGFloat sg_turnPhase[2];                         // at the epoch, a share of a turn

NSInteger SGRSongColourMotionSpeed(void) {
    return MAX(SGRMotionSpeedMin, MIN(SGRMotionSpeedMax, SGInt(SGRKeySongColourMotionSpeed, SGRMotionSpeedDefault)));
}

static CFTimeInterval periodOf(NSUInteger disc) {
    return 60.0 / SGRSongColourMotionSpeed() * (disc ? kSecondTurn : 1);
}

static CGFloat phaseOf(NSUInteger disc, CFTimeInterval now) {
    if (!sg_turnPeriod[0]) {
        sg_turnEpoch = now;
        for (NSUInteger i = 0; i < 2; i++) sg_turnPeriod[i] = periodOf(i);
    }
    return fmod(sg_turnPhase[disc] + (now - sg_turnEpoch) / sg_turnPeriod[disc], 1);
}

void SGRSongColourMotionSpeedChanged(void) {
    CFTimeInterval now = CACurrentMediaTime();
    for (NSUInteger i = 0; i < 2; i++) sg_turnPhase[i] = phaseOf(i, now);
    for (NSUInteger i = 0; i < 2; i++) sg_turnPeriod[i] = periodOf(i);
    sg_turnEpoch = now;
    [NSNotificationCenter.defaultCenter postNotificationName:SGRSongColourMotionSpeedDidChangeNotification object:nil];
}

// The still glow is one layer, the cover filling the view. Moving glow puts two turning discs of it in
// its place (kBlobCentre), unless Reduce Motion is on.
@implementation SGRSongGlowView {
    CALayer *_black;
    NSArray<CALayer *> *_glows;
    BOOL _turns;
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
    _turns = SGRSongColourMotion() && !SGRReduceMotion();
    NSMutableArray<CALayer *> *glows = [NSMutableArray array];
    for (NSUInteger i = 0; i < (_turns ? 2 : 1); i++) {
        CALayer *glow = [CALayer layer];
        glow.actions = noActions();
        glow.contentsGravity = kCAGravityResizeAspectFill;
        glow.opacity = _turns ? kBlobOpacity[i] : kGlowOpacity;
        glow.contents = [self sgr_contents];
        [self.layer addSublayer:glow];
        [glows addObject:glow];
    }
    _glows = glows;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sgr_songColourDidChange)
                                               name:SGRSongColourDidChangeNotification object:nil];
    if (_turns) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sgr_speedDidChange)
                                                   name:SGRSongColourMotionSpeedDidChangeNotification object:nil];
    }
    return self;
}

- (void)sgr_speedDidChange {
    for (CALayer *glow in _glows) [glow removeAnimationForKey:@"sgr.turn"];
    [self sgr_turn];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (id)sgr_contents {
    return (__bridge id)(_turns ? sg_blob : sg_glow).CGImage;
}

- (void)sgr_songColourDidChange {
    id contents = [self sgr_contents];
    for (CALayer *glow in _glows) {
        if (glow.contents == contents) continue;
        if (self.window) {
            CATransition *fade = [CATransition animation];
            fade.type = kCATransitionFade;
            fade.duration = SGRCrossfade;
            [glow addAnimation:fade forKey:@"contents"];
        }
        glow.contents = contents;
    }
}

// Each disc turns about its own middle, for good, by the glows' one clock. No frame rate is asked for: an
// animation asking for less than the screen's can hold the player's 120 Hz animations down (SGRKaraokeView.m).
- (void)sgr_turn {
    if (!_turns) return;
    CFTimeInterval now = CACurrentMediaTime();
    for (NSUInteger i = 0; i < _glows.count; i++) {
        CALayer *glow = _glows[i];
        if ([glow animationForKey:@"sgr.turn"]) continue;
        CGFloat phase = phaseOf(i, now);
        CABasicAnimation *turn = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        turn.fromValue = @0;
        turn.toValue = @(i ? -2 * M_PI : 2 * M_PI);
        turn.duration = sg_turnPeriod[i];
        turn.repeatCount = HUGE_VALF;
        // Kept through a trip to the background, which would otherwise take it off.
        turn.removedOnCompletion = NO;
        turn.timeOffset = phase * sg_turnPeriod[i];
        [glow addAnimation:turn forKey:@"sgr.turn"];
    }
}

// A glow that was off screen while the song changed catches up as it comes back.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) return;
    id contents = [self sgr_contents];
    for (CALayer *glow in _glows) {
        if (glow.contents != contents) glow.contents = contents;
    }
    [self sgr_turn];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _black.frame = bounds;
    if (_turns) {
        CGFloat side = MAX(bounds.size.width, bounds.size.height) * kBlobSide;
        for (NSUInteger i = 0; i < _glows.count; i++) {
            _glows[i].bounds = CGRectMake(0, 0, side, side);
            _glows[i].position = CGPointMake(CGRectGetMinX(bounds) + bounds.size.width * kBlobCentre[i].x,
                                             CGRectGetMinY(bounds) + bounds.size.height * kBlobCentre[i].y);
        }
    } else {
        // Wider than the screen, as the reference draws it, so the blur's edges are never seen.
        _glows.firstObject.frame = CGRectInset(bounds, -bounds.size.width * 0.2, 0);
    }
    [CATransaction commit];
}

@end

#pragma mark - a patch of the glow

// Every glow fills its screen from the window's corner, so a glow laid out over the window's bounds, seen
// through the patch's own, is the same picture in the same place, and the two discs of a moving one keep
// the same time.
@interface SGRSongGlowPatch ()
- (void)sgr_place;
@end

@implementation SGRSongGlowPatch {
    SGRSongGlowView *_glow;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    self.clipsToBounds = YES;
    _glow = [SGRSongGlowView new];
    [self addSubview:_glow];
    return self;
}

- (void)sgr_place {
    UIWindow *window = self.window;
    if (!window) return;
    CGRect screen = [self convertRect:window.bounds fromView:nil];
    if (!CGRectEqualToRect(_glow.frame, screen)) _glow.frame = screen;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self sgr_place];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self sgr_place];
}

@end

SGRSongGlowPatch *SGRSongColourPatchIn(UIView *host, BOOL front) {
    if (!host || !SGRSongColour()) return nil;
    SGRSongGlowPatch *patch = objc_getAssociatedObject(host, &kPatchKey);
    if (!patch) {
        patch = [SGRSongGlowPatch new];
        patch.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(host, &kPatchKey, patch, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (patch.superview != host) {
        if (front) [host addSubview:patch];
        else [host insertSubview:patch atIndex:0];
    } else if (front && host.subviews.lastObject != patch) {
        [host bringSubviewToFront:patch];
    } else if (!front && host.subviews.firstObject != patch) {
        [host sendSubviewToBack:patch];
    }
    if (!CGRectEqualToRect(patch.frame, host.bounds)) patch.frame = host.bounds;
    [patch sgr_place];
    return patch;
}

#pragma mark - screens

static BOOL isOwn(UIView *view) {
    return [view isKindOfClass:SGRSongGlowView.class];
}

// What a glowing screen leaves its paint: pictures, labels and hairlines. A view with no size yet is not a
// hairline. The Library's rows are painted the base surface as they are made, before they are laid out, and
// kept as hairlines they stayed black over the glow, new rows only, so the list came out striped (device
// dumps, 2026-10-05).
BOOL SGRSongColourKeeps(UIView *view) {
    if ([view isKindOfClass:UIImageView.class] || [view isKindOfClass:UILabel.class]) return YES;
    CGFloat height = view.bounds.size.height;
    return height > 0 && height <= 4;
}

static void clearBase(UIView *view) {
    if (isOwn(view)) return;
    if (!SGRSongColourKeeps(view) && SGIsBaseSurface(view.layer.backgroundColor)) view.layer.backgroundColor = NULL;
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
