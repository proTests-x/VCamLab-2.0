#!/usr/bin/env python3
"""Repository checks that do not require Theos or an iOS SDK."""

from __future__ import annotations

import plistlib
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ERRORS: list[str] = []


def fail(message: str) -> None:
    ERRORS.append(message)


def read_text(relative: str) -> str:
    path = ROOT / relative
    if not path.is_file():
        fail(f"missing file: {relative}")
        return ""
    return path.read_text(encoding="utf-8")


def read_plist(relative: str):
    path = ROOT / relative
    if not path.is_file():
        fail(f"missing plist: {relative}")
        return {}
    try:
        with path.open("rb") as handle:
            return plistlib.load(handle)
    except Exception as exc:
        fail(f"invalid plist {relative}: {exc}")
        return {}


def require(text: str, fragments: tuple[str, ...], context: str) -> None:
    for fragment in fragments:
        if fragment not in text:
            fail(f"{context} missing: {fragment}")


def validate_plists() -> None:
    for path in sorted(ROOT.rglob("*.plist")):
        try:
            with path.open("rb") as handle:
                plistlib.load(handle)
        except Exception as exc:
            fail(f"invalid plist {path.relative_to(ROOT)}: {exc}")


def validate_makefile() -> None:
    makefile = read_text("Makefile")
    require(
        makefile,
        (
            "THEOS_PACKAGE_SCHEME = rootless",
            "TARGET = iphone:clang:16.5:15.0",
            "ARCHS ?= arm64 arm64e",
            "TWEAK_NAME = AVFCameraSupport VCMediaServer",
            "VCSharedMediaBus.m",
            "VCAudioSampleConverter.m",
            "VCScreenCaptureSource.m",
            "VCLocalMediaSource.m",
            "IOSurface",
            "AudioToolbox",
            "INSTALL_TARGET_PROCESSES = SpringBoard Camera mediaserverd",
        ),
        "Makefile",
    )
    source_names = set(
        re.findall(r"[A-Za-z0-9_+.-]+\.(?:m|mm|x|xm|c|cpp)(?![A-Za-z0-9_.-])", makefile)
    )
    for source in source_names:
        if not (ROOT / source).is_file():
            fail(f"Makefile references missing source: {source}")
    media_frameworks = re.search(r"^VCMediaServer_FRAMEWORKS\s*=\s*(.+)$",
                                 makefile,
                                 re.MULTILINE)
    if media_frameworks and "UIKit" in media_frameworks.group(1).split():
        fail("mediaserverd binary must not statically link UIKit")


