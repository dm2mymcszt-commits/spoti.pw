// Fork: the colour of what is playing, carried through the whole app. The cover's palette (SGRPalette)
// gives two colours on every track change:
//
//   the surface   a near black tinted by the cover, which SGRAmoled.x paints wherever Spotify paints its
//                 base grey: Home, Search, Library, the settings lists, rows and the gradients into them
//   the accent    a lively colour from the cover, which SGRAccent.x swaps Spotify's green for
//
// The switch is Appearance's Dynamic colour, read at launch. The accent reaches what is drawn after it
// changes, since the swap happens where a colour is made; the surfaces on screen are repainted at once.
//
// Threading: the palette is asked for and answered on the main thread, and the two colours are written
// there. They are read from any thread (layers are painted off the main one), under a lock.
#import <UIKit/UIKit.h>

#define SGRKeyDynamicColor @"spotifyglass.redesign.dynamic"

BOOL SGRDynamicColor(void);   // the switch, read at launch

// The current colours, NO until a cover has been read. Any thread.
BOOL SGRDynamicSurface(CGFloat *r, CGFloat *g, CGFloat *b);
BOOL SGRDynamicAccent(CGFloat *r, CGFloat *g, CGFloat *b);

// Starts following the now playing artwork; called once from a %ctor that has the switch on.
void SGRDynamicStart(void);
