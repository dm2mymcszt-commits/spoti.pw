// Player redesign: nothing is kept under the player. Every card (about the artist, videos, SongDNA,
// events, explore, credits, merch, the lyrics card, anything Spotify adds later) reports no height, so
// the list closes up around it and the player is one screen; PlayerScroll.x closes off the gaps the
// list leaves between them, and the lyrics come to the player itself (PlayerLyrics.x) instead of
// waiting on a card below it.
//
// A block on everything rather than a list of what to drop: the server decides which cards a track
// gets, and a new kind should not turn up under a redesigned player. The collapse is the one
// Native/Player/PlayerDeclutter.x has shipped.
//
// Tree (trees/clean/player/01.txt:385, lyrics/01.txt:996-999): every card is an Element_List.CollectionViewCell
// whose first subview is an ElementContentView naming NowPlaying_ScrollAPI, then an ElementView, then
// the card's own root: CreatorBiographyCardLayout, song-dna-npv-card, Lyrics_CardElementImpl.CardView
// id=lyrics-card-view and so on (all ten player snapshots). The cells of lists inside a card
// (WatchFeed's) name WatchFeed_ComponentAPI instead, so they are left to their card.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Kit/SGRWorkaround.h"
#import "Redesigned/Kit/SGRSongColour.h"
#import "Shared/AdBlock/AdBlock.h"
#import "Player.h"

// Whether the cell's content is the player's card list, remembered per content class.
static BOOL isPlayerCard(UIView *content) {
    static NSMutableSet<Class> *yes, *no;
    if (!yes) {
        yes = [NSMutableSet set];
        no = [NSMutableSet set];
    }
    Class cls = object_getClass(content);
    if (!cls || [no containsObject:cls]) return NO;
    if ([yes containsObject:cls]) return YES;
    BOOL player = [NSStringFromClass(cls) containsString:@"NowPlaying_ScrollAPI"];
    [(player ? yes : no) addObject:cls];
    return player;
}

%group Collapse
%hook _TtC12Element_List18CollectionViewCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewLayoutAttributes *result = %orig;
    UIView *cell = (UIView *)self;
    UIView *content = cell.subviews.firstObject;
    if (!content || !isPlayerCard(content)) return result;
    result.size = CGSizeMake(result.size.width, 0);
    cell.clipsToBounds = YES;

    static NSMutableSet<NSString *> *logged;
    if (!logged) logged = [NSMutableSet set];
    UIView *root = content.subviews.firstObject.subviews.firstObject;
    NSString *name = root ? NSStringFromClass(root.class) : @"nothing yet";
    if (![logged containsObject:name]) {
        [logged addObject:name];
        SGLog(@"redesign player: collapsed card root %@ (%lu kinds so far)", name, (unsigned long)logged.count);
    }
    return result;
}
%end
%end

// The Workaround (Kit/SGRWorkaround.h): before iOS 26 the cards stay and the player scrolls down to them
// the way Spotify's does (PlayerScroll.x pins nothing then), and only the Lyrics preview card goes: the
// redesign has the lyrics in the player itself (PlayerLyrics.x). It is collapsed the way every card is
// otherwise, one card rather than all of them. Making the cards invisible instead left the Lyrics
// preview's own grey backing on screen (device, 2026-09-19).
//
// Tree (lyrics/01.txt:996-999): the card's root under ElementContentView > ElementView is
// Lyrics_CardElementImpl.CardView id=lyrics-card-view.
static char kLyricsCardKey;

static BOOL isLyricsCard(UIView *cell, UIView *content) {
    UIView *root = content.subviews.firstObject.subviews.firstObject;
    if (root && [NSStringFromClass(root.class) containsString:@"Lyrics_Card"]) return YES;
    return SGRFindByIdentifier(cell, @"lyrics-card-view", &kLyricsCardKey) != nil;
}

// Fork: an ad among the cards kept. The list of cards comes from the server and the ad is one of them
// ("Advertisement", a picture and a button, device 2026-10-05); Shared/AdBlock/Feeds.m takes it out of
// the list on its way in. This is for one that gets through all the same: a card with a view of one of
// Spotify's ad modules in it is collapsed as the Lyrics preview is. Only with Hide ads on.
static BOOL sg_hideAds;

static BOOL fromAds(Class cls) {
    static NSMutableSet<Class> *yes, *no;
    if (!yes) {
        yes = [NSMutableSet set];
        no = [NSMutableSet set];
    }
    if (!cls || [no containsObject:cls]) return NO;
    if ([yes containsObject:cls]) return YES;
    NSString *name = NSStringFromClass(cls);
    BOOL ad = NO;
    for (NSString *module in @[@"AdsPlatform_", @"AdsEmbedded_", @"AdsNowPlaying_", @"AdsStandalone_", @"NativeAds_"]) {
        if ([name containsString:module]) ad = YES;
    }
    [(ad ? yes : no) addObject:cls];
    return ad;
}