def validate_preferences() -> None:
    implementation = read_text("VCPreferences.m")
    header = read_text("VCPreferences.h")
    controller = read_text("prefs/VCPRootListController.m")
    application_selector = read_text("prefs/VCPApplicationSelectorController.m")
    track_loader = read_text("VCMediaTrackLoader.h")
    bundle_makefile = read_text("prefs/Makefile")
    workflow = read_text(".github/workflows/test.yml")
    root = read_plist("prefs/Resources/Root.plist")
    items = root.get("items", [])
    keyed = {item.get("key"): item for item in items if item.get("key")}
    expected = {
        "enabled",
        "sourceType",
        "streamURL",
        "localMediaPath",
        "loopLocalMedia",
        "preferredFPS",
        "sourceRotation",
        "mirrorSource",
        "maximumPixelDimension",
        "jpegQuality",
        "aspectFill",
        "holdLastFrame",
        "staleFrameTimeout",
    }
    missing = expected - keyed.keys()
    if missing:
        fail(f"settings UI missing keys: {', '.join(sorted(missing))}")
    for key in expected:
        item = keyed.get(key, {})
        if item.get("defaults") != "com.murkaska.virtualcampro":
            fail(f"wrong preference domain for {key}")
        if item.get("PostNotification") != "com.murkaska.virtualcampro/preferences.changed":
            fail(f"missing Darwin preference notification for {key}")
        if f'@"{key}"' not in implementation:
            fail(f"VCPreferences.m missing key constant: {key}")
    if keyed.get("sourceType", {}).get("validValues") != [0, 1, 2]:
        fail("sourceType must expose network, screen, and local media")
    for item in items:
        if item.get("cell") != "PSLinkListCell":
            continue
        key = item.get("key", "<unknown>")
        if item.get("detail") != "PSListItemsController":
            fail(f"{key} link-list is missing PSListItemsController (opens a blank page)")
        titles = item.get("validTitles")
        values = item.get("validValues")
        if not isinstance(titles, list) or not titles or len(titles) != len(values or []):
            fail(f"{key} link-list titles and values must be non-empty and aligned")
    if keyed.get("enabled", {}).get("default") is not False:
        fail("replacement must remain disabled by default")
    if keyed.get("loopLocalMedia", {}).get("default") is not True:
        fail("local media should loop by default")
    for key in (
        "localMediaPath",
        "loopLocalMedia",
        "preferredFPS",
        "sourceRotation",
        "mirrorSource",
        "maximumPixelDimension",
        "jpegQuality",
        "aspectFill",
    ):
        if keyed.get(key, {}).get("vcSourceTypes") != [2]:
            fail(f"{key} must be presented as a local-media-only setting")
    local_media = keyed.get("localMediaPath", {})
    if local_media.get("cell") != "PSTitleValueCell" or \
            local_media.get("get") != "currentLocalMediaName:":
        fail("localMediaPath must be a read-only current-media status row")
    actions = {item.get("action"): item for item in items if item.get("action")}
    for action in ("chooseLocalMedia:", "clearLocalMedia:"):
        if actions.get(action, {}).get("vcSourceTypes") != [2]:
            fail(f"missing local-media-only settings action: {action}")
    for action in (
        "showCurrentSourceGuide:",
        "reloadCurrentSource:",
        "copyRuntimeDiagnostics:",
        "chooseTargetApplications:",
    ):
        if action not in actions:
            fail(f"settings control panel is missing action: {action}")
    if actions.get("showLocalMediaLibrary:", {}).get("vcSourceTypes") != [2]:
        fail("local media library viewer must be local-media-only")
    live_status_getters = {
        item.get("get") for item in items if item.get("vcLiveStatus") is True
    }
    if live_status_getters != {
        "currentSourceRuntimeStatus:",
        "currentSharedVideoBusStatus:",
        "currentSystemVideoPipelineStatus:",
        "currentApplicationFallbackStatus:",
        "currentLocalVolumeHookStatus:",
        "currentLocalTransformStatus:",
    }:
        fail("settings live-refresh rows are incomplete or include editable controls")
    require(
        controller,
        (
            "UIDocumentPickerViewController",
            "PHPickerViewController",
            "startAccessingSecurityScopedResource",
            "NSFileCoordinator",
            '@"/var/mobile/Media/VirtualCamPro"',
            "NSFileSystemFreeSize",
            "VCAssetContainsRecognizableMediaTracks",
            "VCMediaLoadTracksFromURL",
            "VCLocalMediaTrackLoadingTimeout",
            "VCLocalMediaImportErrorTrackLoadingTimeout",
            "UniformTypeIdentifiers/UniformTypeIdentifiers.h",
            "NSURLContentTypeKey",
            "VCPreferredLocalMediaExtension",
            "VCIsKnownLocalMediaExtension",
            "PHPickerConfigurationAssetRepresentationModeCompatible",
            "CFPreferencesSetAppValue(VCLocalMediaPathKey",
            "picker.allowsMultipleSelection = YES",
            "configuration.selectionLimit = 20",
            "finishLocalMediaImportsWithURLs",
            "currentLocalVideoPlaylistSummary:",
            "currentLocalTransformStatus:",
            "currentLocalVolumeHookStatus:",
            "currentSourceRuntimeStatus:",
            "currentSharedVideoBusStatus:",
            "currentSystemVideoPipelineStatus:",
            "currentApplicationFallbackStatus:",
            "reloadCurrentSource:",
            "sourceRestartToken",
            "pipeline.video.heartbeat.v1",
            "scheduledTimerWithTimeInterval:1.0",
            "stopStatusRefreshTimer",
            "vcLiveStatus",
            "currentSourceConfigurationSummary:",
            "currentNetworkEndpointSummary:",
            "currentLocalMediaLibrarySummary:",
            "showLocalMediaLibrary:",
            "NSByteCountFormatter",
            "VCPDisplaySafeFilename",
            "controlCharacterSet",
            "copyRuntimeDiagnostics:",
            "UIPasteboard.generalPasteboard.string",
            "showCurrentSourceGuide:",
            "VCPNotifyTokenForChannel",
            "synchronizePreferencesIfNeeded:",
            "VCPStreamStatusCompleted",
            "viewDidAppear:",
            "performSafeRuntimePresentationRefresh",
            "disableRuntimePresentationAfterException:",
            "_runtimePresentationDisabled",
            "VCPRepairStoredPreferences",
            "VCPReadFinitePreferenceNumber",
            "VCPReadIntegerPreference",
            "VCPReadRealPreference",
            "VCPReadBooleanPreference",
            "VCPreferenceValidateInteger",
            "VCPreferenceValidateReal",
            "[value length] > 64",
            "OS_UNFAIR_LOCK_INIT",
            "lastAttemptMilliseconds",
            '@"maximumLength": @4096',
            '@"maximumLength": @128',
            "currentTargetApplicationsSummary:",
            "VCPApplicationSelectorController",
        ),
        "mobile native settings and runtime recovery",
    )
    require(
        application_selector + implementation + header + bundle_makefile,
        (
            "LSApplicationWorkspace",
            "allInstalledApplications",
            "targetBundleIdentifiers",
            "com.apple.camera",
            "com.apple.WebKit.WebContent",
            "VCPWriteSelectedBundleIdentifiers",
            "VCTargetBundleIdentifiersKey",
            "targetBundleIdentifiersValue",
            "isCurrentProcessSelected",
            "VCPApplicationSelectorController.m",
        ),
        "target application selection",
    )
    require(
        track_loader,
        (
            "VCMediaTrackLoadResultLoaded",
            "VCMediaTrackLoadResultFailed",
            "VCMediaTrackLoadResultTimedOut",
            "VCMediaTrackLoadResultCancelled",
            "loadTracksWithMediaType:AVMediaTypeVideo",
            "loadTracksWithMediaType:AVMediaTypeAudio",
            "dispatch_group_wait",
            "NSProcessInfo.processInfo.systemUptime",
            "[asset cancelLoading]",
            "VCMediaLoadVideoTrackGeometry",
            "VCMediaLoadTracksFromURL",
            "VCMediaWaitForRetryDelay",
            "maximumAttempts",
            "fresh asset",
            "AVURLAsset *asset, BOOL loading",
            'loadValuesAsynchronouslyForKeys:@[@"preferredTransform", @"naturalSize"]',
            'statusOfValueForKey:@"preferredTransform"',
            'statusOfValueForKey:@"naturalSize"',
        ),
        "shared asynchronous local-media track loader",
    )
    if "[asset tracksWithMediaType:" in controller or \
       "PHPickerConfigurationAssetRepresentationModeCurrent" in controller:
        fail("local media import must await tracks and request a compatible Photos asset")
    view_will_appear = controller.split("- (void)viewWillAppear:", 1)[1].split(
        "- (void)viewDidAppear:", 1
    )[0]
    if "refreshRuntimePresentation" in view_will_appear or \
       "startStatusRefreshTimer" in view_will_appear:
        fail("optional Settings status refresh must wait until viewDidAppear")
    if "reloadSpecifier:specifier animated:" in controller or \
       "reloadSpecifier:statusSpecifier animated:" in controller:
        fail("Settings live rows must use the iOS 15-compatible reload selector")
    for legacy_dashboard_symbol in (
        "VCPDashboardHeaderView",
        "dashboardHeader",
        "installDashboardHeaderIfNeeded",
        "layoutDashboardHeaderIfNeeded",
        "systemLayoutSizeFittingSize",
    ):
        if legacy_dashboard_symbol in controller:
            fail("legacy Settings dashboard code must not be compiled: " +
                 legacy_dashboard_symbol)
    if "QuartzCore" in bundle_makefile:
        fail("preference bundle must not require the optional QuartzCore dashboard")
    if "UniformTypeIdentifiers" not in bundle_makefile:
        fail("preference bundle must link media filename type inference")
    specifier_loader = controller.split("- (NSArray *)specifiers", 1)[1].split(
        "- (void)setPreferenceValue:", 1
    )[0]
    repair_index = specifier_loader.find("VCPRepairStoredPreferences()")
    load_index = specifier_loader.find("loadSpecifiersFromPlistName")
    if repair_index < 0 or load_index < 0 or repair_index > load_index:
        fail("stored preference types must be normalized before Root.plist loads")
    if "notify_cancel(" in controller or controller.count("notify_register_check(") != 1:
        fail("settings live polling must reuse process-lifetime Darwin notify tokens")
    preference_validation = read_text("VCPreferenceValidation.h")
    preference_validation_test = read_text("tests/test_preference_validation.c")
    require(
        preference_validation,
        (
            "VCPreferenceValidateInteger",
            "VCPreferenceValidateReal",
            "isfinite",
            "value < (double)minimum",
            "value > (double)maximum",
        ),
        "stored preference numeric validation",
    )
    require(
        preference_validation_test,
        (
            "1.0e300",
            "-1.0e300",
            "NAN",
            "INFINITY",
            "test_integer_boundaries",
            "test_real_boundaries",
        ),
        "stored preference sanitizer regression test",
    )
    if "tests/test_preference_validation.c" not in workflow:
        fail("source validation workflow does not run preference sanitizer tests")
    require(
        bundle_makefile,
        ("AVFoundation", "PhotosUI"),
        "preference bundle frameworks",
    )
    if "query" in controller.split("copyRuntimeDiagnostics:", 1)[1].split(
            "clearLocalMedia:", 1)[0]:
        fail("copied runtime diagnostics must not include network query parameters")
    if "compatibilityMode" in keyed or "VCCompatibilityModeKey" in header:
        fail("the obsolete manual compatibility mode is still exposed")
    require(
        implementation,
        (
            '#import "VCPreferenceValidation.h"',
            "VCReadFinitePreferenceNumber",
            "VCReadBooleanPreference",
            "VCPreferenceValidateInteger",
            "VCPreferenceValidateReal",
            "[value length] > 64",
            "[value length] > 16",
            'hasPrefix:@"/var/mobile/Media/"',
            'hasPrefix:@"/var/mobile/Library/VirtualCamPro/"',
            "path.stringByStandardizingPath",
            "candidate.user.length == 0",
            "candidate.password.length == 0",
        ),
        "preference validation",
    )
    for unsafe_scalar_read in (
        "[enabledValue boolValue]",
        "[fpsValue integerValue]",
        "[qualityValue doubleValue]",
        "[staleFrameTimeoutValue doubleValue]",
    ):
        if unsafe_scalar_read in implementation:
            fail("runtime preferences contain an unchecked scalar message: " +
                 unsafe_scalar_read)
    example = read_plist("example-config.plist")
    for key in expected:
        if key not in example:
            fail(f"example-config.plist missing key: {key}")


