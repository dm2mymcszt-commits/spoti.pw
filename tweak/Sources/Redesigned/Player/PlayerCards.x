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

// The Workaround (Kit/SGRWorkaround.h): before iOS 26 a card keeps the height Spotify gives it and is
// only made invisible and untouchable. The list is pinned to its top (PlayerScroll.x), so the cards
// below the player are out of reach anyway; this takes away the one peeking in at the bottom. The
// content view's alpha is used rather than the cell's, which the list sets from its layout attributes,
// and a cell reused for anything else gets it back.
static char kConcealedKey;

static void conceal(UIView *cell) {
    UIView *content = cell.subviews.firstObject;
    BOOL card = content && isPlayerCard(content);
    UIView *concealed = objc_getAssociatedObject(cell, &kConcealedKey);
    if (concealed && concealed != content) {
        concealed.alpha = 1;
        cell.userInteractionEnabled = YES;
        objc_setAssociatedObject(cell, &kConcealedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!card) return;
    if (content.alpha != 0) content.alpha = 0;
    cell.userInteractionEnabled = NO;
    objc_setAssociatedObject(cell, &kConcealedKey, content, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"redesign player: cards concealed, not collapsed (workaround)"); });
}

%group Conceal
%hook _TtC12Element_List18CollectionViewCell
- (void)applyLayoutAttributes:(UICollectionViewLayoutAttributes *)attributes {
    %orig;
    conceal((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    conceal((UIView *)self);
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (SGRResizesListCells(@"player")) {
        %init(Collapse);
    } else {
        %init(Conceal);
    }
    SGRequireClasses(@[@"_TtC12Element_List18CollectionViewCell"]);
}
