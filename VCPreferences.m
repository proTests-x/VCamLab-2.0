#import "VCPreferences.h"
#import "VCPreferenceValidation.h"
#import <float.h>
#import <notify.h>
#import <math.h>
#import <stdint.h>

NSString * const VCPreferencesDomain = @"com.murkaska.virtualcampro";
NSString * const VCPreferencesChangedNotification = @"com.murkaska.virtualcampro/preferences.changed";
NSString * const VCEnabledKey = @"enabled";
NSString * const VCStreamURLKey = @"streamURL";
NSString * const VCPreferredFPSKey = @"preferredFPS";
NSString * const VCSourceRotationKey = @"sourceRotation";
NSString * const VCMirrorSourceKey = @"mirrorSource";
NSString * const VCMaximumPixelDimensionKey = @"maximumPixelDimension";
NSString * const VCJPEGQualityKey = @"jpegQuality";
NSString * const VCAspectFillKey = @"aspectFill";
NSString * const VCSourceTypeKey = @"sourceType";
NSString * const VCLocalMediaPathKey = @"localMediaPath";
NSString * const VCLoopLocalMediaKey = @"loopLocalMedia";
NSString * const VCHoldLastFrameKey = @"holdLastFrame";
NSString * const VCStaleFrameTimeoutKey = @"staleFrameTimeout";
NSString * const VCSourceRestartTokenKey = @"sourceRestartToken";
NSString * const VCFloatingControlEnabledKey = @"floatingControlEnabled";
NSString * const VCFloatingControlCenterXKey = @"floatingControlCenterX";
NSString * const VCFloatingControlCenterYKey = @"floatingControlCenterY";
NSString * const VCTargetBundleIdentifiersKey = @"targetBundleIdentifiers";
const char * const VCTargetCaptureStateNotification =
    "com.murkaska.virtualcampro/target-capture.state.v1";

static NSString * const VCLegacyPreferencesPath = @"/var/mobile/Library/Preferences/com.apple.avfoundation.cs.plist";
static NSString * const VCPreferencesPath = @"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist";
static NSString * const VCRuntimeConfigurationNotification =
    @"com.murkaska.virtualcampro/runtime.configuration.v1";
static const uint16_t VCRuntimeConfigurationMagic = 0x5643;
static const NSUInteger VCRuntimeMaximumURLBytes = 512;

@interface VCRuntimeConfigurationSnapshot : NSObject
@property(nonatomic, assign) BOOL enabled;
@property(nonatomic, assign) BOOL hasTargetFilter;
@property(nonatomic, assign) BOOL currentProcessSelected;
@property(nonatomic, assign) VCSourceType sourceType;
@property(nonatomic, copy, nullable) NSString *streamURLString;
@end

@implementation VCRuntimeConfigurationSnapshot
@end

static uint64_t VCFNV1a64(NSData *data) {
    const uint8_t *bytes = data.bytes;
    uint64_t hash = UINT64_C(14695981039346656037);
    for (NSUInteger index = 0; index < data.length; index++) {
        hash ^= bytes[index];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static NSString *VCTargetRuntimeNotification(NSString *bundleIdentifier) {
    NSData *data = [bundleIdentifier dataUsingEncoding:NSUTF8StringEncoding] ?: NSData.data;
    return [NSString stringWithFormat:
        @"com.murkaska.virtualcampro/runtime.target.%016llx.v1",
        (unsigned long long)VCFNV1a64(data)];
}

static NSString *VCURLChunkRuntimeNotification(NSUInteger index) {
    return [NSString stringWithFormat:
        @"com.murkaska.virtualcampro/runtime.url.%03lu.v1",
        (unsigned long)index];
}

static int VCRuntimeNotifyToken(NSString *name) {
    static NSMutableDictionary<NSString *, NSNumber *> *tokens;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ tokens = [NSMutableDictionary dictionary]; });
    @synchronized (tokens) {
        NSNumber *stored = tokens[name];
        if (stored) return stored.intValue;
        int token = -1;
        if (notify_register_check(name.UTF8String, &token) != NOTIFY_STATUS_OK) {
            return -1;
        }
        // Keep registrations alive for the process lifetime.  notifyd may
        // discard state when its last owner cancels a token.
        tokens[name] = @(token);
        return token;
    }
}

