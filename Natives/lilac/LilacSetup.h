#import <Foundation/Foundation.h>

/// Sets up and updates the "Lilac" profile: Fabric for Minecraft 1.21.11 in its own game folder, with Fabric API
/// and the newest Lilac Client from the Lilac update feed. Offline it keeps what it has.
@interface LilacSetup : NSObject
+ (void)runWithCompletion:(void (^)(NSError *error))completion;
@end
