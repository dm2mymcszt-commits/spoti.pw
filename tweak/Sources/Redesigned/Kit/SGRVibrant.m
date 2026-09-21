#import <Foundation/Foundation.h>
#import "SGRVibrant.h"

// DefaultDynamic calls `new Vibrant(img, 12)`: 12 colours, Vibrant's default quality of every fifth pixel, on
// the cover as the browser loads it (300 pixels across for the now playing cover).
static const int kColours = 12, kQuality = 5;
static const size_t kSide = 300;
// quantize.js
enum { kSigBits = 5, kShift = 8 - kSigBits, kCells = 1 << (3 * kSigBits), kAxis = 1 << kSigBits, kMaxBoxes = 64 };
static const int kMaxIterations = 1000;
static const double kFractByPopulations = 0.75;
// Vibrant.js's swatches.
static const double kMinNormalLuma = 0.3, kMaxNormalLuma = 0.7;
static const double kMinLightLuma = 0.55, kMaxDarkLuma = 0.45;
static const double kMinVibrantSaturation = 0.35, kMaxMutedSaturation = 0.4;

static inline int cell(int r, int g, int b) {
    return (r << (2 * kSigBits)) + (g << kSigBits) + b;
}

#pragma mark - boxes

// A box of the colour cube, in quantized steps; its pixels and its volume kept, as quantize.js caches them. A
// cut can leave the upper half empty, one step past its end, which counts nothing and has no volume.
typedef struct {
    int r1, r2, g1, g2, b1, b2;
    long count, volume;
} SGRBox;

static SGRBox boxMake(int r1, int r2, int g1, int g2, int b1, int b2, const uint32_t *histo) {
    SGRBox box = {r1, r2, g1, g2, b1, b2, 0, 0};
    box.volume = (long)(r2 - r1 + 1) * (g2 - g1 + 1) * (b2 - b1 + 1);
    for (int i = r1; i <= r2; i++) {
        for (int j = g1; j <= g2; j++) {
            for (int k = b1; k <= b2; k++) box.count += histo[cell(i, j, k)];
        }
    }
    return box;
}

static SGRBox boxWith(SGRBox box, char axis, BOOL upper, int value, const uint32_t *histo) {
    int r1 = box.r1, r2 = box.r2, g1 = box.g1, g2 = box.g2, b1 = box.b1, b2 = box.b2;
    int *field = axis == 'r' ? (upper ? &r2 : &r1) : axis == 'g' ? (upper ? &g2 : &g1) : (upper ? &b2 : &b1);
    *field = value;
    return boxMake(r1, r2, g1, g2, b1, b2, histo);
}

static void boxAverage(const SGRBox *box, const uint32_t *histo, int out[3]) {
    const int mult = 1 << kShift;
    double total = 0, r = 0, g = 0, b = 0;
    for (int i = box->r1; i <= box->r2; i++) {
        for (int j = box->g1; j <= box->g2; j++) {
            for (int k = box->b1; k <= box->b2; k++) {
                double h = histo[cell(i, j, k)];
                total += h;
                r += h * (i + 0.5) * mult, g += h * (j + 0.5) * mult, b += h * (k + 0.5) * mult;
            }
        }
    }
    if (total > 0) {
        out[0] = (int)(r / total), out[1] = (int)(g / total), out[2] = (int)(b / total);
    } else {
        out[0] = (int)(mult * (box->r1 + box->r2 + 1) / 2.0);
        out[1] = (int)(mult * (box->g1 + box->g2 + 1) / 2.0);
        out[2] = (int)(mult * (box->b1 + box->b2 + 1) / 2.0);
    }
}

