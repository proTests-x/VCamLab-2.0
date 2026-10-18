#import "VCStreamCoordinator.h"

#import "AVAssetStreamAdapter.h"
#import "VCFrameConverter.h"
#import "VCLocalMediaSource.h"
#import "VCPreferences.h"
#import "VCScreenCaptureSource.h"
#import "VCSharedMediaBus.h"
#import <float.h>
#import <IOSurface/IOSurfaceRef.h>
#import <math.h>
#import <notify.h>
#import <os/lock.h>

static const char *VCStreamStatusNotificationName =
    "com.murkaska.virtualcampro/stream.status";
static const char *VCLocalTransformStatusNotificationName =
    "com.murkaska.virtualcampro/local-transform.status";
static const int VCInvalidNotifyToken = -1;

static uint64_t VCConsumerMonotonicMilliseconds(void) {
    NSTimeInterval uptime = NSProcessInfo.processInfo.systemUptime;
    if (!isfinite(uptime) || uptime <= 0) return 0;
    return (uint64_t)llround(uptime * 1000.0);
}

typedef NS_ENUM(uint64_t, VCStreamStatus) {
    VCStreamStatusDisabled = 0,
    VCStreamStatusConnecting = 1,
    VCStreamStatusReceiving = 2,
    VCStreamStatusError = 3,
    VCStreamStatusHoldingLastFrame = 4,
    VCStreamStatusCompleted = 5,
};

@interface VCStreamCoordinator () {
    os_unfair_lock _stateLock;
    BOOL _replacementEnabled;
    BOOL _producerProcess;
    VCSourceType _configuredSourceType;
    NSInteger _configuredFPS;
    CGFloat _configuredJPEGQuality;
    BOOL _configuredAspectFill;
    NSInteger _configuredMaximumPixelDimension;
    NSInteger _configuredSourceRotation;
    BOOL _configuredMirrorSource;
    BOOL _configuredHoldLastFrame;
    NSTimeInterval _configuredStaleFrameTimeout;
    NSUInteger _preferencesGeneration;
    NSUInteger _sourceGeneration;
    NSUInteger _transformGeneration;
    CVPixelBufferRef _pendingPixelBuffer;
    NSUInteger _pendingSourceGeneration;
    NSInteger _pendingTrackRotation;
    BOOL _pendingTrackMirror;
    BOOL _frameProcessingScheduled;
    int _streamStatusToken;
    int _localTransformStatusToken;
    BOOL _localTransformStatusNeedsPublish;
    uint64_t _publishedStreamStatus;
    BOOL _loggedFirstFrame;
    BOOL _loggedStaleFrame;
    CVPixelBufferRef _consumerFallbackPixelBuffer;
    uint64_t _consumerFallbackTimestampMilliseconds;
    BOOL _loggedConsumerFallbackFrame;
    CFAbsoluteTime _lastVolumeButtonActionTime;
}
@property (nonatomic, strong) AVAssetStreamAdapter *networkSource;
@property (nonatomic, strong) VCScreenCaptureSource *screenSource;
@property (nonatomic, strong) VCLocalMediaSource *localSource;
@property (nonatomic, copy) NSArray<NSURL *> *localMediaPlaylist;
@property (nonatomic, assign) NSInteger localMediaPlaylistIndex;
@property (nonatomic, copy) NSString *activeSourceIdentity;
@property (nonatomic, strong) dispatch_queue_t frameProcessingQueue;
@property (nonatomic, strong) dispatch_source_t memoryPressureSource;
- (void)clearPendingFrames;
- (void)stopConsumerNetworkFallback;
- (void)storeConsumerFallbackPixelBuffer:(CVPixelBufferRef)pixelBuffer
                         sourceGeneration:(NSUInteger)sourceGeneration;
- (BOOL)sourceGenerationIsCurrent:(NSUInteger)generation;
- (void)producerFailedWithError:(NSError *)error
               sourceGeneration:(NSUInteger)sourceGeneration;
@end

static BOOL VCURLHasSupportedLocalVideoExtension(NSURL *url) {
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:@[
            @"mp4", @"mov", @"m4v", @"3gp", @"3g2",
            @"avi", @"mpg", @"mpeg", @"ts", @"mts", @"m2ts",
        ]];
    });
    return [extensions containsObject:url.pathExtension.lowercaseString];
}

static NSArray<NSURL *> *VCLocalVideoPlaylistForURL(NSURL *selectedURL,
                                                     NSInteger *selectedIndex) {
    if (selectedIndex) *selectedIndex = NSNotFound;
    if (!selectedURL.isFileURL) return @[];
    NSURL *directory = selectedURL.URLByDeletingLastPathComponent;
    NSArray<NSURLResourceKey> *keys = @[NSURLIsRegularFileKey];
    NSMutableArray<NSURL *> *videos = [NSMutableArray array];
    NSDirectoryEnumerator<NSURL *> *entries = [[NSFileManager defaultManager]
        enumeratorAtURL:directory
includingPropertiesForKeys:keys
             options:NSDirectoryEnumerationSkipsHiddenFiles |
                     NSDirectoryEnumerationSkipsSubdirectoryDescendants
        errorHandler:^BOOL(__unused NSURL *url, __unused NSError *error) {
            return YES;
        }];
    NSUInteger inspectedCount = 0;
    for (NSURL *entry in entries) {
        if (++inspectedCount > 4096 || videos.count >= 512) break;
        NSNumber *regular = nil;
        [entry getResourceValue:&regular forKey:NSURLIsRegularFileKey error:NULL];
        if (regular.boolValue && VCURLHasSupportedLocalVideoExtension(entry)) {
            [videos addObject:entry];
        }
    }
    [videos sortUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        return [left.lastPathComponent localizedStandardCompare:right.lastPathComponent];
    }];
    NSUInteger index = [videos indexOfObjectPassingTest:^BOOL(NSURL *candidate,
                                                               NSUInteger idx,
                                                               BOOL *stop) {
        return [candidate.path isEqualToString:selectedURL.path];
    }];
    if (selectedIndex && index != NSNotFound) *selectedIndex = (NSInteger)index;
    return videos;
}

