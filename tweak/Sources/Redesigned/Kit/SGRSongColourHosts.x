// Fork: where Song colour (SGRSongColour.h) is put. The glow goes behind the screens the tabs open on and
// behind the settings; the album, playlist and artist pages show it through their SGRArtworkField
// (SGRField.m), and their heroes fade into it instead of into a colour of their own. Labels Spotify draws
// white take the song's text colour as they are set, when Tint text is on.
//
// The screens (device dumps, 2026-09-19 and -20):
//   Home      Home_FunkisPageImpl.FunkisViewController's view
//   Search    Browse_BrowsePageImpl.BrowsePageViewController's view
//   Library   YourLibrary_YourLibraryXImpl.YourLibraryView
//   Settings  Settings_PlatformImpl.SettingsListViewController's view, and the Mod Settings pages (SGPage,
//             a table view controller, so the glow is its table's background view)
#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "SGRSongColour.h"

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
    if (bg && SGIsBaseSurface(bg) && !SGKeepsColor(view) && ![view isKindOfClass:SGRSongGlowView.class] && SGRSongColourClears(view)) {
        view.layer.backgroundColor = NULL;
    }
    SGRSongColourCatchUp(view);
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

%group Text
%hook UILabel
- (void)setTextColor:(UIColor *)color {
    %orig(tinted(color));
}

- (void)setAttributedText:(NSAttributedString *)text {
    if (!text.length) {
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
%end

%ctor {
    if (!SGRedesignedUI() || !SGRSongColour()) return;
    %init;
    if (SGRSongColourText()) %init(Text);
    SGRSongColourStart();
    SGRequireClasses(@[
        @"_TtC19Home_FunkisPageImpl20FunkisViewController",
        @"_TtC21Browse_BrowsePageImpl24BrowsePageViewController",
        @"_TtC28YourLibrary_YourLibraryXImpl15YourLibraryView",
        @"_TtC21Settings_PlatformImpl26SettingsListViewController",
    ]);
}
