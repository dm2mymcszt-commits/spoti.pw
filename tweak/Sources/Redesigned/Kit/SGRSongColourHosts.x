// Fork: where Song colour (SGRSongColour.h) is put. The glow goes behind the screens the tabs open on and
// behind the settings; the album, playlist and artist pages show it through their SGRArtworkField
// (SGRField.m), and their heroes fade into it instead of into a colour of their own. Labels Spotify draws
// white take the song's text colour as they are set, when Tint text is on.
//
// The screens (device dumps, 2026-09-19 and -20):
//   Home      Home_FunkisPageImpl.FunkisViewController's view
//   Search    Browse_BrowsePageImpl.BrowsePageViewController's view; and, once the field is tapped,
//             Search_FeatureImpl.SearchUIContainerViewControllerImpl's (id=SearchUIContainerViewController.view,
//             dumps 2026-10-05): the recent searches and the results in one list the size of the screen, under
//             Search_FeatureImpl.HeaderViewController's view, a 95pt bar of #1F1F1F holding the field
//   Library   YourLibrary_YourLibraryXImpl.YourLibraryView
//   Settings  Settings_PlatformImpl.SettingsListViewController's view, and the Mod Settings pages (SGPage,
//             a table view controller, so the glow is its table's background view)
#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "SGRSongColour.h"
#import "SGRRestyle.h"

#pragma mark - the screens

%hook _TtC19Home_FunkisPageImpl20FunkisViewController
- (void)viewDidLayoutSubviews {
    %orig;
    SGRSongColourAdopt(((UIViewController *)self).viewIfLoaded);
}
%end

%hook _TtC21Browse_BrowsePageImpl24BrowsePageViewController
- (void)viewDidLayoutSubviews {
    %orig;
    SGRSongColourAdopt(((UIViewController *)self).viewIfLoaded);
}
%end

// The list runs under the header, so the header takes a patch of the glow: its own grey is covered, and the
// rows going under it are too.
%hook _TtC18Search_FeatureImpl35SearchUIContainerViewControllerImpl
- (void)viewDidLayoutSubviews {
    %orig;
    SGRSongColourAdopt(((UIViewController *)self).viewIfLoaded);
}
%end

%hook _TtC18Search_FeatureImpl20HeaderViewController
- (void)viewDidLayoutSubviews {
    %orig;
    SGRSongColourPatchIn(((UIViewController *)self).viewIfLoaded, NO);
}
%end

%hook _TtC28YourLibrary_YourLibraryXImpl15YourLibraryView
- (void)layoutSubviews {
    %orig;
    SGRSongColourAdopt((UIView *)self);
}
%end

%hook _TtC21Settings_PlatformImpl26SettingsListViewController
- (void)viewDidLayoutSubviews {
    %orig;
    SGRSongColourAdopt(((UIViewController *)self).viewIfLoaded);
}
%end

%hook SGPage
- (void)viewDidLayoutSubviews {
    %orig;
    SGRSongColourAdopt(((UITableViewController *)self).tableView);
}
%end

// Sheets: the queue, Add to playlist and whatever else Spotify brings up from the bottom were plain grey
// over a player in the song's colours (device, 2026-10-05). Every one is hosted by
// NavigationUI_SheetImpl.ContainerViewController, and what it shows sits in a view with id=sheet-view,
// #1F1F1F, clipped to the sheet's corners (dumps 2026-10-05 10:58:668-676 and 10:59:672-676).
static char kSheetViewKey;

static UIView *sheetViewOf(UIView *root) {
    for (UIView *v = root; v && ![v isKindOfClass:UIWindow.class]; v = v.superview) {
        if ([v.accessibilityIdentifier isEqualToString:@"sheet-view"]) return v;
    }
    return SGRFindByIdentifier(root, @"sheet-view", &kSheetViewKey);
}

%hook _TtC22NavigationUI_SheetImpl23ContainerViewController
- (void)viewDidLayoutSubviews {
    %orig;
    SGRSongColourAdoptSheet(sheetViewOf(((UIViewController *)self).viewIfLoaded));
}
%end