static void VCPreferencesDidChange(CFNotificationCenterRef center,
                                   void *observer,
                                   CFStringRef name,
                                   const void *object,
                                   CFDictionaryRef userInfo) {
    [(__bridge VCStreamCoordinator *)observer refreshPreferencesAndStream];
}

@implementation VCStreamCoordinator

+ (instancetype)sharedCoordinator {
    static VCStreamCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ coordinator = [[self alloc] init]; });
    return coordinator;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateLock = (os_unfair_lock)OS_UNFAIR_LOCK_INIT;
        _configuredFPS = 60;
        _configuredJPEGQuality = 1.0;
        _configuredAspectFill = YES;
        _configuredMaximumPixelDimension = 1920;
        _configuredHoldLastFrame = YES;
        _configuredStaleFrameTimeout = 8.0;
        _preferencesGeneration = 1;
        _sourceGeneration = 1;
        _transformGeneration = 1;
        _streamStatusToken = VCInvalidNotifyToken;
        _localTransformStatusToken = VCInvalidNotifyToken;
        _publishedStreamStatus = UINT64_MAX;
        NSString *process = NSProcessInfo.processInfo.processName;
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        _producerProcess = [process isEqualToString:@"SpringBoard"] ||
                           [bundle isEqualToString:@"com.apple.springboard"];
        dispatch_queue_attr_t attributes =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                     QOS_CLASS_USER_INTERACTIVE,
                                                     0);
        _frameProcessingQueue = dispatch_queue_create(
            "com.murkaska.virtualcampro.frame-processing", attributes);
    }
    return self;
}

- (void)startMonitoring {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (self->_producerProcess &&
            notify_register_check(VCStreamStatusNotificationName,
                                  &self->_streamStatusToken) == NOTIFY_STATUS_OK) {
            [self publishStreamStatus:VCStreamStatusDisabled];
        }
        if (self->_producerProcess) {
            notify_register_check(VCLocalTransformStatusNotificationName,
                                  &self->_localTransformStatusToken);
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)self,
                                        VCPreferencesDidChange,
                                        (__bridge CFStringRef)VCPreferencesChangedNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        [self startMemoryPressureMonitoring];
        [self refreshPreferencesAndStream];
    });
}

- (void)publishLocalTransformStatusReady:(BOOL)ready
                            trackRotation:(NSInteger)trackRotation
                              trackMirror:(BOOL)trackMirror {
    if (!_producerProcess || _localTransformStatusToken < 0) return;
    os_unfair_lock_lock(&_stateLock);
    BOOL configured = _replacementEnabled &&
                      _configuredSourceType == VCSourceTypeLocalMedia;
    NSInteger userRotation = _configuredSourceRotation;
    BOOL userMirror = _configuredMirrorSource;
    BOOL aspectFill = _configuredAspectFill;
    os_unfair_lock_unlock(&_stateLock);
    uint64_t state = configured ? 1ULL : 0ULL;
    if (configured && ready) state |= 1ULL << 1;
    if (userMirror) state |= 1ULL << 2;
    if (aspectFill) state |= 1ULL << 3;
    if (trackMirror) state |= 1ULL << 4;
    state |= ((uint64_t)((userRotation / 90) & 0x3)) << 8;
    state |= ((uint64_t)((trackRotation / 90) & 0x3)) << 10;
    notify_set_state(_localTransformStatusToken, state);
    notify_post(VCLocalTransformStatusNotificationName);
}

- (void)publishStreamStatus:(VCStreamStatus)status {
    int token = VCInvalidNotifyToken;
    os_unfair_lock_lock(&_stateLock);
    if (_publishedStreamStatus != status) {
        _publishedStreamStatus = status;
        token = _streamStatusToken;
    }
    os_unfair_lock_unlock(&_stateLock);
    if (token < 0) return;
    notify_set_state(token, status);
    notify_post(VCStreamStatusNotificationName);
}

- (void)startMemoryPressureMonitoring {
    if (self.memoryPressureSource) return;
    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_MEMORYPRESSURE,
        0,
        DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (!source) return;
    __weak VCStreamCoordinator *weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        VCStreamCoordinator *strongSelf = weakSelf;
        if (!strongSelf) return;
        unsigned long pressure = dispatch_source_get_data(strongSelf.memoryPressureSource);
        VCFlushFrameConverterCaches(YES);
        [strongSelf.networkSource handleMemoryPressure];
        [strongSelf.screenSource handleMemoryPressure];
        if (strongSelf->_producerProcess) {
            [[VCSharedVideoServer sharedServer] handleMemoryPressure];
            if (pressure & DISPATCH_MEMORYPRESSURE_CRITICAL) {
                [[VCSharedAudioServer sharedServer] handleMemoryPressure];
            }
        }
        if (pressure & DISPATCH_MEMORYPRESSURE_CRITICAL) {
            [strongSelf clearPendingFrames];
        }
    });
    self.memoryPressureSource = source;
    dispatch_resume(source);
}