// quantize.js's median cut: along the longest side, at the step where the pixels pass half, moved into the
// larger side and kept off empty steps. NO when there is nothing to cut; a single pixel comes back whole.
static BOOL cut(SGRBox box, const uint32_t *histo, SGRBox *first, SGRBox *second, BOOL *two) {
    if (!box.count) return NO;
    int rw = box.r2 - box.r1 + 1, gw = box.g2 - box.g1 + 1, bw = box.b2 - box.b1 + 1;
    int longest = MAX(rw, MAX(gw, bw));
    if (box.count == 1) {
        *first = box;
        *two = NO;
        return YES;
    }
    char axis = longest == rw ? 'r' : longest == gw ? 'g' : 'b';
    int lo = axis == 'r' ? box.r1 : axis == 'g' ? box.g1 : box.b1;
    int hi = axis == 'r' ? box.r2 : axis == 'g' ? box.g2 : box.b2;
    // The pixels up to and including each step along the axis, and those after it.
    long partial[kAxis] = {0}, ahead[kAxis] = {0}, total = 0;
    for (int i = lo; i <= hi; i++) {
        long sum = 0;
        for (int r = box.r1; r <= box.r2; r++) {
            if (axis == 'r' && r != i) continue;
            for (int g = box.g1; g <= box.g2; g++) {
                if (axis == 'g' && g != i) continue;
                for (int b = box.b1; b <= box.b2; b++) {
                    if (axis == 'b' && b != i) continue;
                    sum += histo[cell(r, g, b)];
                }
            }
        }
        total += sum;
        partial[i] = total;
    }
    for (int i = lo; i <= hi; i++) ahead[i] = total - partial[i];
    for (int i = lo; i <= hi; i++) {
        if (partial[i] <= total / 2.0) continue;
        int left = i - lo, right = hi - i, d2;
        if (left <= right) d2 = MIN(hi - 1, (int)(i + right / 2.0));
        else d2 = MAX(lo, (int)(i - 1 - left / 2.0));
        while (d2 < kAxis - 1 && !partial[d2]) d2++;
        long after = ahead[d2];
        while (!after && d2 > 0 && partial[d2 - 1]) after = ahead[--d2];
        *first = boxWith(box, axis, YES, d2, histo);
        *second = boxWith(box, axis, NO, d2 + 1, histo);
        *two = YES;
        return YES;
    }
    return NO;
}

#pragma mark - quantize.js's queue

// Sorted on the way out, stably, as Array.prototype.sort is; the last is taken.
typedef struct {
    SGRBox boxes[kMaxBoxes];
    int size;
    BOOL byVolume;
} SGRQueue;

static long queueKey(const SGRQueue *queue, const SGRBox *box) {
    return queue->byVolume ? box->count * box->volume : box->count;
}

static void queuePush(SGRQueue *queue, SGRBox box) {
    if (queue->size < kMaxBoxes) queue->boxes[queue->size++] = box;
}

static SGRBox queuePop(SGRQueue *queue) {
    for (int i = 1; i < queue->size; i++) {
        SGRBox box = queue->boxes[i];
        long key = queueKey(queue, &box);
        int j = i - 1;
        while (j >= 0 && queueKey(queue, &queue->boxes[j]) > key) {
            queue->boxes[j + 1] = queue->boxes[j];
            j--;
        }
        queue->boxes[j + 1] = box;
    }
    return queue->boxes[--queue->size];
}

static void iterate(SGRQueue *queue, double target, const uint32_t *histo) {
    int colours = 1, iterations = 0;
    while (iterations < kMaxIterations && queue->size) {
        SGRBox box = queuePop(queue);
        if (!box.count) {
            queuePush(queue, box);
            iterations++;
            continue;
        }
        SGRBox first, second;
        BOOL two = NO;
        if (!cut(box, histo, &first, &second, &two)) return;
        queuePush(queue, first);
        if (two) {
            queuePush(queue, second);
            colours++;
        }
        if (colours >= target) return;
        if (iterations++ > kMaxIterations) return;
    }
}

#pragma mark - swatches

typedef struct {
    double h, s, l;
} SGRSwatch;

static SGRSwatch swatchOf(const int rgb[3]) {
    double r = rgb[0] / 255.0, g = rgb[1] / 255.0, b = rgb[2] / 255.0;
    double max = MAX(r, MAX(g, b)), min = MIN(r, MIN(g, b)), d = max - min;
    SGRSwatch swatch = {0, 0, (max + min) / 2};
    if (d > 0) {
        swatch.s = swatch.l > 0.5 ? d / (2 - max - min) : d / (max + min);
        if (max == r) swatch.h = (g - b) / d + (g < b ? 6 : 0);
        else if (max == g) swatch.h = (b - r) / d + 2;
        else swatch.h = (r - g) / d + 4;
        swatch.h /= 6;
    }
    return swatch;
}