def validate_injection_filters() -> None:
    app_filter = read_plist("AVFCameraSupport.plist").get("Filter", {})
    expected_classes = {
        "AVCaptureSession",
        "AVCaptureVideoDataOutput",
        "AVCaptureAudioDataOutput",
        "AVCaptureVideoPreviewLayer",
        "AVCapturePhoto",
    }
    if set(app_filter.get("Classes", [])) != expected_classes:
        fail("application injection filter must remain AVFoundation-specific")
    if set(app_filter.get("Bundles", [])) != {
        "com.apple.UIKit",
        "com.apple.UIKitCore",
        "com.apple.WebKit.WebContent",
    }:
        fail("application injection filter is broader than the reviewed scope")
    system_executables = read_plist("VCMediaServer.plist").get("Filter", {}).get(
        "Executables", []
    )
    if system_executables != ["mediaserverd", "SpringBoard"]:
        fail("system binary must inject only into mediaserverd and SpringBoard")


def validate_zero_copy_bus() -> None:
    header = read_text("VCSharedMediaBus.h")
    protocol = read_text("VCSharedMediaProtocol.h")
    bus = read_text("VCSharedMediaBus.m")
    screen = read_text("VCScreenCaptureSource.m")
    local = read_text("VCLocalMediaSource.m")
    orientation = read_text("VCLocalOrientationMath.h")
    network = read_text("AVAssetStreamAdapter.m")
    network_header = read_text("AVAssetStreamAdapter.h")
    converter = read_text("VCFrameConverter.m")
    coordinator = read_text("VCStreamCoordinator.m")
    require(
        header + protocol + bus,
        (
            "VC_SHARED_VIDEO_RING_SIZE 3u",
            "VCPackSurfaceState",
            "VCRequiredCanonicalInputFrames",
            "VCRequiredStreamingCanonicalFrames",
            "VCAdvanceStreamingResamplePhase",
            "VCResolveAudioReadStart",
            "VC_SHARED_AUDIO_TARGET_LEAD_FRAMES",
            "VCSharedAudioCursor",
            "IOSurfaceGetID",
            "IOSurfaceLookup",
            "CVPixelBufferCreateWithIOSurface",
            "kIOSurfaceIsGlobal",
            "mach_continuous_time",
            "totalFramesWritten",
            "memory_order_release",
            "VCMarkSystemPipelineActivity",
            "VCSystemPipelineIsActive",
            "VCStartSharedRuntimeHeartbeat",
            "VCReportMediaServerVideoRuntimeEvent",
            "VCReportApplicationVideoRuntimeEvent",
            "VCReportProducerVideoRuntimeEvent",
            "VCSharedVideoLastFailureReason",
            "VCPackRuntimeEventState",
            "VCNotifyTokenForChannel",
            "VCShouldPublishPipelineHeartbeat",
            "VCSharedVideoControl",
            "VC_SHARED_VIDEO_CONTROL_MAGIC",
            "VCSharedTimestampIsRecent",
            "VCResolveConsumerFrameTimestamp",
            "VCNotifyCheckChanged",
            "_cachedSurfaceState",
            "_cachedPixelBuffer",
            "static _Atomic(int) tokens[VCNotifyChannelCount]",
            "A transient notifyd failure is retried at a bounded cadence",
            "atomic_load_explicit(&tokens[channel], memory_order_acquire)",
            "lastAttemptMilliseconds[VCNotifyChannelCount]",
            "IOSurfaceIncrementUseCount",
            "IOSurfaceDecrementUseCount",
            "VCReleaseSharedVideoPixelBuffer",
            "VCNotifyChannelVideoDirectState",
            "VCNotifyChannelVideoDirectTimestamp",
            "readLatestPublishedState",
            "effectiveTimestampForPublishedState",
            "_lastObservedPublicationMilliseconds",
            "runtimeAdvanced || runtimeTimestampRecent",
            "Redundant discovery path",
            "_controlRetryAfterMilliseconds",
        ),
        "shared media bus",
    )
    if "notify_cancel" in bus or bus.count("notify_post(") != 1:
        fail("shared media bus must retain tokens and post only control lifecycle events")
    if "VCNotifyChannelVideoTimestamp" in bus or \
       "VCNotifyChannelAudioTimestamp" in bus or \
       "VCShouldPublishMediaTimestamp" in protocol:
        fail("media freshness must live in shared memory instead of Darwin notify state")
    require(
        bus,
        (
            "IOSurfaceIncrementUseCount(racedSurface)",
            "IOSurfaceDecrementUseCount(surface)",
            "previous implicit lease-transfer invariant",
            "atomic_store_explicit(&_control->surfaceState",
            "atomic_load_explicit(&_control->surfaceState",
            "atomic_store_explicit(&_ring->timestampMilliseconds",
            "VCNotifyChannelVideoControl",
            "surfaceStateDue = !_surfaceStatePublished",
        ),
        "shared video lease and notify hot path",
    )
    if "NSData" in bus or "NSKeyedArchiver" in bus:
        fail("shared frame bus must not serialize media payloads")
    require(
        screen,
        (
            'dlsym(RTLD_DEFAULT,',
            '"CARenderServerRenderDisplay"',
            "CVPixelBufferPoolCreatePixelBufferWithAuxAttributes",
            "kIOSurfaceIsGlobal",
            "if (!self.renderDisplay)",
            "requestScreenGeometryRefreshIfNeeded",
            "_geometryRefreshPending",
            "_geometryRefreshCountdown == 0",
            "transient UIKit failure",
        ),
        "screen producer",
    )
    if "dispatch_sync(dispatch_get_main_queue()" in screen:
        fail("screen capture hot path must not synchronously block SpringBoard main")
    require(
        local,
        (
            "AVAssetReader",
            "AVAssetReaderTrackOutput",
            "AVSampleRateKey: @48000",
            "AVNumberOfChannelsKey: @2",
            "alwaysCopiesSampleData = NO",
            "CMTimeCompare",
            "maximumPixelDimension",
            "preferredFPS",
            "BOOL tooLate",
            "CMBlockBufferGetDataPointer",
            "VCResolveLocalTrackOrientation",
            "trackRotation",
            "trackMirrored",
            "VCLocalMediaCompletionCallback",
            "reachedNaturalEnd",
            '#import "VCMediaTrackLoader.h"',
            "VCMediaLoadTracksFromURL",
            "VCMediaTrackLoadResultCancelled",
            "if (loading && current)",
            "self.loadingAsset == observedAsset",
            "[loadingAsset cancelLoading]",
            "self.preparedAsset = asset",
            "VCMediaLoadVideoTrackGeometry",
            "![self isGenerationCurrent:generation]",
            "self.preparedTrackTransform = preferredTransform",
            "self.preparedTrackNaturalSize = naturalSize",
            "self.preparedTrackGeometryReady = geometryReady",
            "consecutiveReadFailures",
            "Retrying local media after a transient read error",
            "VCMediaWaitForRetryDelay(0.20",
        ),
        "local media producer",
    )
    if "tracksWithMediaType:" in local:
        fail("local media playback must await the shared asynchronous track loader")
    if "videoTrack.preferredTransform" in local or "videoTrack.naturalSize" in local:
        fail("local media playback must await video-track geometry before access")
    require(
        orientation,
        (
            "VCResolveLocalTrackOrientation",
            "determinant",
            "atan2",
            "fabs(angle - (double)quadrant * halfPi) > 0.02",
        ),
        "local track orientation resolver",
    )
    require(
        converter + coordinator,
        (
            "VCCopyShareablePixelBuffer",
            "VCCopyBGRAStorage(source, NO)",
            "kCVPixelBufferIOSurfacePropertiesKey",
            "kIOSurfaceIsGlobal",
            "publishPixelBuffer:shareable",
        ),
        "global producer frame copy",
    )
    require(
        coordinator,
        (
            'isEqualToString:@"SpringBoard"',
            "stopAllSourcesAndInvalidateBus",
            "publishPixelBuffer:shareable",
            "publishInterleavedStereoSamples",
            "_pendingPixelBuffer",
            "_frameProcessingScheduled",
            "sourceGenerationIsCurrent:",
            "sourceGeneration:sourceGeneration",
            "VCStreamStatusCompleted",
            "[[VCSharedAudioServer sharedServer] invalidate]",
            "_configuredHoldLastFrame",
        ),
        "single-producer coordinator",
    )
    if "producerFailedWithError:error];" in coordinator:
        fail("producer errors must be generation-gated after a source switch")
    require(
        coordinator,
        (
            "supportsDirectFallback",
            'isEqualToString:@"m3u8"',
            "stopConsumerNetworkFallback",
            "storeConsumerFallbackPixelBuffer:",
            "Consumer HLS fallback received its first frame",
            "IOSurfaceIncrementUseCount(surface)",
        ),
        "sandbox-safe consumer HLS fallback",
    )
    consumer_fallback = coordinator.split("if (!_producerProcess) {", 1)[1].split(
        "dispatch_async(dispatch_get_main_queue()", 1
    )[0]
    if "m3u8" not in consumer_fallback or "mjpg" in consumer_fallback:
        fail("consumer network fallback must remain restricted to multi-client HLS")
    require(
        network,
        (
            "CGImageSourceCreateImageAtIndex",
            "_pendingMJPEGData",
            "mjpegDecodeQueue",
            "decodePendingMJPEGFrames",
            "VCMJPEGDecompressionOutputCallback",
            "VTDecompressionSessionDecodeFrame",
            "kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder",
            "kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder",
            "copyPixelBufferFromJPEGDataUsingImageIO",
            "_mjpegSupersededFrameCount",
            "average-decode=%.2fms",
            "VCHLSInitialPollingFPS = 120",
            "VCHLSMaximumPollingFPS = 240",
            "configureHLSFrameTimerForPlayerItem",
            "_mjpegVTDisabledUntil",
            "CFAbsoluteTimeGetCurrent() + 30.0",
            "preferredForwardBufferDuration = 1.5",
            "catchUpToHLSLiveEdgeIfNeeded",
        ),
        "sender-authoritative network decoder",
    )
    require(
        network,
        (
            "loadTracksWithMediaType:AVMediaTypeVideo",
            'loadValuesAsynchronouslyForKeys:@[@"nominalFrameRate"]',
            'statusOfValueForKey:@"nominalFrameRate"',
            "item != liveSelf.hlsPlayerItem",
            "[loadingAsset cancelLoading]",
        ),
        "non-blocking HLS track metadata loading",
    )
    if "item.tracks" in network or "assetTrack.nominalFrameRate" in network:
        fail("HLS polling adaptation must not synchronously inspect track metadata")
    if "CGImageSourceCreateThumbnail" in network:
        fail("network MJPEG must not apply a phone-side thumbnail quality/orientation transform")
    if "preferredFPS" in network_header or "maximumPixelDimension" in network_header:
        fail("network decoder still exposes phone-side FPS or quality controls")
    if "self.networkSource.preferredFPS" in coordinator or \
       "self.networkSource.maximumPixelDimension" in coordinator:
        fail("coordinator still applies local FPS/quality settings to a network source")
    require(
        coordinator,
        (
            "localMediaControlsActive = sourceType == VCSourceTypeLocalMedia",
            "effectiveRotation = localMediaControlsActive ? rotation : 0",
            "effectiveMirror = localMediaControlsActive ? mirror : NO",
            "VCLocalVideoPlaylistForURL",
            "handleLocalMediaVolumeButtonDirection",
            "trackRotation + userRotation",
            "publishLocalTransformStatusReady",
            "Do not depend on this process receiving its own Darwin notification",
            "sourceRestartToken",
        ),
        "source-specific media policy",
    )