- (NSString *)sourceIdentityForPreferences:(VCPreferences *)preferences {
    NSString *identity = nil;
    switch (preferences.sourceType) {
        case VCSourceTypeScreen:
            identity = @"screen";
            break;
        case VCSourceTypeLocalMedia:
            identity = preferences.localMediaURL
                ? [@"file:" stringByAppendingString:preferences.localMediaURL.path] : nil;
            break;
        case VCSourceTypeNetwork:
        default:
            identity = preferences.streamURL
                ? [@"network:" stringByAppendingString:preferences.streamURL.absoluteString] : nil;
            break;
    }
    if (identity.length > 0 && preferences.sourceRestartToken.length > 0) {
        identity = [identity stringByAppendingFormat:@"#restart=%@",
                                                     preferences.sourceRestartToken];
    }
    return identity;
}

- (void)refreshPreferencesAndStream {
    os_unfair_lock_lock(&_stateLock);
    NSUInteger preferenceGeneration = ++_preferencesGeneration;
    os_unfair_lock_unlock(&_stateLock);

    VCPreferences *preferences = VCPreferences.sharedPreferences;
    [preferences reload];
    __block BOOL enabled = NO;
    __block VCSourceType sourceType = VCSourceTypeNetwork;
    __block NSURL *networkURL = nil;
    __block NSURL *localURL = nil;
    __block BOOL loopLocalMedia = YES;
    __block NSInteger fps = 60;
    __block CGFloat jpegQuality = 1.0;
    __block BOOL aspectFill = YES;
    __block NSInteger rotation = 0;
    __block BOOL mirror = NO;
    __block BOOL holdLastFrame = YES;
    __block NSTimeInterval staleTimeout = 8.0;
    __block NSInteger maximumPixelDimension = 1920;
    __block NSString *sourceIdentity = nil;
    @synchronized (preferences) {
        sourceType = preferences.sourceType;
        networkURL = preferences.streamURL;
        localURL = preferences.localMediaURL;
        loopLocalMedia = preferences.loopLocalMedia;
        fps = preferences.preferredFPS;
        jpegQuality = preferences.jpegQuality;
        aspectFill = preferences.aspectFill;
        rotation = preferences.sourceRotation;
        mirror = preferences.mirrorSource;
        holdLastFrame = preferences.holdLastFrame;
        staleTimeout = preferences.staleFrameTimeout;
        maximumPixelDimension = preferences.maximumPixelDimension;
        sourceIdentity = [self sourceIdentityForPreferences:preferences];
        enabled = preferences.isEnabled && sourceIdentity.length > 0;
    }

    // Network frames are already authored by the sender. Screen capture follows
    // the display. Only local files are transformed/resized here, while the FPS
    // preference still describes network timing to preview and replacement
    // consumers.
    BOOL localMediaControlsActive = sourceType == VCSourceTypeLocalMedia;
    NSInteger effectiveFPS = sourceType == VCSourceTypeScreen ? 60 : fps;
    CGFloat effectiveJPEGQuality = localMediaControlsActive ? jpegQuality : 1.0;
    BOOL effectiveAspectFill = localMediaControlsActive ? aspectFill : YES;
    NSInteger effectiveRotation = localMediaControlsActive ? rotation : 0;
    BOOL effectiveMirror = localMediaControlsActive ? mirror : NO;
    NSInteger effectiveMaximumPixelDimension = localMediaControlsActive
        ? maximumPixelDimension : 4096;

    BOOL transformChanged = NO;
    BOOL localDecodeSizeChanged = NO;
    BOOL localRateChanged = NO;
    os_unfair_lock_lock(&_stateLock);
    if (preferenceGeneration == _preferencesGeneration) {
        transformChanged = _configuredSourceRotation != effectiveRotation ||
                           _configuredMirrorSource != effectiveMirror;
        localDecodeSizeChanged = _configuredMaximumPixelDimension !=
                                 effectiveMaximumPixelDimension;
        localRateChanged = localMediaControlsActive &&
                           _configuredFPS != effectiveFPS;
        if (transformChanged) _transformGeneration++;
        _replacementEnabled = enabled;
        _configuredSourceType = sourceType;
        _configuredFPS = effectiveFPS;
        _configuredJPEGQuality = effectiveJPEGQuality;
        _configuredAspectFill = effectiveAspectFill;
        _configuredMaximumPixelDimension = effectiveMaximumPixelDimension;
        _configuredSourceRotation = effectiveRotation;
        _configuredMirrorSource = effectiveMirror;
        _configuredHoldLastFrame = holdLastFrame;
        _configuredStaleFrameTimeout = staleTimeout;
        _localTransformStatusNeedsPublish = enabled && localMediaControlsActive;
    }
    os_unfair_lock_unlock(&_stateLock);
    if (_producerProcess) {
        [self publishLocalTransformStatusReady:NO trackRotation:0 trackMirror:NO];
    }
    if (!_producerProcess) {
        // Global IOSurface lookup is denied between SpringBoard and some
        // sandboxed iOS 15 camera processes even when the producer requested a
        // global surface. HLS is intentionally multi-client, so those consumers
        // can decode the same Windows stream locally without competing for the
        // single MJPEG listener connection.
        BOOL supportsDirectFallback = enabled &&
            sourceType == VCSourceTypeNetwork &&
            [networkURL.pathExtension.lowercaseString isEqualToString:@"m3u8"];
        dispatch_async(dispatch_get_main_queue(), ^{
            os_unfair_lock_lock(&self->_stateLock);
            BOOL current = preferenceGeneration == self->_preferencesGeneration;
            os_unfair_lock_unlock(&self->_stateLock);
            if (!current) return;

            NSString *fallbackIdentity = supportsDirectFallback
                ? [@"consumer-hls:" stringByAppendingString:networkURL.absoluteString]
                : nil;
            if (fallbackIdentity.length > 0 &&
                [self.activeSourceIdentity isEqualToString:fallbackIdentity] &&
                self.networkSource) {
                return;
            }

            [self stopConsumerNetworkFallback];
            if (!supportsDirectFallback) return;

            self.activeSourceIdentity = fallbackIdentity;
            os_unfair_lock_lock(&self->_stateLock);
            NSUInteger sourceGeneration = ++self->_sourceGeneration;
            self->_loggedConsumerFallbackFrame = NO;
            os_unfair_lock_unlock(&self->_stateLock);

            AVAssetStreamAdapter *source = [[AVAssetStreamAdapter alloc]
                                             initWithURL:networkURL];
            __weak VCStreamCoordinator *weakSelf = self;
            source.pixelBufferCallback = ^(CVPixelBufferRef pixelBuffer) {
                [weakSelf storeConsumerFallbackPixelBuffer:pixelBuffer
                                          sourceGeneration:sourceGeneration];
            };
            source.errorCallback = ^(NSError *error) {
                VCStreamCoordinator *strongSelf = weakSelf;
                if (!strongSelf ||
                    ![strongSelf sourceGenerationIsCurrent:sourceGeneration]) return;
                NSLog(@"[VirtualCamPro] Consumer HLS fallback error in %@: %@",
                      NSProcessInfo.processInfo.processName,
                      error.localizedDescription);
            };
            self.networkSource = source;
            [source startStreaming];
            NSLog(@"[VirtualCamPro] Consumer HLS fallback started in %@",
                  NSProcessInfo.processInfo.processName);
        });
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        os_unfair_lock_lock(&self->_stateLock);
        BOOL current = preferenceGeneration == self->_preferencesGeneration;
        os_unfair_lock_unlock(&self->_stateLock);
        if (!current) return;

        BOOL sameSource = enabled && [self.activeSourceIdentity isEqual:sourceIdentity];
        if (sameSource && !transformChanged && !localDecodeSizeChanged &&
            !localRateChanged) {
            self.screenSource.preferredFPS = 60;
            self.localSource.loops = loopLocalMedia;
            self.localSource.preferredFPS = effectiveFPS;
            return;
        }

        [self stopAllSourcesAndInvalidateBus];
        if (!enabled) {
            [self publishStreamStatus:VCStreamStatusDisabled];
            return;
        }
        self.activeSourceIdentity = sourceIdentity;
        os_unfair_lock_lock(&self->_stateLock);
        NSUInteger sourceGeneration = ++self->_sourceGeneration;
        self->_loggedFirstFrame = NO;
        self->_loggedStaleFrame = NO;
        self->_localTransformStatusNeedsPublish =
            sourceType == VCSourceTypeLocalMedia;
        os_unfair_lock_unlock(&self->_stateLock);
        [self publishStreamStatus:VCStreamStatusConnecting];

        if (sourceType == VCSourceTypeScreen) {
            VCScreenCaptureSource *source = [VCScreenCaptureSource new];
            source.preferredFPS = 60;
            __weak VCStreamCoordinator *weakSelf = self;
            source.frameCallback = ^(CVPixelBufferRef pixelBuffer) {
                [weakSelf enqueueLatestPixelBuffer:pixelBuffer
                                  sourceGeneration:sourceGeneration
                                      trackRotation:0
                                         trackMirror:NO];
            };
            source.errorCallback = ^(NSError *error) {
                [weakSelf producerFailedWithError:error
                                  sourceGeneration:sourceGeneration];
            };
            self.screenSource = source;
            [source start];
        } else if (sourceType == VCSourceTypeLocalMedia) {
            NSInteger playlistIndex = NSNotFound;
            self.localMediaPlaylist = VCLocalVideoPlaylistForURL(localURL, &playlistIndex);
            self.localMediaPlaylistIndex = playlistIndex;
            VCLocalMediaSource *source = [[VCLocalMediaSource alloc] initWithFileURL:localURL];
            source.loops = loopLocalMedia;
            source.preferredFPS = effectiveFPS;
            source.maximumPixelDimension = effectiveMaximumPixelDimension;
            __weak VCStreamCoordinator *weakSelf = self;
            __weak VCLocalMediaSource *weakSource = source;
            source.videoCallback = ^(CVPixelBufferRef pixelBuffer) {
                VCLocalMediaSource *strongSource = weakSource;
                [weakSelf enqueueLatestPixelBuffer:pixelBuffer
                                  sourceGeneration:sourceGeneration
                                      trackRotation:strongSource.trackRotation
                                         trackMirror:strongSource.isTrackMirrored];
            };
            source.audioCallback = ^(const float *samples, NSUInteger frameCount) {
                VCStreamCoordinator *strongSelf = weakSelf;
                if (!strongSelf || ![strongSelf sourceGenerationIsCurrent:sourceGeneration]) return;
                if ([[VCSharedAudioServer sharedServer]
                        publishInterleavedStereoSamples:samples frameCount:frameCount]) {
                    [strongSelf publishStreamStatus:VCStreamStatusReceiving];
                }
            };
            source.errorCallback = ^(NSError *error) {
                [weakSelf producerFailedWithError:error
                                  sourceGeneration:sourceGeneration];
            };
            source.completionCallback = ^{
                VCStreamCoordinator *strongSelf = weakSelf;
                if (!strongSelf ||
                    ![strongSelf sourceGenerationIsCurrent:sourceGeneration]) return;
                // Video may intentionally remain on the last frame, but stale
                // local PCM must stop immediately instead of replacing the mic
                // for another two seconds after natural EOF.
                [[VCSharedAudioServer sharedServer] invalidate];
                [strongSelf publishStreamStatus:VCStreamStatusCompleted];
            };
            self.localSource = source;
            [source start];
        } else {
            AVAssetStreamAdapter *source = [[AVAssetStreamAdapter alloc] initWithURL:networkURL];
            __weak VCStreamCoordinator *weakSelf = self;
            source.pixelBufferCallback = ^(CVPixelBufferRef pixelBuffer) {
                [weakSelf enqueueLatestPixelBuffer:pixelBuffer
                                  sourceGeneration:sourceGeneration
                                      trackRotation:0
                                         trackMirror:NO];
            };
            source.errorCallback = ^(NSError *error) {
                [weakSelf producerFailedWithError:error
                                  sourceGeneration:sourceGeneration];
            };
            self.networkSource = source;
            [source startStreaming];
        }
    });
}