// Vibrant.js's findColorVariation as it behaves: the first swatch in the ranges that is not already taken.
static int findVariation(const SGRSwatch *swatches, int count, double minLuma, double maxLuma, double minSaturation,
                         double maxSaturation, const int *taken, int takenCount) {
    for (int i = 0; i < count; i++) {
        BOOL used = NO;
        for (int t = 0; t < takenCount; t++) used |= taken[t] == i;
        const SGRSwatch *s = &swatches[i];
        if (used || s->s < minSaturation || s->s > maxSaturation || s->l < minLuma || s->l > maxLuma) continue;
        return i;
    }
    return -1;
}

BOOL SGRVibrantPick(CGImageRef cover, CGFloat *hue, CGFloat *saturation) {
    if (!cover) return NO;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    uint8_t *pixels = calloc(kSide * kSide * 4, 1);
    CGContextRef context = CGBitmapContextCreate(pixels, kSide, kSide, 8, kSide * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) {
        free(pixels);
        return NO;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), cover);
    CGContextRelease(context);

    // Every fifth pixel, as a canvas reads them, row by row from the top; the transparent and the white left out.
    uint32_t *histo = calloc(kCells, sizeof(uint32_t));
    int rmin = kAxis, rmax = -1, gmin = kAxis, gmax = -1, bmin = kAxis, bmax = -1;
    for (size_t i = 0; i < kSide * kSide; i += kQuality) {
        const uint8_t *p = pixels + i * 4;
        if (p[3] < 125) continue;
        int r = p[0], g = p[1], b = p[2];
        if (p[3] < 255) r = MIN(255, r * 255 / p[3]), g = MIN(255, g * 255 / p[3]), b = MIN(255, b * 255 / p[3]);
        if (r > 250 && g > 250 && b > 250) continue;
        int qr = r >> kShift, qg = g >> kShift, qb = b >> kShift;
        histo[cell(qr, qg, qb)]++;
        rmin = MIN(rmin, qr), rmax = MAX(rmax, qr), gmin = MIN(gmin, qg), gmax = MAX(gmax, qg), bmin = MIN(bmin, qb), bmax = MAX(bmax, qb);
    }
    free(pixels);
    if (rmax < 0) {
        free(histo);
        return NO;
    }

    SGRQueue *byCount = calloc(1, sizeof(SGRQueue)), *byVolume = calloc(1, sizeof(SGRQueue));
    byVolume->byVolume = YES;
    queuePush(byCount, boxMake(rmin, rmax, gmin, gmax, bmin, bmax, histo));
    iterate(byCount, kFractByPopulations * kColours, histo);
    while (byCount->size) queuePush(byVolume, queuePop(byCount));
    iterate(byVolume, kColours - byVolume->size, histo);

    // The colour map, in the order its boxes come off the queue.
    SGRSwatch swatches[kMaxBoxes];
    int count = 0;
    while (byVolume->size) {
        SGRBox box = queuePop(byVolume);
        int rgb[3];
        boxAverage(&box, histo, rgb);
        swatches[count++] = swatchOf(rgb);
    }
    free(byCount);
    free(byVolume);
    free(histo);

    int taken[3] = {0}, takenCount = 0;
    int vibrant = findVariation(swatches, count, kMinNormalLuma, kMaxNormalLuma, kMinVibrantSaturation, 1, taken, takenCount);
    if (vibrant >= 0) taken[takenCount++] = vibrant;
    int lightVibrant = findVariation(swatches, count, kMinLightLuma, 1, kMinVibrantSaturation, 1, taken, takenCount);
    if (lightVibrant >= 0) taken[takenCount++] = lightVibrant;
    int darkVibrant = findVariation(swatches, count, 0, kMaxDarkLuma, kMinVibrantSaturation, 1, taken, takenCount);
    if (darkVibrant >= 0) taken[takenCount++] = darkVibrant;
    int muted = findVariation(swatches, count, kMinNormalLuma, kMaxNormalLuma, 0, kMaxMutedSaturation, taken, takenCount);

    // With no Vibrant, one is made from Dark Vibrant at the normal lightness: the same hue and saturation.
    int picked = vibrant >= 0 ? vibrant : darkVibrant >= 0 ? darkVibrant : lightVibrant >= 0 ? lightVibrant : muted;
    if (picked < 0) return NO;
    *hue = swatches[picked].h;
    *saturation = swatches[picked].s;
    return YES;
}
