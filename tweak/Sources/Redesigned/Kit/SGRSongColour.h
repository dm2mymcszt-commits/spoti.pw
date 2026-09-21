// Fork: Song colour, the whole app worn in the colour of what is playing (the user's reference is the
// DefaultDynamic Spicetify theme). On every track change the cover gives three things, worked out off the
// main thread from one small copy of it:
//
//   the glow     the cover itself, blurred hard and saturated, behind every screen at kGlowOpacity over
//                black: Home, Search, Library, the settings, and the album, playlist and artist pages (whose
//                SGRArtworkField shows it instead of their own cover's colour). The player keeps its own.
//   the accent   the cover's most vibrant colour at a mid lightness, in place of Spotify's green
//                (SGRAccent.x swaps it where a colour is made)
//   the text     the same hue, lighter, for the labels Spotify draws white (Tint text, its own switch)
//
// What is already on screen is recoloured at once on a change: the glows crossfade, and a walk over the
// windows takes every label, layer and shape still in the last song's colours to the new ones. What is
// drawn after takes the new colours where it is made. A grey or black and white cover leaves the accent
// and the text as they were, and gives a grey glow.
//
// Threading: the colours are read from any thread (layers are painted off the main one), under a lock;
// everything else is main thread only.
#import <UIKit/UIKit.h>

#define SGRKeySongColour @"spotifyglass.redesign.songColour"
#define SGRKeySongColourText @"spotifyglass.redesign.songColourText"

// Posted on the main thread when the colours of a new song are in.
extern NSNotificationName const SGRSongColourDidChangeNotification;

BOOL SGRSongColour(void);       // the switch, read at launch
BOOL SGRSongColourText(void);   // Tint text, read at launch; NO while Song colour is off

// The current colours, NO until a cover has been read (or while it is grey). Any thread.
BOOL SGRSongAccent(CGFloat *r, CGFloat *g, CGFloat *b);
BOOL SGRSongText(CGFloat *r, CGFloat *g, CGFloat *b);

// Starts following the now playing artwork; once, from the %ctor of SGRSongColourHosts.x.
void SGRSongColourStart(void);

// The glow behind a screen: black with the song's blurred cover over it, crossfading on every song.
@interface SGRSongGlowView : UIView
@end

// Puts a glow behind `root` (its backgroundView when it is a table or collection view, else its first
// subview) and keeps Spotify's base surface inside it clear from now on, so the glow shows through.
void SGRSongColourAdopt(UIView *root);
// Whether `view` sits inside an adopted root. Main thread; NO from any other.
BOOL SGRSongColourClears(UIView *view);