- (BOOL)sourceGenerationIsCurrent:(NSUInteger)generation {
    os_unfair_lock_lock(&_stateLock);
    BOOL current = _replacementEnabled && _sourceGeneration == generation;
    os_unfair_lock_unlock(&_stateLock);
    return current;
}

- (void)producerFailedWithError:(NSError *)error
               sourceGeneration:(NSUInteger)sourceGeneration {
    if (![self sourceGenerationIsCurrent:sourceGeneration]) return;
    os_unfair_lock_lock(&_stateLock);
    BOOL holdLastFrame = _configuredHoldLastFrame;
    os_unfair_lock_unlock(&_stateLock);
    BOOL holding = holdLastFrame && [[VCSharedVideoClient sharedClient]
        hasPublishedFrameWithMaximumAge:365.0 * 24.0 * 60.0 * 60.0];
    [self publishStreamStatus:holding ? VCStreamStatusHoldingLastFrame
                                      : VCStreamStatusError];
    NSLog(@"[VirtualCamPro] Source error: %@", error.localizedDescription);
}

- (void)enqueueLatestPixelBuffer:(CVPixelBufferRef)pixelBuffer
                sourceGeneration:(NSUInteger)sourceGeneration
                    trackRotation:(NSInteger)trackRotation
                       trackMirror:(BOOL)trackMirror {
    if (!pixelBuffer) return;
    CVPixelBufferRef retained = CVPixelBufferRetain(pixelBuffer);
    CVPixelBufferRef retired = NULL;
    BOOL schedule = NO;
    os_unfair_lock_lock(&_stateLock);
    if (!_replacementEnabled || sourceGeneration != _sourceGeneration) {
        os_unfair_lock_unlock(&_stateLock);
        CVPixelBufferRelease(retained);
        return;
    }
    retired = _pendingPixelBuffer;
    _pendingPixelBuffer = retained;
    _pendingSourceGeneration = sourceGeneration;
    _pendingTrackRotation = trackRotation;
    _pendingTrackMirror = trackMirror;
    if (!_frameProcessingScheduled) {
        _frameProcessingScheduled = YES;
        schedule = YES;
    }
    os_unfair_lock_unlock(&_stateLock);
    if (retired) CVPixelBufferRelease(retired);
    if (!schedule) return;
    __weak VCStreamCoordinator *weakSelf = self;
    dispatch_async(self.frameProcessingQueue, ^{ [weakSelf processPendingFrames]; });
}

