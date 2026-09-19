#import "Core/SGCore.h"
#import "SGRWorkaround.h"

static NSString *keyFor(NSString *part) {
    return [@"spotifyglass.redesign.workaround." stringByAppendingString:part];
}

static BOOL needed(void) {
    if (@available(iOS 26.0, *)) return NO;
    return YES;
}

BOOL SGRResizesListCells(NSString *part) {
    if (!needed()) return YES;
    BOOL workaround = SGEnabled(keyFor(part));
    SGLog(@"redesign %@: %@", part, workaround ? @"workaround on, list cells left at Spotify's size" : @"workaround off, list cells resized");
    return !workaround;
}

// The switches are read at launch, so a flip ends Spotify straight away rather than leaving it half
// in the old state; it opens again from the Home Screen.
static SGModRow *row(NSString *title, NSString *subtitle, NSString *part, NSString *symbol) {
    SGModRow *row = SGSwitchRow(title, subtitle, keyFor(part));
    row.changed = ^(BOOL on) { SGRestartSpotify(); };
    return SGWithSymbol(row, symbol);
}

SGModSection *SGRWorkaroundSection(void) {
    if (!needed()) return nil;
    return SGNotedSection(@"Workaround", @[
        row(@"Album pages", @"More by the artist and the rest under the tracks stay", @"album", @"square.stack"),
        row(@"Artist pages", @"The videos stay in the Music list", @"artist", @"music.mic"),
        row(@"Home", @"The sections the redesign drops stay", @"home", @"house"),
        row(@"Search", @"The carousels and promos stay above the categories", @"search", @"magnifyingglass"),
        row(@"Player", @"The cards under the player are hidden without resizing them", @"player", @"play.rectangle"),
    ], @"Before iOS 26, hiding these sections by resizing them can freeze Spotify. A switch on keeps that part safe. Spotify quits when you flip one; open it again.");
}