static BOOL VCReadRuntimeState(NSString *name, uint64_t *stateOut) {
    int token = VCRuntimeNotifyToken(name);
    return token >= 0 && stateOut &&
        notify_get_state(token, stateOut) == NOTIFY_STATUS_OK;
}

static BOOL VCWriteRuntimeState(NSString *name, uint64_t state) {
    int token = VCRuntimeNotifyToken(name);
    return token >= 0 && notify_set_state(token, state) == NOTIFY_STATUS_OK;
}

static uint16_t VCNextRuntimeConfigurationGeneration(void) {
    static uint16_t previous;
    @synchronized (VCPreferences.class) {
        uint64_t milliseconds = (uint64_t)llround(
            MAX(0.0, NSProcessInfo.processInfo.systemUptime) * 1000.0);
        uint16_t candidate = (uint16_t)(milliseconds & UINT16_MAX);
        if (candidate == 0 || candidate == previous) candidate = previous + 1;
        if (candidate == 0) candidate = 1;
        previous = candidate;
        return candidate;
    }
}

static VCRuntimeConfigurationSnapshot *VCReadRuntimeConfiguration(
    NSString *bundleIdentifier) {
    uint64_t metadataBefore = 0;
    if (!VCReadRuntimeState(VCRuntimeConfigurationNotification,
                            &metadataBefore)) return nil;
    uint16_t magic = (uint16_t)(metadataBefore >> 48);
    if (magic != VCRuntimeConfigurationMagic) return nil;
    uint16_t generation = (uint16_t)((metadataBefore >> 32) & UINT16_MAX);
    uint8_t flags = (uint8_t)((metadataBefore >> 24) & UINT8_MAX);
    NSUInteger length = (NSUInteger)((metadataBefore >> 12) & 0xFFF);
    uint16_t expectedChecksum = (uint16_t)(metadataBefore & 0xFFF);
    if (length > VCRuntimeMaximumURLBytes) return nil;

    NSMutableData *urlData = [NSMutableData dataWithLength:length];
    uint8_t *destination = urlData.mutableBytes;
    NSUInteger chunkCount = (length + 7) / 8;
    for (NSUInteger chunk = 0; chunk < chunkCount; chunk++) {
        uint64_t packed = 0;
        if (!VCReadRuntimeState(VCURLChunkRuntimeNotification(chunk), &packed)) {
            return nil;
        }
        NSUInteger chunkLength = MIN((NSUInteger)8, length - chunk * 8);
        for (NSUInteger byte = 0; byte < chunkLength; byte++) {
            destination[chunk * 8 + byte] = (uint8_t)(packed >> (byte * 8));
        }
    }
    uint64_t metadataAfter = 0;
    if (!VCReadRuntimeState(VCRuntimeConfigurationNotification,
                            &metadataAfter) || metadataAfter != metadataBefore) {
        return nil;
    }
    if (((uint16_t)VCFNV1a64(urlData) & 0xFFF) != expectedChecksum) {
        return nil;
    }

    NSString *urlString = length > 0
        ? [[NSString alloc] initWithData:urlData encoding:NSUTF8StringEncoding]
        : nil;
    if (length > 0 && !urlString) return nil;

    BOOL hasTargetFilter = (flags & (1U << 1)) != 0;
    BOOL selected = !hasTargetFilter;
    if (hasTargetFilter && bundleIdentifier.length > 0) {
        uint64_t targetState = 0;
        if (VCReadRuntimeState(VCTargetRuntimeNotification(bundleIdentifier),
                               &targetState) &&
            (uint16_t)(targetState >> 48) == VCRuntimeConfigurationMagic &&
            (uint16_t)((targetState >> 32) & UINT16_MAX) == generation) {
            selected = (targetState & 1) != 0;
        }
    }
    VCRuntimeConfigurationSnapshot *configuration =
        [VCRuntimeConfigurationSnapshot new];
    configuration.enabled = (flags & 1U) != 0;
    configuration.hasTargetFilter = hasTargetFilter;
    configuration.currentProcessSelected = selected;
    configuration.sourceType = (VCSourceType)((flags >> 2) & 0x3);
    configuration.streamURLString = urlString;
    return configuration;
}