def validate_hooks_and_fail_open() -> None:
    media = read_text("MediaServer.x")
    tweak = read_text("Tweak.x")
    coordinator = read_text("VCStreamCoordinator.m")
    audio = read_text("VCAudioSampleConverter.m")
    converter = read_text("VCFrameConverter.m")
    all_source = "\n".join(
        path.read_text(encoding="utf-8", errors="replace")
        for pattern in ("*.m", "*.h", "*.x", "*.xm")
        for path in ROOT.glob(pattern)
    )
    banned = {
        "device identity spoofing": r"%hook\s+AVCaptureDevice\b",
        "Apple bundle identity spoofing": r"setBundleIdentifier|com\.apple\.[^\"\s]+\s*=",
        "anti-debugging or jailbreak hiding": r"P_TRACED|ptrace\s*\(|/Applications/Cydia\.app",
    }
    for label, pattern in banned.items():
        if re.search(pattern, all_source):
            fail(f"unexpected {label} code")
    require(
        media,
        (
            "VCMethodAcceptsSampleBuffer",
            "VCMethodReturnsBoolean",
            "objc_getClassList",
            "VCClassIsSubclassOfClass",
            "VCDirectInstanceMethod",
            "VCMediaServerRescanScheduled",
            "VCReplacedSampleAttachmentKey",
            "kCMAttachmentMode_ShouldPropagate",
            "kCVAttachmentMode_ShouldPropagate",
            "CMSampleBufferGetImageBuffer",
            "CMAudioFormatDescriptionGetStreamBasicDescription",
            "VCIsSupportedReplacementPixelFormat",
            "replacement ?: originalBuffer",
            "Depth, disparity, metadata and compressed auxiliary streams",
            "VCMarkSystemPipelineActivity(VCSharedMediaKindVideo)",
            "VCMarkSystemPipelineActivity(VCSharedMediaKindAudio)",
            "VCInstallSpringBoardVolumeHooks",
            "SBVolumeControl",
            "VCVolumeHookEntries",
            "VCVolumeEntryForInvocation",
            "VCScanKnownVolumeClasses",
            "VCScanLoadedVolumeClasses",
            "VCVolumeDirectionForSelectorName",
            "handleLocalMediaVolumeButtonDirection:direction",
            "handleLocalMediaVolumeButtonDirection:delta > 0.0 ? 1 : -1",
            "VCMethodIsVoidWithIntegerArgument",
            "VCVolumeDeltaHookKindForMethod",
            "VCVolumeHookKindDeltaFloat",
            '"_changeVolumeByDelta:"',
            '"volumeIncreasePressDownWithModifiers:"',
            "VCPackVolumeHookStatus",
            "VCVolumeHookScanComplete",
            "VCPublishVolumeHookStatus",
            "VCVolumeHookStatusToken",
            "Keep the registration alive for SpringBoard's lifetime",
            "local-volume-hook.status",
            "VCNodeOutputDispatchCache",
            "VCCachedOriginalEmitForClass",
            "VCCacheOriginalEmitForClass",
            "allowInheritedMethod",
            "continuing low-frequency scans",
            "VCMediaServerVideoRuntimeReplacementSucceeded",
            "VCTargetCaptureIsActive(3.0)",
            "hasTargetBundleFilter",
        ),
        "system hook fail-open path",
    )
    require(
        tweak,
        (
            "VCVideoDataOutputProxy",
            "VCAudioDataOutputProxy",
            "VCSampleWasReplacedBySystem",
            "Suppress only for evidence attached to this exact sample",
            "VCCopySessionCompatibilityPixelBuffer",
            "previewLayer.session",
            "copyRecentCompatibilityPixelBufferWithActivePath",
            "replacement ?: sampleBuffer",
            "VCPhotoDataPreservesAuthenticMetadata",
            "preserving the authentic original camera file",
            "semanticSegmentationMatteForType",
            "portraitEffectsMatte",
            "depthData",
            "VCCopyStablePixelBuffer",
            "replaceSharedPixelBufferLease",
            "VCReleaseSharedVideoPixelBuffer",
            "VCReportApplicationVideoRuntimeEvent",
            "VCApplicationVideoRuntimePreviewFrameDisplayed",
            "%hook AVCaptureSession",
            "%hook ARSession",
            "%hook ARFrame",
            "VCTargetCameraConsumerDidStart",
            "isCurrentProcessSelected",
        ),
        "application fallback",
    )
    if "VCSystemPipelineIsActive" in tweak:
        fail("a global pipeline heartbeat still suppresses an application fallback")
    if "copyLatestCompatibilityOutputPixelBufferWithActivePath" in coordinator:
        fail("compatibility preview state is still global instead of output/session scoped")
    springboard_guard = tweak.find('isEqualToString:@"SpringBoard"')
    springboard_return = tweak.find("return;", springboard_guard)
    if springboard_guard < 0 or springboard_return < 0:
        fail("application binary must stay inert when class filters select SpringBoard")
    require(
        audio,
        (
            "VCAudioReplacementContext",
            "VCSharedAudioCursor",
            "_canonicalAvailableFrames",
            "_sourcePhase",
            "VCRequiredStreamingCanonicalFrames",
            "VCAdvanceStreamingResamplePhase",
            "kAudioFormatLinearPCM",
            "outputFrameCount",
            "CMSampleBufferGetPresentationTimeStamp",
            "CMAudioSampleBufferCreateWithPacketDescriptions",
            "CMSampleBufferSetDataBufferFromAudioBufferList",
            "CMSampleBufferSetDataReady",
            "kAudioFormatFlagIsNonInterleaved",
            "sampleStride",
            "CMSampleBufferGetSampleAttachmentsArray",
            "return NULL",
        ),
        "audio format preservation",
    )
    require(
        converter,
        (
            "CMVideoFormatDescriptionMatchesImageBuffer",
            "VTPixelTransferSessionTransferImage",
            "CMSampleBufferGetSampleAttachmentsArray",
            "VCIsSupportedReplacementPixelFormat",
            "VCMaximumOutstandingBuffersPerFormat = 6",
            "VCCopyStablePixelBuffer",
            "VCFrameStateLock",
            "VCPixelTransferSessionLock",
            "A sibling output can finish the same conversion",
            "os_unfair_lock_trylock",
            "VCLockedCopyMostRecentConvertedFrame",
            "VCLockedStoreConvertedFrame",
            "VCMaximumConvertedFrameCacheBytes = 64 * 1024 * 1024",
            "Slow pixel transfer",
        ),
        "video format preservation",
    )
    converted_entry = re.search(
        r"typedef struct \{(?P<body>.*?)\} VCConvertedFrameEntry;",
        converter,
        re.DOTALL,
    )
    if not converted_entry or "CVPixelBufferRef sourceBuffer;" not in \
       converted_entry.group("body"):
        fail("converted-frame cache entry does not retain its source generation")