#pragma mark - views joining a screen

// Spotify paints a cell its base surface before the cell is in the list, so the repaint hook, which asks
// where a view is, let it through, and Home came out black under its header (device, 2026-09-21). A view
// arriving in a window inside a glowing screen is cleared as it arrives. And whatever it still wears of an
// earlier song, having been out of a window while the song changed, takes the playing one's colours.
%hook UIView
- (void)didMoveToWindow {
    %orig;
    UIView *view = (UIView *)self;
    if (!view.window) return;
    CGColorRef bg = view.layer.backgroundColor;
    if (bg && !SGRSongColourKeeps(view) && ![view isKindOfClass:SGRSongGlowView.class]
        && ((SGIsBaseSurface(bg) && SGRSongColourClears(view)) || SGRSongColourClearsSheet(view, bg))) {
        view.layer.backgroundColor = NULL;
    }
    SGRSongColourCatchUp(view);
}
%end

// The lists themselves: Home's (Home_CarouselKit.TouchCancellingCollectionView) and the Library's
// (YourLibrary_CommonKit.YourLibraryCollectionView) came out opaque black over the glow, Home's from launch and
// the Library's once it had rebuilt its list (device dumps, 2026-09-21). A list is painted before it has a size,
// when the paint rules keep what a view of 4pt or less wears, and joins before its screen is adopted, so
// neither the repaint nor the arrival took it off. It is taken off as the list lays out, which it does as it
// scrolls: a look at its colour, and only one of the base surface asks where it is.
%hook UIScrollView
- (void)layoutSubviews {
    %orig;
    UIScrollView *list = (UIScrollView *)self;
    CGColorRef bg = list.layer.backgroundColor;
    if (bg && SGIsBaseSurface(bg) && SGRSongColourClears(list)) list.layer.backgroundColor = NULL;
}
%end

#pragma mark - glyphs

// Shuffle, repeat and the checkmarks are drawn into images in the accent of the moment and set again as their
// state changes (SGRSongColourGlyph): each is painted in the playing song's colour on its way in.
%hook UIImageView
- (void)setImage:(UIImage *)image {
    UIImage *glyph = SGRSongColourGlyph(image);
    %orig(glyph ?: image);
}
%end

#pragma mark - the heroes

// A hero fades into its page's colour by drawing that colour over its bottom. Over the glow the page has no
// colour of its own to fade into, so the hero is faded out instead: its dissolve is given no colour, and a
// mask takes the picture to nothing over the same part of it (kDissolve, 0.46 of its height).
static char kHeroMaskKey;

