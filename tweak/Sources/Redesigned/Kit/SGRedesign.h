// The flags the redesign is built on. A redesigned screen, and the glass design Spotify ships switched
// off (SGRGlassDesign.x), register theirs from a %ctor whether or not Redesigned UI is on: the settings
// rows need the list to lock theirs. Only while Redesigned UI was on at launch is anything forced,
// and then over an override from the All flags page too (Core/SGFlagForce.h). The switch itself is
// Core/SGUIMode.h's.
// Threading: register from a %ctor, before Spotify reads a flag.
#import <Foundation/Foundation.h>

void SGRedesignForceFlags(NSString *owner, NSDictionary<NSString *, id> *flags);

// Whether the parts that resize Element_List cells (AlbumSections, ArtistSections, HomeSections,
// PlayerCards, SearchSections) hook them. Before iOS 26 the self-sizing pass keeps asking for the
// size they change and the main thread spins until the watchdog kills the app (iOS 17.0, issue #37),
// so there those sections stay as Spotify lays them out unless the switch below is turned off.
// Gate their %ctor on it after SGRedesignedUI(). Read at launch.
BOOL SGRResizesListCells(void);

// The switch for that, shown only before iOS 26; unset is on.
#define SGRKeyListFreezeFix @"spotifyglass.redesign.listFreezeFix"
