#import <CommonCrypto/CommonDigest.h>
#import "LilacSetup.h"
#import "PLProfiles.h"
#import "utils.h"

static NSString *const kProfile = @"Lilac";
static NSString *const kMinecraft = @"1.21.11";
static NSString *const kGameDir = @"./custom_gamedir/lilac";
static NSString *const kFeed = @"https://github.com/yutyy65h45h65h645/lilac-downloads/releases/latest/download/latest.json";

@implementation LilacSetup

+ (NSError *)fail:(NSString *)why {
    return [NSError errorWithDomain:@"Lilac" code:1 userInfo:@{NSLocalizedDescriptionKey: why}];
}

/// Blocking GET; only ever called off the main thread.
+ (NSData *)get:(NSString *)url error:(NSError **)error {
    __block NSData *result = nil;
    __block NSError *failure = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:url]
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (err) failure = err;
        else if (status < 200 || status >= 300) failure = [self fail:[NSString stringWithFormat:@"HTTP %ld for %@", (long)status, url]];
        else result = data;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (error) *error = failure;
    return result;
}

+ (id)json:(NSString *)url error:(NSError **)error {
    NSData *data = [self get:url error:error];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:error] : nil;
}

+ (NSString *)hashOf:(NSString *)path sha256:(BOOL)sha256 {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!file) return @"";
    CC_SHA256_CTX c256;
    CC_SHA1_CTX c1;
    if (sha256) CC_SHA256_Init(&c256); else CC_SHA1_Init(&c1);
    while (YES) {
        @autoreleasepool {
            NSData *chunk = [file readDataOfLength:1 << 16];
            if (chunk.length == 0) break;
            if (sha256) CC_SHA256_Update(&c256, chunk.bytes, (CC_LONG)chunk.length);
            else CC_SHA1_Update(&c1, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [file closeFile];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    int length = sha256 ? CC_SHA256_DIGEST_LENGTH : CC_SHA1_DIGEST_LENGTH;
    if (sha256) CC_SHA256_Final(digest, &c256); else CC_SHA1_Final(digest, &c1);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < length; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

/// Download `name` into `mods` unless it is already there and intact, then remove other jars starting with `prefix`.
+ (NSError *)replaceIn:(NSString *)mods prefix:(NSString *)prefix name:(NSString *)name url:(NSString *)url
                  hash:(NSString *)hash sha256:(BOOL)sha256 {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *target = [mods stringByAppendingPathComponent:name];
    if (![[self hashOf:target sha256:sha256] isEqualToString:hash.lowercaseString]) {
        __block NSError *failure = nil;
        NSString *part = [target stringByAppendingString:@".part"];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [[NSURLSession.sharedSession downloadTaskWithURL:[NSURL URLWithString:url]
            completionHandler:^(NSURL *location, NSURLResponse *response, NSError *err) {
            failure = err;
            if (!err) {
                // the temporary file is deleted when this handler returns, so move it now
                [fm removeItemAtPath:part error:nil];
                NSError *moveError = nil;
                if (![fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:part] error:&moveError]) failure = moveError;
            }
            dispatch_semaphore_signal(done);
        }] resume];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (failure) return failure;
        if (![[self hashOf:part sha256:sha256] isEqualToString:hash.lowercaseString]) {
            [fm removeItemAtPath:part error:nil];
            return [self fail:[NSString stringWithFormat:@"Download of %@ was damaged", name]];
        }
        [fm removeItemAtPath:target error:nil];
        NSError *moveError = nil;
        if (![fm moveItemAtPath:part toPath:target error:&moveError]) return moveError;
    }
    for (NSString *other in [fm contentsOfDirectoryAtPath:mods error:nil]) {
        if ([other hasPrefix:prefix] && [other hasSuffix:@".jar"] && ![other isEqualToString:name]) {
            [fm removeItemAtPath:[mods stringByAppendingPathComponent:other] error:nil];
        }
    }
    return nil;
}

+ (NSError *)run {
    NSError *error = nil;
    NSString *gameRoot = @(getenv("GAME_DIR"));

    // newest stable Fabric Loader for 1.21.11, and its version json
    NSArray *loaders = [self json:[@"https://meta.fabricmc.net/v2/versions/loader/" stringByAppendingString:kMinecraft] error:&error];
    if (!loaders) return error;
    NSString *loader = nil;
    for (NSDictionary *entry in loaders) {
        if ([entry[@"loader"][@"stable"] boolValue]) { loader = entry[@"loader"][@"version"]; break; }
    }
    if (!loader) return [self fail:@"No Fabric Loader for 1.21.11"];
    NSString *versionId = [NSString stringWithFormat:@"fabric-loader-%@-%@", loader, kMinecraft];
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", gameRoot, versionId, versionId];
    if (![NSFileManager.defaultManager fileExistsAtPath:jsonPath]) {
        NSDictionary *version = [self json:[NSString stringWithFormat:@"https://meta.fabricmc.net/v2/versions/loader/%@/%@/profile/json", kMinecraft, loader] error:&error];
        if (!version) return error;
        versionId = version[@"id"];
        jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", gameRoot, versionId, versionId];
        [NSFileManager.defaultManager createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if ((error = saveJSONToFile(version, jsonPath))) return error;
    }

    // the Lilac profile, made and selected the first time (profiles are touched on the main thread only)
    __block BOOL created = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        PLProfiles *profiles = PLProfiles.current;
        NSMutableDictionary *profile = profiles.profiles[kProfile];
        created = profile == nil;
        if (created) {
            profile = [NSMutableDictionary dictionary];
            profile[@"name"] = kProfile;
            profile[@"gameDir"] = kGameDir;
            profiles.profiles[kProfile] = profile;
        }
        profile[@"lastVersionId"] = versionId;
        [profiles save];
        if (created) profiles.selectedProfileName = kProfile;
    });

    NSString *mods = [[gameRoot stringByAppendingPathComponent:kGameDir] stringByAppendingPathComponent:@"mods"].stringByStandardizingPath;
    [NSFileManager.defaultManager createDirectoryAtPath:mods withIntermediateDirectories:YES attributes:nil error:nil];

    // Fabric API from Modrinth
    NSCharacterSet *plain = NSCharacterSet.alphanumericCharacterSet;
    NSString *query = [NSString stringWithFormat:@"game_versions=%@&loaders=%@",
        [[NSString stringWithFormat:@"[\"%@\"]", kMinecraft] stringByAddingPercentEncodingWithAllowedCharacters:plain],
        [@"[\"fabric\"]" stringByAddingPercentEncodingWithAllowedCharacters:plain]];
    NSArray *apiVersions = [self json:[@"https://api.modrinth.com/v2/project/fabric-api/version?" stringByAppendingString:query] error:&error];
    if (!apiVersions) return error;
    if (apiVersions.count == 0) return [self fail:@"No Fabric API for 1.21.11"];
    NSArray *files = apiVersions[0][@"files"];
    NSDictionary *file = files.firstObject;
    for (NSDictionary *f in files) if ([f[@"primary"] boolValue]) file = f;
    if ((error = [self replaceIn:mods prefix:@"fabric-api-" name:file[@"filename"] url:file[@"url"] hash:file[@"hashes"][@"sha1"] sha256:NO])) return error;

    // Lilac Client from the update feed
    NSDictionary *feed = [self json:kFeed error:&error];
    if (!feed) return error;
    if (feed[@"minecraft"] && ![feed[@"minecraft"] isEqualToString:kMinecraft]) return [self fail:@"Lilac feed is for another Minecraft"];
    NSString *url = feed[@"url"];
    return [self replaceIn:mods prefix:@"lilac-" name:url.lastPathComponent url:url hash:feed[@"sha256"] sha256:YES];
}

+ (void)runWithCompletion:(void (^)(NSError *error))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *error = [self run];
        if (error) NSLog(@"[Lilac] Setup could not finish: %@", error);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
    });
}

@end