static void maskHero(UIView *hero) {
    CAGradientLayer *mask = objc_getAssociatedObject(hero, &kHeroMaskKey);
    if (!mask) {
        mask = [CAGradientLayer layer];
        mask.colors = @[(id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)[UIColor colorWithWhite:0 alpha:0].CGColor];
        mask.locations = @[@0, @0.54, @1];
        objc_setAssociatedObject(hero, &kHeroMaskKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (hero.layer.mask != mask) hero.layer.mask = mask;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = hero.bounds;
    [CATransaction commit];
}

%hook SGRPlaylistHero
- (void)setFieldColor:(UIColor *)color {
    %orig(UIColor.clearColor);
}
- (void)layoutSubviews {
    %orig;
    maskHero((UIView *)self);
}
%end

%hook SGRAlbumHero
- (void)setFieldColor:(UIColor *)color {
    %orig(UIColor.clearColor);
}
- (void)layoutSubviews {
    %orig;
    maskHero((UIView *)self);
}
%end

%hook SGRArtistHero
- (void)setFieldColor:(UIColor *)color {
    %orig(UIColor.clearColor);
}
- (void)layoutSubviews {
    %orig;
    maskHero((UIView *)self);
}
%end

#pragma mark - the text

// White takes the live text colour, which follows the song on its own from then on (SGRSongColour.h).
static UIColor *tinted(UIColor *color) {
    CGFloat r, g, b, a;
    if (![color isKindOfClass:UIColor.class] || ![color getRed:&r green:&g blue:&b alpha:&a]) return color;
    if (r < 0.93 || g < 0.93 || b < 0.93 || a < 0.9) return color;
    return SGRSongLiveText(a) ?: color;
}

static char kBiographyLabelKey;

static void keepLabelsWhite(UIView *root) {
    if (!root) return;
    SGForEachView(root, ^(UIView *view) {
        if ([view isKindOfClass:UILabel.class] && !SGRSongColourKeepsWhite((UILabel *)view)) SGRSongColourKeepWhite((UILabel *)view);
    });
}

%group Text
%hook UILabel
- (void)setTextColor:(UIColor *)color {
    UILabel *label = (UILabel *)self;
    %orig(SGRSongColourKeepsWhite(label) ? color : tinted(color));
}

- (void)setAttributedText:(NSAttributedString *)text {
    if (!text.length || SGRSongColourKeepsWhite((UILabel *)self)) {
        %orig;
        return;
    }
    __block NSMutableAttributedString *copy = nil;
    [text enumerateAttribute:NSForegroundColorAttributeName inRange:NSMakeRange(0, text.length) options:0
                  usingBlock:^(id value, NSRange range, BOOL *stop) {
        UIColor *swapped = tinted(value);
        if (swapped == value) return;
        if (!copy) copy = [text mutableCopy];
        [copy addAttribute:NSForegroundColorAttributeName value:swapped range:range];
    }];
    %orig(copy ?: text);
}
%end

// Text over a picture stays white, as the titles on Search's coloured cards do (Search/SearchCards.x): the
// song's shade over a photograph is a colour on colours, and was hard to read (device, 2026-10-05). The cards
// that draw their words over a picture:
//   WatchFeed_ECMKit.WatchFeedVideoCardView (id=WatchFeedVideoCardView), the picture cards of the player's
//     Explore card: "Songs by", "Similar to" (dump 100227:443-470). Search's Discover row looks like the
//     same card and has not been dumped
//   Creator_ECMKit's CreatorBiographyCardLayout, About the artist, whose header label
//     (id=Components.UI.CreatorBiographyCard.HeaderLabel) lies over the artist's photograph (:363-371)
%hook _TtC16WatchFeed_ECMKit22WatchFeedVideoCardView
- (void)layoutSubviews {
    %orig;
    keepLabelsWhite((UIView *)self);
}
%end

%hook _TtC14Creator_ECMKitP33_9A9A9C9886A2DEDE51521D11F82E7F9026CreatorBiographyCardLayout
- (void)layoutSubviews {
    %orig;
    UIView *card = (UIView *)self;
    keepLabelsWhite(SGRFindByIdentifier(card, @"Components.UI.CreatorBiographyCard.HeaderLabel", &kBiographyLabelKey));
}
%end
%end

%ctor {
    if (!SGRedesignedUI() || !SGRSongColour()) return;
    %init;
    if (SGRSongColourText()) {
        %init(Text);
        SGRequireClasses(@[
            @"_TtC16WatchFeed_ECMKit22WatchFeedVideoCardView",
            @"_TtC14Creator_ECMKitP33_9A9A9C9886A2DEDE51521D11F82E7F9026CreatorBiographyCardLayout",
        ]);
    }
    SGRSongColourStart();
    SGRequireClasses(@[
        @"_TtC19Home_FunkisPageImpl20FunkisViewController",
        @"_TtC21Browse_BrowsePageImpl24BrowsePageViewController",
        @"_TtC28YourLibrary_YourLibraryXImpl15YourLibraryView",
        @"_TtC18Search_FeatureImpl35SearchUIContainerViewControllerImpl",
        @"_TtC18Search_FeatureImpl20HeaderViewController",
        @"_TtC21Settings_PlatformImpl26SettingsListViewController",
        @"_TtC22NavigationUI_SheetImpl23ContainerViewController",
    ]);
}
