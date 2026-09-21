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
// The accent and the text are live colours (SGRSongLiveAccent, SGRSongLiveText): they resolve to the playing
// song's whenever UIKit draws them. Spotify makes its colours once and keeps them (its green is one cached
// object), and a cell can be off screen while the song changes, so a colour fixed where it was made kept
// the first song's, or the last one it saw (device dump, 2026-09-21: labels of two songs side by side). A
// change sets a trait of the mod's own on every window (iOS 17's custom traits, affecting colour
// appearance), which makes UIKit redraw every live colour on screen and in any view that comes back to
// one. Colours a layer was handed as a CGColor are taken over by a walk over the windows. The glows
// crossfade. A grey or black and white cover leaves the accent and the text as they were.
//
// Every accent worn since launch is remembered, the Appearance one first, because the walk only sees what
// is in a window: a play indicator, a checkmark or a cell sitting in a reuse queue while the song changed
// kept that song's colour, and a later walk, looking for the colour just replaced, never matched it again
// (device, 2026-09-21: an earlier song's pink indicator on a teal song, the Appearance green on shuffle,
// repeat and checkmarks an hour in). A colour of any worn accent is taken to the playing one by the walk,
// and again as its view joins a window (SGRSongColourCatchUp). Spotify's icons (SPTEncoreIconView, in
// SpotifyShared) draw from colours of their own and are handed live ones.
//
// Moving glow (off until asked for) turns the glow the way the reference theme does: two soft copies of the
// cover, off centre, each rotating slowly about its own middle. Core Animation runs it, but everything over
// it is composited again on every frame, the glass included, so it costs battery.
//
// Threading: the colours are read from any thread (layers are painted off the main one), under a lock;
// everything else is main thread only.
#import <UIKit/UIKit.h>

#define SGRKeySongColour @"spotifyglass.redesign.songColour"
#define SGRKeySongColourText @"spotifyglass.redesign.songColourText"
#define SGRKeySongColourMotion @"spotifyglass.redesign.songColourMotion"

// Posted on the main thread when the colours of a new song are in.
extern NSNotificationName const SGRSongColourDidChangeNotification;

BOOL SGRSongColour(void);       // the switch, read at launch
BOOL SGRSongColourText(void);   // Tint text, read at launch; NO while Song colour is off
BOOL SGRSongColourMotion(void); // Moving glow, read at launch; NO while Song colour is off

// The current colours, NO until a cover has been read (or while it is grey). Any thread.
BOOL SGRSongAccent(CGFloat *r, CGFloat *g, CGFloat *b);
BOOL SGRSongText(CGFloat *r, CGFloat *g, CGFloat *b);

// Live colours: Spotify's green at `factor` of its brightness (its darker states), and the text tint. They
// resolve to `fallback` (or white for the text) until a song's colours are in. nil with the switch off or
// below iOS 17, where the caller keeps its fixed colour.
UIColor *SGRSongLiveAccent(CGFloat factor, CGFloat alpha, UIColor *fallback);
UIColor *SGRSongLiveText(CGFloat alpha);

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

// Takes whatever `view` itself wears in an earlier song's accent to the playing one: its own colours and
// its layer's, not its subviews', which arrive in a window each on their own. From -didMoveToWindow.
void SGRSongColourCatchUp(UIView *view);
