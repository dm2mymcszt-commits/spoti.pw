// Workarounds for iOS versions before 26 (fork only, skopevoj/spoti.pw#37).
//
// The parts that hide sections by resizing Element_List cells (AlbumSections, ArtistSections,
// HomeSections, SearchSections, PlayerCards) report a height from
// -preferredLayoutAttributesFittingAttributes: that the cell then re-applies in -layoutSubviews. On
// iOS 17.0 the self-sizing pass keeps asking again, the main thread spins, and the watchdog kills
// Spotify. Each part has its own switch, on until switched off, so the one that loops can be found:
// while a part's switch is on its sections stay as Spotify lays them out; the player keeps its cards and
// scrolls down to them, and only its Lyrics preview is collapsed (PlayerCards.x, PlayerScroll.x).
// From iOS 26 on there is no switch and every part resizes as it always has.
#import "Settings/SGModPage.h"

// @"album", @"artist", @"home", @"search" or @"player". Read at launch: gate the part's %ctor on it,
// after SGRedesignedUI().
BOOL SGRResizesListCells(NSString *part);

// The Workaround section of the Mod Settings root page, or nil from iOS 26 on. A switch quits Spotify.
SGModSection *SGRWorkaroundSection(void);
