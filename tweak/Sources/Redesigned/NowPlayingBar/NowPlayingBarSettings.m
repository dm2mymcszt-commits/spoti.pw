// The Now playing page of the redesign, under Player (App/Pages.m puts it there): the bar and the
// player behind it.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "NowPlayingBar.h"
#import "Redesigned/Player/Player.h"

UIViewController *SGRNowPlayingBarSettingsPage(void) {
    // Fork: off until asked for, and it says first that it is not finished.
    SGModRow *canvas = SGOptionRow(@"Canvas video", @"Lets a song's looping video play in the player, as Spotify draws it", SGRKeyPlayerCanvas);
    canvas.warning = @"The redesign keeps Canvas out of the player, and nothing of it has been fitted to the redesign yet: the video may cover the background, the corners or the lyrics.";
    return [[SGModPage alloc] initWithTitle:@"Now playing" intro:SGRestartNote sections:@[
        SGSection(nil, @[
            SGHideRow(@"Hide the device button", nil, SGRHideBarConnect),
        ]),
        SGSection(nil, @[
            SGSwitchRow(@"Moving background", nil, SGRKeyPlayerMotion),
            canvas,
        ]),
    ] footer:nil];
}