def validate_package_and_docs() -> None:
    control = read_text("control")
    require(
        control,
        (
            "Package: com.murkaska.virtualcampro",
            "Architecture: iphoneos-arm64",
            "firmware (>= 15.0)",
            "firmware (<< 16.0)",
        ),
        "Debian control",
    )
    version_match = re.search(r"(?m)^Version: ([0-9][0-9A-Za-z.+:~_-]*)$", control)
    if not version_match:
        fail("Debian control has no valid Version field")
        package_version = ""
    else:
        package_version = version_match.group(1)
    apple_relationship = re.search(
        r"(?mi)^(?:Provides|Replaces|Conflicts):\s*[^\n]*\bcom\.apple\.",
        control,
    )
    if apple_relationship:
        fail("package must not impersonate, replace, or conflict with an Apple package")

    preferences_info = read_plist("prefs/Info.plist")
    preferences_makefile = read_text("prefs/Makefile")
    if "VirtualCamPro_RESOURCE_FILES = Info.plist" not in preferences_makefile:
        fail("preference bundle must explicitly package its Info.plist")
    if package_version:
        if preferences_info.get("CFBundleShortVersionString") != package_version or \
           preferences_info.get("CFBundleVersion") != package_version:
            fail("preference bundle version does not match Debian package version")
        readme = read_text("README.md")
        changelog = read_text("CHANGELOG.md")
        if f"当前版本：`{package_version}`" not in readme:
            fail("README current version does not match Debian package version")
        if f"## {package_version}" not in changelog:
            fail("CHANGELOG has no section for the Debian package version")

    for relative in (
        "layout/DEBIAN/postinst",
        "layout/DEBIAN/postrm",
        "setup-config.sh",
        "scripts/verify_deb.sh",
    ):
        path = ROOT / relative
        if not path.is_file():
            fail(f"missing package script: {relative}")
        elif b"\r\n" in path.read_bytes():
            fail(f"package script must use LF line endings: {relative}")
    for path in list(ROOT.glob("*.md")) + list(
        (ROOT / "VirtualCamPro-Windows-Control-Center").glob("*.md")
    ):
        text = path.read_text(encoding="utf-8")
        for target in re.findall(r"\[[^\]]+\]\(([^)]+)\)", text):
            if target.startswith(("http://", "https://", "#")):
                continue
            local = target.split("#", 1)[0]
            if local and not (path.parent / local).exists():
                fail(f"broken local link in {path.name}: {target}")

    windows_config = read_text("VirtualCamPro-Windows-Control-Center/obs-vcam-config.cmd")
    windows_streamer = read_text(
        "VirtualCamPro-Windows-Control-Center/scripts/windows-vcam.ps1"
    )
    windows_deep_test = read_text(
        "VirtualCamPro-Windows-Control-Center/scripts/deep-self-test.ps1"
    )
    require(
        windows_config,
        (
            'VCAM_HLS_SEGMENT_SECONDS=0.25',
            'VCAM_HLS_LIST_SIZE=6',
            'VCAM_HLS_PRESET=ultrafast',
            'VCAM_HLS_BUFSIZE_KBPS=12000',
            'VCAM_RT_BUFFER_MB=64',
            'VCAM_THREAD_QUEUE_SIZE=4',
            'VCAM_OUTPUT_QUEUE_SIZE=3',
            'VCAM_TCP_SEND_BUFFER_MB=1',
        ),
        "Windows low-latency defaults",
    )
    require(
        windows_streamer + windows_deep_test,
        (
            '"-huffman", $MjpegHuffman',
            '$argumentText -like "*-flags`nlow_delay*"',
            '-c:v mjpeg -threads 4 -pix_fmt yuvj420p -q:v 1 -huffman optimal',
            '-fps_mode passthrough -flush_packets 1',
            'production quality/thread/Huffman profile',
        ),
        "FFmpeg 8 production MJPEG regression coverage",
    )
    if re.search(r'"-flags"\s*,\s*"low_delay"', windows_streamer):
        fail("MJPEG bridge must not apply FFmpeg's MPEG-2-only low_delay forcing flag")

    manifest_path = ROOT / "VirtualCamPro-Windows-Control-Center/standalone-manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError) as error:
        fail(f"invalid standalone manifest: {error}")
        manifest = {}
    if manifest.get("toolVersion") != package_version:
        fail("Windows companion and iOS package versions do not match")
    if manifest.get("packageIncluded") is not False:
        fail("source-tree standalone manifest must not advertise a stale bundled package")
    standalone_builder = read_text("tools/build-windows-standalone.ps1")
    if '.Replace("`r`n", "`n")' not in standalone_builder:
        fail("generated standalone manifest needs canonical LF JSON formatting")

    package_verifier = read_text("scripts/verify_deb.sh")
    require(
        package_verifier,
        (
            "dpkg-deb -f",
            "actual_version",
            "actual_architecture",
            "AVFCameraSupport.dylib",
            "VCMediaServer.dylib",
            "virtualcampro-config",
            "plistlib.load",
            "sha256sum",
        ),
        "built package verifier",
    )