- (void)processPendingFrames {
    while (YES) {
        CVPixelBufferRef input = NULL;
        NSUInteger sourceGeneration = 0;
        NSUInteger transformGeneration = 0;
        NSInteger rotation = 0;
        BOOL mirror = NO;
        NSInteger userRotation = 0;
        BOOL userMirror = NO;
        NSInteger trackRotation = 0;
        BOOL trackMirror = NO;
        os_unfair_lock_lock(&_stateLock);
        input = _pendingPixelBuffer;
        _pendingPixelBuffer = NULL;
        if (!input) {
            _frameProcessingScheduled = NO;
            os_unfair_lock_unlock(&_stateLock);
            return;
        }
        sourceGeneration = _pendingSourceGeneration;
        transformGeneration = _transformGeneration;
        trackRotation = _pendingTrackRotation;
        trackMirror = _pendingTrackMirror;
        userRotation = _configuredSourceRotation;
        userMirror = _configuredMirrorSource;
        rotation = ((trackRotation + userRotation) % 360 + 360) % 360;
        mirror = trackMirror != userMirror;
        os_unfair_lock_unlock(&_stateLock);

        CVPixelBufferRef transformed = VCCopyPixelBufferApplyingOrientation(input,
                                                                             rotation,
                                                                             mirror);
        BOOL transformRequired = rotation != 0 || mirror;
        if (transformed && (rotation == 90 || rotation == 270)) {
            size_t expectedWidth = CVPixelBufferGetHeight(input);
            size_t expectedHeight = CVPixelBufferGetWidth(input);
            if (CVPixelBufferGetWidth(transformed) != expectedWidth ||
                CVPixelBufferGetHeight(transformed) != expectedHeight) {
                NSLog(@"[VirtualCamPro] Rejecting invalid local orientation output: "
                       "%zux%zu expected %zux%zu",
                      CVPixelBufferGetWidth(transformed),
                      CVPixelBufferGetHeight(transformed),
                      expectedWidth,
                      expectedHeight);
                CVPixelBufferRelease(transformed);
                transformed = NULL;
            }
        }
        BOOL transformApplied = transformed != NULL || !transformRequired;
        if (!transformed && (rotation != 0 || mirror)) {
            static dispatch_once_t orientationFailureLogToken;
            dispatch_once(&orientationFailureLogToken, ^{
                NSLog(@"[VirtualCamPro] Local orientation render failed; preserving source frames");
            });
        }
        if (!transformed) transformed = CVPixelBufferRetain(input);
        CVPixelBufferRelease(input);

        // Do not publish the decoder's surface directly. On iOS 15,
        // VideoToolbox can return an IOSurface with a valid local ID while
        // ignoring kIOSurfaceIsGlobal, so Camera sees the notification state
        // but IOSurfaceLookup fails. Copy into our own global BGRA pool first.
        CVPixelBufferRef shareable = VCCopyShareablePixelBuffer(transformed);
        if (!shareable) {
            static dispatch_once_t shareableCopyFailureLogToken;
            dispatch_once(&shareableCopyFailureLogToken, ^{
                NSLog(@"[VirtualCamPro] Could not create a global shared frame; "
                       @"preserving the previous published frame");
            });
        }

        os_unfair_lock_lock(&_stateLock);
        BOOL current = _replacementEnabled && sourceGeneration == _sourceGeneration &&
                       transformGeneration == _transformGeneration;
        BOOL firstFrame = current && !_loggedFirstFrame;
        if (firstFrame) _loggedFirstFrame = YES;
        os_unfair_lock_unlock(&_stateLock);
        if (current && shareable &&
            [[VCSharedVideoServer sharedServer] publishPixelBuffer:shareable]) {
            [self publishStreamStatus:VCStreamStatusReceiving];
            BOOL publishTransformStatus = NO;
            os_unfair_lock_lock(&_stateLock);
            if (_localTransformStatusNeedsPublish && _replacementEnabled &&
                sourceGeneration == _sourceGeneration &&
                transformGeneration == _transformGeneration) {
                _localTransformStatusNeedsPublish = NO;
                publishTransformStatus = YES;
            }
            os_unfair_lock_unlock(&_stateLock);
            if (publishTransformStatus) {
                [self publishLocalTransformStatusReady:transformApplied
                                         trackRotation:trackRotation
                                           trackMirror:trackMirror];
            }
            if (firstFrame) {
                NSLog(@"[VirtualCamPro] SpringBoard published first shared frame: %zux%zu/%u "
                       "(track rotation=%ld mirror=%@, user rotation=%ld mirror=%@)",
                      CVPixelBufferGetWidth(transformed),
                      CVPixelBufferGetHeight(transformed),
                      (unsigned int)CVPixelBufferGetPixelFormatType(transformed),
                      (long)trackRotation,
                      trackMirror ? @"YES" : @"NO",
                      (long)userRotation,
                      userMirror ? @"YES" : @"NO");
            }
        }
        if (shareable) CVPixelBufferRelease(shareable);
        CVPixelBufferRelease(transformed);
    }
}