@interface VCPreferences ()
@property (atomic, assign, readwrite, getter=isEnabled) BOOL enabled;
@property (atomic, copy, readwrite, nullable) NSURL *streamURL;
@property (atomic, assign, readwrite) NSInteger preferredFPS;
@property (atomic, assign, readwrite) NSInteger sourceRotation;
@property (atomic, assign, readwrite) BOOL mirrorSource;
@property (atomic, assign, readwrite) NSInteger maximumPixelDimension;
@property (atomic, assign, readwrite) CGFloat jpegQuality;
@property (atomic, assign, readwrite) BOOL aspectFill;
@property (atomic, assign, readwrite) VCSourceType sourceType;
@property (atomic, copy, readwrite, nullable) NSURL *localMediaURL;
@property (atomic, assign, readwrite) BOOL loopLocalMedia;
@property (atomic, assign, readwrite) BOOL holdLastFrame;
@property (atomic, assign, readwrite) NSTimeInterval staleFrameTimeout;
@property (atomic, copy, readwrite) NSString *sourceRestartToken;
@property (atomic, copy, readwrite) NSSet<NSString *> *targetBundleIdentifiers;
@property (atomic, assign) BOOL publishedConfigurationAvailable;
@property (atomic, assign) BOOL publishedHasTargetBundleFilter;
@property (atomic, assign) BOOL publishedCurrentProcessSelected;
@end

@implementation VCPreferences

+ (instancetype)sharedPreferences {
    static VCPreferences *preferences;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        preferences = [[self alloc] init];
        [preferences reload];
    });
    return preferences;
}

static id VCReadPreference(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)VCPreferencesDomain);
    return CFBridgingRelease(value);
}

static BOOL VCReadFinitePreferenceNumber(id value, double *numberOut) {
    if (![value isKindOfClass:NSNumber.class] &&
        ![value isKindOfClass:NSString.class]) {
        return NO;
    }
    if ([value isKindOfClass:NSString.class] && [value length] > 64) return NO;
    double number = [value doubleValue];
    if (!isfinite(number)) return NO;
    if (numberOut) *numberOut = number;
    return YES;
}

static BOOL VCReadBooleanPreference(id value, BOOL defaultValue) {
    if (![value isKindOfClass:NSNumber.class] &&
        ![value isKindOfClass:NSString.class]) {
        return defaultValue;
    }
    if ([value isKindOfClass:NSString.class] && [value length] > 16) {
        return defaultValue;
    }
    return [value boolValue];
}

static NSSet<NSString *> *VCReadTargetBundleIdentifiers(id value) {
    if (![value isKindOfClass:NSArray.class] &&
        ![value isKindOfClass:NSSet.class]) {
        return [NSSet set];
    }
    NSMutableSet<NSString *> *result = [NSMutableSet set];
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (id candidate in value) {
        if (![candidate isKindOfClass:NSString.class]) continue;
        NSString *identifier = [candidate stringByTrimmingCharactersInSet:whitespace];
        if (identifier.length == 0 || identifier.length > 255) continue;
        if ([identifier rangeOfCharacterFromSet:whitespace].location != NSNotFound) continue;
        [result addObject:identifier];
        if (result.count >= 128) break;
    }
    return [result copy];
}

static int VCTargetCaptureNotifyToken(void) {
    static int token = -1;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        int candidate = -1;
        if (notify_register_check(VCTargetCaptureStateNotification, &candidate) == NOTIFY_STATUS_OK) {
            token = candidate;
        }
    });
    return token;
}