def validate_jpeg_parser_tests() -> None:
    test = read_text("tests/test_jpeg_parser.c")
    require(
        test,
        (
            "testIncrementalBaselineAndEmbeddedThumbnail",
            "testProgressiveScans",
            "testInvalidStructure",
            "testConcatenatedFramesReturnOneFrameAtATime",
            "testMarkerSplitAcrossCallbacks",
            "testFrameDimensionsSurviveIncrementalParsing",
            "testInvalidFrameDimensions",
        ),
        "JPEG parser tests",
    )
    shared_test = read_text("tests/test_shared_media_protocol.c")
    require(
        shared_test,
        (
            "testSurfaceStateRoundTrip",
            "testPipelineHeartbeatRateLimit",
            "testVolumeHookStatusRoundTrip",
            "testSharedTimestampFreshness",
            "testVideoControlAtomicLayout",
            "testAudioRingWrap",
            "testAudioReadCursor",
            "testResampleInputBounds",
            "testStreamingResampleContinuity",
        ),
        "shared media protocol tests",
    )
    orientation_test = read_text("tests/test_local_orientation_math.c")
    require(
        orientation_test,
        (
            "expect_orientation(0, 1, -1, 0, 90, false)",
            "expect_orientation(0, -1, -1, 0, 90, true)",
            "arbitrary.valid",
            "NAN",
        ),
        "local orientation tests",
    )