- (BOOL)handleLocalMediaVolumeButtonDirection:(NSInteger)direction {
    if (!_producerProcess || direction == 0) return NO;
    __block NSURL *nextURL = nil;
    @synchronized (self) {
        os_unfair_lock_lock(&_stateLock);
        BOOL active = _replacementEnabled &&
                      _configuredSourceType == VCSourceTypeLocalMedia;
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        BOOL debounced = _lastVolumeButtonActionTime > 0 &&
                         now - _lastVolumeButtonActionTime < 0.35;
        os_unfair_lock_unlock(&_stateLock);
        NSURL *selectedURL = self.localSource.fileURL;
        NSInteger selectedIndex = NSNotFound;
        NSArray<NSURL *> *freshPlaylist = VCLocalVideoPlaylistForURL(selectedURL,
                                                                     &selectedIndex);
        if (freshPlaylist.count > 0) {
            self.localMediaPlaylist = freshPlaylist;
            self.localMediaPlaylistIndex = selectedIndex;
        }
        NSInteger count = (NSInteger)self.localMediaPlaylist.count;
        if (!active || count == 0) return NO;
        // Consume key-repeat events while a local playlist owns the buttons, but
        // advance at most once per deliberate click.
        if (debounced) return YES;
        NSInteger current = self.localMediaPlaylistIndex;
        if (current == NSNotFound) {
            current = direction > 0 ? 0 : count - 1;
        } else if (count < 2) {
            return NO;
        } else {
            current = (current + (direction > 0 ? 1 : -1) + count) % count;
        }
        nextURL = self.localMediaPlaylist[(NSUInteger)current];
        os_unfair_lock_lock(&_stateLock);
        _lastVolumeButtonActionTime = now;
        os_unfair_lock_unlock(&_stateLock);
    }
    if (!nextURL) return NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        CFPreferencesSetAppValue((__bridge CFStringRef)VCLocalMediaPathKey,
                                 (__bridge CFStringRef)nextURL.path,
                                 (__bridge CFStringRef)VCPreferencesDomain);
        BOOL saved = CFPreferencesAppSynchronize((__bridge CFStringRef)VCPreferencesDomain);
        if (!saved) {
            NSLog(@"[VirtualCamPro] Volume-button video switch could not persist %@",
                  nextURL.lastPathComponent);
            return;
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)VCPreferencesChangedNotification,
            NULL,
            NULL,
            YES);
        // Do not depend on this process receiving its own Darwin notification.
        // Reload directly so the old reader is invalidated on the next main-loop
        // turn even if notification delivery is coalesced.
        [self refreshPreferencesAndStream];
        NSLog(@"[VirtualCamPro] Volume button selected local video %@",
              nextURL.lastPathComponent);
    });
    return YES;
}

