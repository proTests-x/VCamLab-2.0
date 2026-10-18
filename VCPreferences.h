#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const VCPreferencesDomain;
FOUNDATION_EXPORT NSString * const VCPreferencesChangedNotification;
FOUNDATION_EXPORT NSString * const VCEnabledKey;
FOUNDATION_EXPORT NSString * const VCStreamURLKey;
FOUNDATION_EXPORT NSString * const VCPreferredFPSKey;
FOUNDATION_EXPORT NSString * const VCSourceRotationKey;
FOUNDATION_EXPORT NSString * const VCMirrorSourceKey;
FOUNDATION_EXPORT NSString * const VCMaximumPixelDimensionKey;
FOUNDATION_EXPORT NSString * const VCJPEGQualityKey;
FOUNDATION_EXPORT NSString * const VCAspectFillKey;
FOUNDATION_EXPORT NSString * const VCSourceTypeKey;
FOUNDATION_EXPORT NSString * const VCLocalMediaPathKey;
FOUNDATION_EXPORT NSString * const VCLoopLocalMediaKey;
FOUNDATION_EXPORT NSString * const VCHoldLastFrameKey;
FOUNDATION_EXPORT NSString * const VCStaleFrameTimeoutKey;
FOUNDATION_EXPORT NSString * const VCSourceRestartTokenKey;
FOUNDATION_EXPORT NSString * const VCFloatingControlEnabledKey;
FOUNDATION_EXPORT NSString * const VCFloatingControlCenterXKey;
FOUNDATION_EXPORT NSString * const VCFloatingControlCenterYKey;

typedef NS_ENUM(NSInteger, VCSourceType) {
    VCSourceTypeNetwork = 0,
    VCSourceTypeScreen = 1,
    VCSourceTypeLocalMedia = 2,
};

@interface VCPreferences : NSObject

@property (atomic, assign, readonly, getter=isEnabled) BOOL enabled;
@property (atomic, copy, readonly, nullable) NSURL *streamURL;
/// These presentation/quality controls are consumed only for local media.
@property (atomic, assign, readonly) NSInteger preferredFPS;
@property (atomic, assign, readonly) NSInteger sourceRotation;
@property (atomic, assign, readonly) BOOL mirrorSource;
@property (atomic, assign, readonly) NSInteger maximumPixelDimension;
@property (atomic, assign, readonly) CGFloat jpegQuality;
@property (atomic, assign, readonly) BOOL aspectFill;
@property (atomic, assign, readonly) VCSourceType sourceType;
@property (atomic, copy, readonly, nullable) NSURL *localMediaURL;
@property (atomic, assign, readonly) BOOL loopLocalMedia;
@property (atomic, assign, readonly) BOOL holdLastFrame;
@property (atomic, assign, readonly) NSTimeInterval staleFrameTimeout;
/// Opaque settings-generated token used to rebuild the active producer without
/// changing any user-facing source configuration.
@property (atomic, copy, readonly) NSString *sourceRestartToken;

+ (instancetype)sharedPreferences;
- (BOOL)reload;

@end

NS_ASSUME_NONNULL_END