def validate_workflows() -> None:
    workflow_paths = sorted((ROOT / ".github" / "workflows").glob("*.yml"))
    if not workflow_paths:
        fail("no GitHub Actions workflows found")
        return
    combined = ""
    for path in workflow_paths:
        text = path.read_text(encoding="utf-8")
        combined += text
        for action, revision in re.findall(r"uses:\s+([^@\s]+)@([^\s#]+)", text):
            if not re.fullmatch(r"[0-9a-f]{40}", revision):
                fail(f"workflow action is not pinned: {action}@{revision}")
    require(
        combined,
        (
            "tests/test_jpeg_parser.c",
            "tests/test_shared_media_protocol.c",
            "tests/test_local_orientation_math.c",
            "make package FINALPACKAGE=1",
            "scripts/verify_deb.sh",
            "dpkg-deb -f",
            "-fsanitize=address,undefined",
            "tools/build-windows-standalone.ps1",
            "persist-credentials: false",
            "cancel-in-progress: true",
            "5280bd038207e14f8bd76f5417aa2fe641c03228",
            "0222fd5413cf4b9af096f37b4621afa2688572f7",
            "a72a7a577e2fbe2838b6b5e9c72034fa7d114af96f0e1d4b016f18730ce4056e",
            "sha256sum --check --strict",
            "toolchain/linux/iphone/bin/clang",
            "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
            "actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
            "actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9",
            "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
            "steps.theos-cache.outputs.cache-hit != 'true'",
        ),
        "CI workflows",
    )
    windows_validation = read_text(".github/workflows/test.yml").split(
        "- name: Validate Windows source scripts", 1
    )[1].split("- name: Rebuild and verify package-free Windows companion", 1)[0]
    if windows_validation.count("if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }") < 5:
        fail("Windows source checks can still hide an earlier nonzero exit code")
    attributes = read_text(".gitattributes")
    if "VirtualCamPro-Windows-Control-Center/** -text" not in attributes:
        fail("Windows standalone manifest inputs need byte-stable checkout behavior")


def main() -> int:
    validate_plists()
    validate_makefile()
    validate_preferences()
    validate_injection_filters()
    validate_zero_copy_bus()
    validate_hooks_and_fail_open()
    validate_package_and_docs()
    validate_jpeg_parser_tests()
    validate_workflows()
    if ERRORS:
        for error in ERRORS:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("VirtualCamPro unified-pipeline validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
