// Fork: the colour DefaultDynamic, the Spicetify theme Song colour follows, picks for a cover, reproduced from
// the Vibrant.js 1.0 it ships (Themes/DefaultDynamic/Vibrant.min.js) so a song wears the colour it wears on the
// desktop. The cover is quantized to 12 colours by MMCQ (quantize.js, the median cut Vibrant.js carries); the
// theme then takes Vibrant, else Light Vibrant, else Muted, else Dark Vibrant.
//
// Vibrant.js ranks the colours that fit a swatch by a score it never computes (HighestPopulation stays 0, so
// every score is infinite), which makes the first colour that fits the one, in the order the quantizer hands
// them out: largest box, by pixels times volume, first. That is kept, since it is what the theme shows.
//
// Any thread.
#import <CoreGraphics/CoreGraphics.h>

// The picked colour's hue and saturation (HSL, 0 to 1). NO when no swatch fits, where the theme falls back to
// Spotify's green.
BOOL SGRVibrantPick(CGImageRef cover, CGFloat *hue, CGFloat *saturation);
