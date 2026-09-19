#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Canvas.h"

SGModSection *SGRCanvasSection(void) {
    return SGNotedSection(@"Canvas", @[
        SGWithSymbol(SGOptionRow(@"Canvas videos", @"Let Spotify load its Canvas videos again", SGRKeyCanvas), @"play.rectangle.on.rectangle"),
    ], @"Experimental: the videos show the way Spotify draws them for now.");
}