// The card's own views only: a list inside a card is another matter, and deeper than this.
static BOOL holdsAd(UIView *view, int depth) {
    if (fromAds(object_getClass(view))) return YES;
    if (depth >= 6) return NO;
    for (UIView *sub in view.subviews) {
        if (holdsAd(sub, depth + 1)) return YES;
    }
    return NO;
}

%group LyricsOnly
%hook _TtC12Element_List18CollectionViewCell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewLayoutAttributes *result = %orig;
    UIView *cell = (UIView *)self;
    UIView *content = cell.subviews.firstObject;
    if (!content || !isPlayerCard(content)) return result;
    if (isLyricsCard(cell, content)) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"redesign player: the Lyrics preview collapsed, the other cards kept (workaround)"); });
    } else if (sg_hideAds && holdsAd(content, 1)) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGLog(@"redesign player: an ad card collapsed"); });
    } else {
        return result;
    }
    result.size = CGSizeMake(result.size.width, 0);
    cell.clipsToBounds = YES;
    return result;
}
%end
%end

// Fork: the cards kept are Spotify's greys, #2A2A2A a card and #282828 or #1F1F1F the parts of one, over
// a field in the cover's colour: grey slabs on a page that is otherwise the song's (device, 2026-10-05).
// A card becomes a film of black the field shows through, and its parts lose their paint, so each is a
// darker shade of whatever the page is.
//
// Tree (dump 2026-10-05 10:58:474-486): Element_List.CollectionViewCell bg=#2A2A2A r=16 clips, a child of
// the list, > ElementContentView > ElementView > the card's root, CreatorBiographyCardLayout bg=#282828
// with a UIView bg=#282828 under its picture; another card's parts are #1F1F1F (:550, :567).
static const CGFloat kCardFilm = 0.25;
static __weak UIView *sg_cardList;

// One of those greys: neutral, opaque, lighter than the base surface and darker than a control.
static BOOL cardGrey(CGColorRef color) {
    if (!color || CFGetTypeID(color) != CGColorGetTypeID() || CGColorGetAlpha(color) < 0.95) return NO;
    size_t count = CGColorGetNumberOfComponents(color);
    const CGFloat *c = CGColorGetComponents(color);
    if (count == 2) return c[0] > 0.10 && c[0] < 0.24;
    if (count != 4) return NO;
    CGFloat top = MAX(c[0], MAX(c[1], c[2])), low = MIN(c[0], MIN(c[1], c[2]));
    return top - low < 0.02 && top > 0.10 && top < 0.24;
}

static CGColorRef cardFilm(void) {
    static UIColor *film;
    if (!film) film = [UIColor colorWithWhite:0 alpha:kCardFilm];
    return film.CGColor;
}

// A card painted before it joined the list, which the repaint below never saw.
static void themeCard(UIView *cell) {
    UIView *list = cell.superview;
    if (!list) return;
    if (sg_cardList != list) sg_cardList = list;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    SGForEachView(cell, ^(UIView *view) {
        if (!cardGrey(view.layer.backgroundColor) || SGRSongColourKeeps(view)) return;
        view.layer.backgroundColor = view == cell ? cardFilm() : NULL;
    });
    [CATransaction commit];
}

%group CardTheme
%hook _TtC12Element_List18CollectionViewCell
- (void)layoutSubviews {
    %orig;
    UIView *cell = (UIView *)self;
    UIView *content = cell.subviews.firstObject;
    if (content && isPlayerCard(content)) themeCard(cell);
}
%end

%hook CALayer
- (void)setBackgroundColor:(CGColorRef)color {
    if (color && cardGrey(color) && NSThread.isMainThread) {
        UIView *list = sg_cardList, *view = (UIView *)self.delegate;
        if (list.window && [view isKindOfClass:UIView.class] && view.layer == self && !SGRSongColourKeeps(view) && SGIsInside(view, list)) {
            color = view.superview == list ? cardFilm() : NULL;
        }
    }
    %orig(color);
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (SGRResizesListCells(@"player")) {
        %init(Collapse);
    } else {
        sg_hideAds = SGHidden(SGKeyHideAds);
        %init(LyricsOnly);
        %init(CardTheme);
    }
    SGRequireClasses(@[@"_TtC12Element_List18CollectionViewCell"]);
}