- (void)stopAllSourcesAndInvalidateBus {
    AVAssetStreamAdapter *network = self.networkSource;
    VCScreenCaptureSource *screen = self.screenSource;
    VCLocalMediaSource *local = self.localSource;
    // Retire the generation before touching producer callbacks. A callback
    // already copied by another queue must observe staleness immediately,
    // including during the stop/cancel window itself.
    os_unfair_lock_lock(&_stateLock);
    _sourceGeneration++;
    os_unfair_lock_unlock(&_stateLock);
    self.networkSource = nil;
    self.screenSource = nil;
    self.localSource = nil;
    self.localMediaPlaylist = @[];
    self.localMediaPlaylistIndex = NSNotFound;
    self.activeSourceIdentity = nil;
    network.pixelBufferCallback = nil;
    network.errorCallback = nil;
    screen.frameCallback = nil;
    screen.errorCallback = nil;
    local.videoCallback = nil;
    local.audioCallback = nil;
    local.errorCallback = nil;
    local.completionCallback = nil;
    [network stopStreaming];
    [screen stop];
    [local stop];
    [self clearPendingFrames];
    [[VCSharedVideoServer sharedServer] invalidate];
    [[VCSharedAudioServer sharedServer] invalidate];
}

- (void)clearPendingFrames {
    CVPixelBufferRef pending = NULL;
    os_unfair_lock_lock(&_stateLock);
    pending = _pendingPixelBuffer;
    _pendingPixelBuffer = NULL;
    _pendingTrackRotation = 0;
    _pendingTrackMirror = NO;
    _loggedFirstFrame = NO;
    _loggedStaleFrame = NO;
    os_unfair_lock_unlock(&_stateLock);
    if (pending) CVPixelBufferRelease(pending);
    VCResetFrameConverterCache();
}

- (void)stopConsumerNetworkFallback {
    if (_producerProcess) return;
    AVAssetStreamAdapter *network = self.networkSource;
    self.networkSource = nil;
    self.activeSourceIdentity = nil;
    CVPixelBufferRef retired = NULL;
    os_unfair_lock_lock(&_stateLock);
    _sourceGeneration++;
    retired = _consumerFallbackPixelBuffer;
    _consumerFallbackPixelBuffer = NULL;
    _consumerFallbackTimestampMilliseconds = 0;
    _loggedConsumerFallbackFrame = NO;
    os_unfair_lock_unlock(&_stateLock);
    network.pixelBufferCallback = nil;
    network.errorCallback = nil;
    [network stopStreaming];
    if (retired) CVPixelBufferRelease(retired);
}

- (void)storeConsumerFallbackPixelBuffer:(CVPixelBufferRef)pixelBuffer
                         sourceGeneration:(NSUInteger)sourceGeneration {
    if (!pixelBuffer) return;
    CVPixelBufferRef retained = CVPixelBufferRetain(pixelBuffer);
    CVPixelBufferRef retired = NULL;
    BOOL logFirstFrame = NO;
    os_unfair_lock_lock(&_stateLock);
    if (!_producerProcess && _replacementEnabled &&
        sourceGeneration == _sourceGeneration) {
        retired = _consumerFallbackPixelBuffer;
        _consumerFallbackPixelBuffer = retained;
        _consumerFallbackTimestampMilliseconds = VCConsumerMonotonicMilliseconds();
        logFirstFrame = !_loggedConsumerFallbackFrame;
        _loggedConsumerFallbackFrame = YES;
        retained = NULL;
    }
    os_unfair_lock_unlock(&_stateLock);
    if (retired) CVPixelBufferRelease(retired);
    if (retained) CVPixelBufferRelease(retained);
    if (logFirstFrame) {
        NSLog(@"[VirtualCamPro] Consumer HLS fallback received its first frame in %@",
              NSProcessInfo.processInfo.processName);
    }
}

- (CVPixelBufferRef)copyLatestPixelBuffer {
    return [self copyLatestPixelBufferWithAspectFill:NULL preferredFPS:NULL];
}

