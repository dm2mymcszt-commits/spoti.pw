// Fork: Canvas in the redesign (Mod Settings > Player > Canvas). The redesign forces Spotify's Canvas flag
// off, since the video would cover the artwork field (Player/PlayerField.x); with this switch on the flag is
// left to Spotify, so its Canvas videos load again. The Apple Music style cover that turns into the video
// on a tap is built on top of that.
//
//     CanvasSettings.m    the Canvas section of the Player page
#import <Foundation/Foundation.h>

#define SGRKeyCanvas @"spotifyglass.redesign.canvas"

@class SGModSection;
SGModSection *SGRCanvasSection(void);
