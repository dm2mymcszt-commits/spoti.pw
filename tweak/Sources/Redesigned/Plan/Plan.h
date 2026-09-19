// Fork: what the account's plan reads while Spoof Premium is on: the side drawer's badge (PlanBadge.x) and
// the Your plan row of Settings > Account (AccountPlan.x). Both hook only while Redesigned UI and Spoof
// Premium were on at launch.
#import <UIKit/UIKit.h>

// What the plan reads.
extern NSString *const SGRPremiumPlanName;

// Writes the plan's name into the UILabels under `label` (an SPTEncoreLabel), keeping the attributes
// Spotify set on its first character. Only UIKit's own UILabel is written: SPTEncoreLabel's -setText: takes
// something other than an NSString, and handed one it raised an unrecognized selector inside SpotifyShared
// (device crash log, 2026-09-19). Returns YES when anything changed.
BOOL SGRWritePlanName(UIView *label);
