// Screen dumps for FLEX builds: the visible screen's view tree, served over the phone's loopback
// and logged when the app goes to the background.
#import <Foundation/Foundation.h>

BOOL SGIsDebugBuild(void);
NSString *SGScreenTree(void);
void SGDumpScreen(NSString *reason);
// Debug builds: after `delay`, the screen then showing and the log go to the share sheet, as a shake does.
void SGShareDumpAfter(NSTimeInterval delay);