- (CVPixelBufferRef)copyLatestPixelBufferWithAspectFill:(BOOL *)aspectFill
                                           preferredFPS:(NSInteger *)preferredFPS {
    BOOL enabled = NO;
    BOOL hold = NO;
    NSTimeInterval staleTimeout = 0;
    BOOL logStale = NO;
    os_unfair_lock_lock(&_stateLock);
    if (aspectFill) *aspectFill = _configuredAspectFill;
    if (preferredFPS) *preferredFPS = _configuredFPS;
    enabled = _replacementEnabled;
    hold = _configuredHoldLastFrame;
    staleTimeout = _configuredStaleFrameTimeout;
    os_unfair_lock_unlock(&_stateLock);
    // SpringBoard is the canonical producer and invalidates the shared bus as
    // soon as replacement is disabled. Sandboxed camera applications cannot
    // reliably read SpringBoard's preference domain, so consumers must use
    // the presence of a valid shared frame as the authoritative state instead
    // of rejecting it because their local CFPreferences lookup returned NO.
    if (_producerProcess && !enabled) return NULL;
    NSTimeInterval maximumAge = hold ? 365.0 * 24.0 * 60.0 * 60.0 : staleTimeout;
    CVPixelBufferRef result = [[VCSharedVideoClient sharedClient]
        copyLatestPixelBufferWithMaximumAge:maximumAge];
    if (!result && !_producerProcess) {
        CVPixelBufferRef local = NULL;
        uint64_t localTimestamp = 0;
        os_unfair_lock_lock(&_stateLock);
        local = _consumerFallbackPixelBuffer
            ? CVPixelBufferRetain(_consumerFallbackPixelBuffer) : NULL;
        localTimestamp = _consumerFallbackTimestampMilliseconds;
        os_unfair_lock_unlock(&_stateLock);
        BOOL localIsFresh = local && (hold || VCSharedTimestampIsRecent(
            VCConsumerMonotonicMilliseconds(), localTimestamp,
            (uint64_t)MAX(1.0, staleTimeout * 1000.0)));
        if (localIsFresh) {
            IOSurfaceRef surface = CVPixelBufferGetIOSurface(local);
            if (surface) {
                // Match the ownership contract of the shared-bus return path so
                // every existing caller can continue using the symmetric
                // VCReleaseSharedVideoPixelBuffer helper.
                IOSurfaceIncrementUseCount(surface);
                result = local;
                local = NULL;
            }
        }
        if (local) CVPixelBufferRelease(local);
    }
    if (!result && !hold) {
        os_unfair_lock_lock(&_stateLock);
        logStale = !_loggedStaleFrame;
        _loggedStaleFrame = YES;
        os_unfair_lock_unlock(&_stateLock);
        if (logStale) {
            NSLog(@"[VirtualCamPro] Shared frame is stale; preserving the physical camera frame");
        }
    }
    return result;
}

- (BOOL)isReplacementActive {
    os_unfair_lock_lock(&_stateLock);
    BOOL enabled = _replacementEnabled;
    BOOL hold = _configuredHoldLastFrame;
    NSTimeInterval timeout = _configuredStaleFrameTimeout;
    os_unfair_lock_unlock(&_stateLock);
    BOOL hasPublishedFrame = [[VCSharedVideoClient sharedClient]
        hasPublishedFrameWithMaximumAge:hold ? 365.0 * 24.0 * 60.0 * 60.0 : timeout];
    return (_producerProcess ? enabled : YES) && hasPublishedFrame;
}

- (BOOL)isSystemPipelineReplacementConfigured {
    os_unfair_lock_lock(&_stateLock);
    BOOL enabled = _replacementEnabled;
    os_unfair_lock_unlock(&_stateLock);
    if (_producerProcess) return enabled;
    return [[VCSharedVideoClient sharedClient]
        hasPublishedFrameWithMaximumAge:365.0 * 24.0 * 60.0 * 60.0];
}

- (NSInteger)preferredFPS {
    os_unfair_lock_lock(&_stateLock);
    NSInteger value = _configuredFPS;
    os_unfair_lock_unlock(&_stateLock);
    return value;
}

- (CGFloat)jpegQuality {
    os_unfair_lock_lock(&_stateLock);
    CGFloat value = _configuredJPEGQuality;
    os_unfair_lock_unlock(&_stateLock);
    return value;
}

- (BOOL)aspectFill {
    os_unfair_lock_lock(&_stateLock);
    BOOL value = _configuredAspectFill;
    os_unfair_lock_unlock(&_stateLock);
    return value;
}

- (BOOL)holdLastFrame {
    os_unfair_lock_lock(&_stateLock);
    BOOL value = _configuredHoldLastFrame;
    os_unfair_lock_unlock(&_stateLock);
    return value;
}

- (NSTimeInterval)staleFrameTimeout {
    os_unfair_lock_lock(&_stateLock);
    NSTimeInterval value = _configuredStaleFrameTimeout;
    os_unfair_lock_unlock(&_stateLock);
    return value;
}

- (void)dealloc {
    [self stopConsumerNetworkFallback];
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
    if (_producerProcess) [self stopAllSourcesAndInvalidateBus];
    else [self clearPendingFrames];
    if (self.memoryPressureSource) dispatch_source_cancel(self.memoryPressureSource);
    if (_streamStatusToken >= 0) notify_cancel(_streamStatusToken);
    if (_localTransformStatusToken >= 0) notify_cancel(_localTransformStatusToken);
}
@end