static uint64_t VCTargetCaptureTimestampMilliseconds(void) {
    NSTimeInterval uptime = NSProcessInfo.processInfo.systemUptime;
    if (!isfinite(uptime) || uptime <= 0) return 1;
    long double milliseconds = (long double)uptime * 1000.0L;
    if (milliseconds >= (long double)INT64_MAX) return INT64_MAX;
    return (uint64_t)milliseconds;
}

void VCSetTargetCaptureActive(BOOL active) {
    int token = VCTargetCaptureNotifyToken();
    if (token < 0) return;
    static const uint64_t activeMask = UINT64_C(1) << 63;
    uint64_t state = VCTargetCaptureTimestampMilliseconds();
    if (active) state |= activeMask;
    if (notify_set_state(token, state) == NOTIFY_STATUS_OK) {
        notify_post(VCTargetCaptureStateNotification);
    }
}

BOOL VCTargetCaptureIsActive(NSTimeInterval maximumAge) {
    int token = VCTargetCaptureNotifyToken();
    if (token < 0 || !isfinite(maximumAge) || maximumAge <= 0) return NO;
    uint64_t state = 0;
    if (notify_get_state(token, &state) != NOTIFY_STATUS_OK) return NO;
    static const uint64_t activeMask = UINT64_C(1) << 63;
    if ((state & activeMask) == 0) return NO;
    uint64_t timestamp = state & ~activeMask;
    uint64_t now = VCTargetCaptureTimestampMilliseconds();
    if (timestamp == 0 || now < timestamp) return NO;
    return now - timestamp <= (uint64_t)llround(maximumAge * 1000.0);
}

- (BOOL)reload {
    CFPreferencesAppSynchronize((__bridge CFStringRef)VCPreferencesDomain);

    // Injected applications can resolve an arbitrary CFPreferences domain
    // inside their own container instead of the mobile user's global domain.
    // SpringBoard writes the canonical file, so use it as a read-only fallback
    // whenever the process-local preferences search list has no value.
    NSDictionary *directPreferences =
        [NSDictionary dictionaryWithContentsOfFile:VCPreferencesPath];

    id enabledValue = VCReadPreference(VCEnabledKey);
    id streamValue = VCReadPreference(VCStreamURLKey);
    id fpsValue = VCReadPreference(VCPreferredFPSKey);
    id sourceRotationValue = VCReadPreference(VCSourceRotationKey);
    id mirrorSourceValue = VCReadPreference(VCMirrorSourceKey);
    id maximumPixelDimensionValue = VCReadPreference(VCMaximumPixelDimensionKey);
    id qualityValue = VCReadPreference(VCJPEGQualityKey);
    id aspectFillValue = VCReadPreference(VCAspectFillKey);
    id sourceTypeValue = VCReadPreference(VCSourceTypeKey);
    id localMediaPathValue = VCReadPreference(VCLocalMediaPathKey);
    id loopLocalMediaValue = VCReadPreference(VCLoopLocalMediaKey);
    id holdLastFrameValue = VCReadPreference(VCHoldLastFrameKey);
    id staleFrameTimeoutValue = VCReadPreference(VCStaleFrameTimeoutKey);
    id sourceRestartTokenValue = VCReadPreference(VCSourceRestartTokenKey);
    id targetBundleIdentifiersValue = VCReadPreference(VCTargetBundleIdentifiersKey);
    VCRuntimeConfigurationSnapshot *runtimeConfiguration =
        VCReadRuntimeConfiguration(NSBundle.mainBundle.bundleIdentifier);

    enabledValue = enabledValue ?: directPreferences[VCEnabledKey];
    streamValue = streamValue ?: directPreferences[VCStreamURLKey];
    fpsValue = fpsValue ?: directPreferences[VCPreferredFPSKey];
    sourceRotationValue = sourceRotationValue ?: directPreferences[VCSourceRotationKey];
    mirrorSourceValue = mirrorSourceValue ?: directPreferences[VCMirrorSourceKey];
    maximumPixelDimensionValue = maximumPixelDimensionValue ?:
        directPreferences[VCMaximumPixelDimensionKey];
    qualityValue = qualityValue ?: directPreferences[VCJPEGQualityKey];
    aspectFillValue = aspectFillValue ?: directPreferences[VCAspectFillKey];
    sourceTypeValue = sourceTypeValue ?: directPreferences[VCSourceTypeKey];
    localMediaPathValue = localMediaPathValue ?: directPreferences[VCLocalMediaPathKey];
    loopLocalMediaValue = loopLocalMediaValue ?: directPreferences[VCLoopLocalMediaKey];
    holdLastFrameValue = holdLastFrameValue ?: directPreferences[VCHoldLastFrameKey];
    staleFrameTimeoutValue = staleFrameTimeoutValue ?:
        directPreferences[VCStaleFrameTimeoutKey];
    sourceRestartTokenValue = sourceRestartTokenValue ?:
        directPreferences[VCSourceRestartTokenKey];
    targetBundleIdentifiersValue = targetBundleIdentifiersValue ?:
        directPreferences[VCTargetBundleIdentifiersKey];

    // Only sandboxed clients need the bridge. Privileged producers must keep
    // the canonical plist authoritative and must never revive a stale notify
    // snapshot while publishing the next generation.
    BOOL useRuntimeConfiguration = runtimeConfiguration && !directPreferences;
    if (useRuntimeConfiguration) {
        enabledValue = enabledValue ?: @(runtimeConfiguration.enabled);
        sourceTypeValue = sourceTypeValue ?: @(runtimeConfiguration.sourceType);
        streamValue = streamValue ?: runtimeConfiguration.streamURLString;
    }

    // Read the original project's preference file as a migration fallback.
    if (!enabledValue || !streamValue) {
        NSDictionary *legacy = [NSDictionary dictionaryWithContentsOfFile:VCLegacyPreferencesPath];
        enabledValue = enabledValue ?: legacy[VCEnabledKey];
        streamValue = streamValue ?: legacy[VCStreamURLKey];
    }

    BOOL enabled = VCReadBooleanPreference(enabledValue, NO);
    double number = 0;
    int64_t integer = 0;
    NSInteger preferredFPS =
        VCReadFinitePreferenceNumber(fpsValue, &number) &&
        VCPreferenceValidateInteger(number, 1, 240, &integer)
            ? (NSInteger)integer : 60;

    NSInteger sourceRotation =
        VCReadFinitePreferenceNumber(sourceRotationValue, &number) &&
        VCPreferenceValidateInteger(number, 0, 270, &integer)
            ? (NSInteger)integer : 0;
    if (sourceRotation != 90 && sourceRotation != 180 && sourceRotation != 270) {
        sourceRotation = 0;
    }
    BOOL mirrorSource = VCReadBooleanPreference(mirrorSourceValue, NO);

    NSInteger maximumPixelDimension =
        VCReadFinitePreferenceNumber(maximumPixelDimensionValue, &number) &&
        VCPreferenceValidateInteger(number, 1280, 3840, &integer)
            ? (NSInteger)integer : 1920;
    if (maximumPixelDimension != 1280 && maximumPixelDimension != 1920 &&
        maximumPixelDimension != 2560 && maximumPixelDimension != 3840) {
        maximumPixelDimension = 1920;
    }

    double real = 0;
    CGFloat jpegQuality =
        VCReadFinitePreferenceNumber(qualityValue, &number) &&
        VCPreferenceValidateReal(number, 0.50, 1.0, &real)
            ? (CGFloat)real : 1.0;

    BOOL aspectFill = VCReadBooleanPreference(aspectFillValue, YES);
    NSInteger sourceTypeValueInteger =
        VCReadFinitePreferenceNumber(sourceTypeValue, &number) &&
        VCPreferenceValidateInteger(number,
                                    VCSourceTypeNetwork,
                                    VCSourceTypeLocalMedia,
                                    &integer)
            ? (NSInteger)integer : VCSourceTypeNetwork;
    VCSourceType sourceType = (sourceTypeValueInteger >= VCSourceTypeNetwork &&
                               sourceTypeValueInteger <= VCSourceTypeLocalMedia)
        ? (VCSourceType)sourceTypeValueInteger : VCSourceTypeNetwork;
    BOOL loopLocalMedia = VCReadBooleanPreference(loopLocalMediaValue, YES);
    BOOL holdLastFrame = VCReadBooleanPreference(holdLastFrameValue, YES);
    NSTimeInterval staleFrameTimeout =
        VCReadFinitePreferenceNumber(staleFrameTimeoutValue, &number) &&
        VCPreferenceValidateReal(number, 2.0, 30.0, &real)
            ? real : 8.0;
    NSString *sourceRestartToken = @"";
    if ([sourceRestartTokenValue isKindOfClass:NSString.class] &&
        [sourceRestartTokenValue length] <= 128) {
        sourceRestartToken = sourceRestartTokenValue;
    }
    NSSet<NSString *> *targetBundleIdentifiers =
        VCReadTargetBundleIdentifiers(targetBundleIdentifiersValue);

    NSURL *streamURL = nil;
    if ([streamValue isKindOfClass:[NSString class]] &&
        [streamValue length] > 0 && [streamValue length] <= 4096) {
        NSURL *candidate = [NSURL URLWithString:[streamValue stringByTrimmingCharactersInSet:
                                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        NSString *scheme = candidate.scheme.lowercaseString;
        if (([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) &&
            candidate.host.length > 0 && candidate.user.length == 0 &&
            candidate.password.length == 0 && candidate.fragment.length == 0) {
            streamURL = candidate;
        }
    }

    NSURL *localMediaURL = nil;
    if ([localMediaPathValue isKindOfClass:[NSString class]] &&
        [localMediaPathValue length] <= 4096) {
        NSString *path = [localMediaPathValue
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *standardized = path.stringByStandardizingPath;
        BOOL approvedRoot = [standardized hasPrefix:@"/var/mobile/Media/"] ||
                            [standardized hasPrefix:@"/var/mobile/Library/VirtualCamPro/"];
        if (path.length > 0 && path.isAbsolutePath &&
            approvedRoot && ![path.pathComponents containsObject:@".."] &&
            ![standardized hasSuffix:@"/"]) {
            localMediaURL = [NSURL fileURLWithPath:standardized isDirectory:NO];
        }
    }

    @synchronized (self) {
        BOOL changed = self.enabled != enabled ||
                       self.preferredFPS != preferredFPS ||
                       self.sourceRotation != sourceRotation ||
                       self.mirrorSource != mirrorSource ||
                       self.maximumPixelDimension != maximumPixelDimension ||
                       fabs(self.jpegQuality - jpegQuality) > DBL_EPSILON ||
                       self.aspectFill != aspectFill ||
                       self.sourceType != sourceType ||
                       self.loopLocalMedia != loopLocalMedia ||
                       self.holdLastFrame != holdLastFrame ||
                       fabs(self.staleFrameTimeout - staleFrameTimeout) > DBL_EPSILON ||
                       ![self.sourceRestartToken isEqualToString:sourceRestartToken] ||
                       ![self.targetBundleIdentifiers isEqualToSet:targetBundleIdentifiers] ||
                       !((self.streamURL == streamURL) || [self.streamURL isEqual:streamURL]) ||
                       !((self.localMediaURL == localMediaURL) ||
                         [self.localMediaURL isEqual:localMediaURL]);

        self.enabled = enabled;
        self.streamURL = streamURL;
        self.preferredFPS = preferredFPS;
        self.sourceRotation = sourceRotation;
        self.mirrorSource = mirrorSource;
        self.maximumPixelDimension = maximumPixelDimension;
        self.jpegQuality = jpegQuality;
        self.aspectFill = aspectFill;
        self.sourceType = sourceType;
        self.localMediaURL = localMediaURL;
        self.loopLocalMedia = loopLocalMedia;
        self.holdLastFrame = holdLastFrame;
        self.staleFrameTimeout = staleFrameTimeout;
        self.sourceRestartToken = sourceRestartToken;
        self.targetBundleIdentifiers = targetBundleIdentifiers;
        self.publishedConfigurationAvailable = useRuntimeConfiguration;
        self.publishedHasTargetBundleFilter = runtimeConfiguration.hasTargetFilter;
        self.publishedCurrentProcessSelected =
            runtimeConfiguration.currentProcessSelected;
        return changed;
    }
}

- (BOOL)hasTargetBundleFilter {
    @synchronized (self) {
        if (self.publishedConfigurationAvailable) {
            return self.publishedHasTargetBundleFilter;
        }
        return self.targetBundleIdentifiers.count > 0;
    }
}

- (BOOL)isBundleIdentifierSelected:(NSString *)bundleIdentifier {
    @synchronized (self) {
        if (self.publishedConfigurationAvailable &&
            [bundleIdentifier isEqualToString:NSBundle.mainBundle.bundleIdentifier]) {
            return self.publishedCurrentProcessSelected;
        }
        if (self.targetBundleIdentifiers.count == 0) return YES;
        return bundleIdentifier.length > 0 &&
            [self.targetBundleIdentifiers containsObject:bundleIdentifier];
    }
}

- (BOOL)isCurrentProcessSelected {
    return [self isBundleIdentifierSelected:NSBundle.mainBundle.bundleIdentifier];
}

- (void)publishSharedConfiguration {
    BOOL enabled = NO;
    VCSourceType sourceType = VCSourceTypeNetwork;
    NSString *streamURLString = nil;
    NSSet<NSString *> *targets = nil;
    @synchronized (self) {
        enabled = self.enabled;
        sourceType = self.sourceType;
        streamURLString = sourceType == VCSourceTypeNetwork
            ? self.streamURL.absoluteString : nil;
        targets = [self.targetBundleIdentifiers copy];
    }

    NSData *urlData = [streamURLString dataUsingEncoding:NSUTF8StringEncoding];
    if (urlData.length > VCRuntimeMaximumURLBytes) urlData = nil;
    urlData = urlData ?: NSData.data;
    uint16_t generation = VCNextRuntimeConfigurationGeneration();
    const uint8_t *urlBytes = urlData.bytes;
    NSUInteger chunkCount = (urlData.length + 7) / 8;
    for (NSUInteger chunk = 0; chunk < chunkCount; chunk++) {
        uint64_t packed = 0;
        NSUInteger chunkLength = MIN((NSUInteger)8,
                                     urlData.length - chunk * 8);
        for (NSUInteger byte = 0; byte < chunkLength; byte++) {
            packed |= ((uint64_t)urlBytes[chunk * 8 + byte]) << (byte * 8);
        }
        VCWriteRuntimeState(VCURLChunkRuntimeNotification(chunk), packed);
    }

    uint64_t targetState = ((uint64_t)VCRuntimeConfigurationMagic << 48) |
                           ((uint64_t)generation << 32) | 1;
    for (NSString *identifier in targets) {
        if (identifier.length > 0) {
            VCWriteRuntimeState(VCTargetRuntimeNotification(identifier),
                                targetState);
        }
    }

    uint8_t flags = enabled ? 1U : 0U;
    if (targets.count > 0) flags |= 1U << 1;
    flags |= ((uint8_t)sourceType & 0x3U) << 2;
    uint16_t checksum = (uint16_t)VCFNV1a64(urlData) & 0xFFF;
    uint64_t metadata = ((uint64_t)VCRuntimeConfigurationMagic << 48) |
                        ((uint64_t)generation << 32) |
                        ((uint64_t)flags << 24) |
                        ((uint64_t)urlData.length << 12) |
                        checksum;
    if (VCWriteRuntimeState(VCRuntimeConfigurationNotification, metadata)) {
        notify_post(VCRuntimeConfigurationNotification.UTF8String);
    }
}

@end
