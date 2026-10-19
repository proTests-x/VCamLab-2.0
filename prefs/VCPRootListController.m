#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <AVFoundation/AVFoundation.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <UIKit/UIKit.h>
#import <limits.h>
#import <mach/mach_time.h>
#import <math.h>
#import <notify.h>
#import <os/lock.h>

#import "VCPApplicationSelectorController.h"
#import "../VCJPEGParser.h"
#import "../VCMediaTrackLoader.h"
#import "../VCPreferenceValidation.h"
#import "../VCSharedMediaProtocol.h"

@interface VCPreferences : NSObject
+ (instancetype)sharedPreferences;
- (BOOL)reload;
- (void)publishSharedConfiguration;
@end

static CFStringRef const VCPreferencesChangedNotification = CFSTR("com.murkaska.virtualcampro/preferences.changed");
static CFStringRef const VCPreferencesDomain = CFSTR("com.murkaska.virtualcampro");
static CFStringRef const VCLocalMediaPathKey = CFSTR("localMediaPath");
static CFStringRef const VCSourceRestartTokenKey = CFSTR("sourceRestartToken");
static NSString * const VCLocalMediaDirectory = @"/var/mobile/Media/VirtualCamPro";
static NSString * const VCLocalMediaImportErrorDomain = @"com.murkaska.virtualcampro.media-import";
static const unsigned long long VCLocalMediaReserveBytes = 64ULL * 1024ULL * 1024ULL;
static const NSUInteger VCPStreamTestMaximumBytes = 8 * 1024 * 1024;

typedef NS_ENUM(NSUInteger, VCPNotifyChannel) {
    VCPNotifyChannelStreamStatus = 0,
    VCPNotifyChannelLocalTransform,
    VCPNotifyChannelLocalVolumeHook,
    VCPNotifyChannelVideoPipeline,
    VCPNotifyChannelSpringBoardRuntime,
    VCPNotifyChannelMediaServerRuntime,
    VCPNotifyChannelMediaServerVideoRuntime,
    VCPNotifyChannelApplicationVideoRuntime,
    VCPNotifyChannelProducerVideoRuntime,
    VCPNotifyChannelCount,
};

static const char *VCPNotifyChannelNames[VCPNotifyChannelCount] = {
    [VCPNotifyChannelStreamStatus] =
        "com.murkaska.virtualcampro/stream.status",
    [VCPNotifyChannelLocalTransform] =
        "com.murkaska.virtualcampro/local-transform.status",
    [VCPNotifyChannelLocalVolumeHook] =
        "com.murkaska.virtualcampro/local-volume-hook.status",
    [VCPNotifyChannelVideoPipeline] =
        "com.murkaska.virtualcampro/pipeline.video.heartbeat.v1",
    [VCPNotifyChannelSpringBoardRuntime] =
        "com.murkaska.virtualcampro/runtime.springboard.heartbeat.v1",
    [VCPNotifyChannelMediaServerRuntime] =
        "com.murkaska.virtualcampro/runtime.mediaserverd.heartbeat.v1",
    [VCPNotifyChannelMediaServerVideoRuntime] =
        "com.murkaska.virtualcampro/runtime.mediaserverd.video.v1",
    [VCPNotifyChannelApplicationVideoRuntime] =
        "com.murkaska.virtualcampro/runtime.application.video.v1",
    [VCPNotifyChannelProducerVideoRuntime] =
        "com.murkaska.virtualcampro/runtime.springboard.video.v1",
};

static BOOL VCPGetNotifyChannelState(VCPNotifyChannel channel,
                                     uint64_t *stateOut);
static uint64_t VCPMonotonicMilliseconds(void);

static BOOL VCPRuntimeTimestampAge(uint64_t timestamp,
                                   uint64_t *ageMillisecondsOut) {
    if (ageMillisecondsOut) *ageMillisecondsOut = UINT64_MAX;
    if (timestamp == 0) return NO;
    uint64_t now = VCPMonotonicMilliseconds();
    if (now < timestamp) return NO;
    if (ageMillisecondsOut) *ageMillisecondsOut = now - timestamp;
    return YES;
}

static NSString *VCPRuntimeHeartbeatDescription(VCPNotifyChannel channel,
                                                 NSString *processName) {
    uint64_t timestamp = 0;
    uint64_t age = UINT64_MAX;
    if (!VCPGetNotifyChannelState(channel, &timestamp) ||
        !VCPRuntimeTimestampAge(timestamp, &age)) {
        return [NSString stringWithFormat:@"%@ no está inyectado / sin señal de actividad", processName];
    }
    if (age > VC_RUNTIME_HEARTBEAT_MAX_AGE_MS) {
        return [NSString stringWithFormat:@"%@ sin conexión (estado anterior de %@ ms)",
                                          processName, @(age)];
    }
    return [NSString stringWithFormat:@"%@ activo (%@ ms)", processName, @(age)];
}

static NSString *VCPSharedVideoFailureDescription(uint8_t detail) {
    switch ((VCSharedVideoFailureReason)detail) {
        case VCSharedVideoFailureControlStateUnavailable:
            return @"No se puede leer el estado del canal de control";
        case VCSharedVideoFailureControlSurfaceLookup:
            return @"No se pudo mapear el IOSurface de control";
        case VCSharedVideoFailureControlSurfaceInvalid:
            return @"El contenido del IOSurface de control no es válido";
        case VCSharedVideoFailureDirectStateUnavailable:
            return @"No están disponibles el estado de fotograma directo ni el canal de control";
        case VCSharedVideoFailureNoPublishedFrame:
            return @"El productor aún no ha publicado un fotograma compartido";
        case VCSharedVideoFailureFrameStale:
            return @"El fotograma compartido ha caducado";
        case VCSharedVideoFailureFrameSurfaceLookup:
            return @"No se pudo mapear el IOSurface del fotograma entre procesos";
        case VCSharedVideoFailurePixelBufferWrap:
            return @"No se pudo convertir el IOSurface en un búfer de píxeles";
        case VCSharedVideoFailurePublicationRace:
            return @"Conflicto continuo de publicación; se agotaron los reintentos seguros";
        default:
            return @"No se proporcionó un código de error interno";
    }
}

static NSString *VCPMediaServerVideoRuntimeDescription(uint64_t state) {
    VCMediaServerVideoRuntimeEvent event =
        (VCMediaServerVideoRuntimeEvent)VCEventFromRuntimeState(state);
    uint8_t detail = VCDetailFromRuntimeState(state);
    uint64_t timestamp = VCTimestampFromRuntimeState(state);
    uint64_t age = UINT64_MAX;
    NSString *ageText = VCPRuntimeTimestampAge(timestamp, &age)
        ? [NSString stringWithFormat:@"hace %@ ms", @(age)]
        : @"Hora no disponible";
    switch (event) {
        case VCMediaServerVideoRuntimeInjected:
            return [NSString stringWithFormat:@"Inyectado; esperando análisis (%@)", ageText];
        case VCMediaServerVideoRuntimeScanning:
            return [NSString stringWithFormat:@"Analizando; reintento consecutivo %@ (%@)",
                                              @(detail), ageText];
        case VCMediaServerVideoRuntimeHookInstalled:
            return [NSString stringWithFormat:@"Hook instalado: %@ clases (%@)",
                                              @(detail), ageText];
        case VCMediaServerVideoRuntimeNodeClassUnavailable:
            return [NSString stringWithFormat:@"No se encontró BWNodeOutput (%@)", ageText];
        case VCMediaServerVideoRuntimeIncompatibleSignature:
            return [NSString stringWithFormat:@"Firma de emitSampleBuffer: incompatible (%@)",
                                              ageText];
        case VCMediaServerVideoRuntimeHookCapacityExceeded:
            return [NSString stringWithFormat:@"La cantidad de hooks supera el límite seguro (%@)", ageText];
        case VCMediaServerVideoRuntimeSampleObserved:
            return [NSString stringWithFormat:@"Se recibió una muestra de video de la cámara del sistema (%@)", ageText];
        case VCMediaServerVideoRuntimeSourceUnavailable:
            return [NSString stringWithFormat:
                @"Llegó una muestra de cámara, pero la fuente compartida no está visible: %@ (%@)",
                VCPSharedVideoFailureDescription(detail),
                ageText];
        case VCMediaServerVideoRuntimeUnsupportedPixelFormat:
            return [NSString stringWithFormat:@"El formato de píxeles de la cámara no es compatible (%@)", ageText];
        case VCMediaServerVideoRuntimeConversionFailed:
            return [NSString stringWithFormat:@"Falló la conversión del fotograma de reemplazo (%@)", ageText];
        case VCMediaServerVideoRuntimeReplacementSucceeded:
            return [NSString stringWithFormat:@"El reemplazo más reciente del sistema se completó (%@)", ageText];
        default:
            return @"Aún no hay datos de la etapa de video de mediaserverd";
    }
}

static NSString *VCPCurrentMediaServerVideoRuntimeDescription(void) {
    uint64_t runtimeState = 0;
    if (!VCPGetNotifyChannelState(VCPNotifyChannelMediaServerVideoRuntime,
                                  &runtimeState)) {
        return @"No se pudo leer el estado";
    }
    NSString *stage = VCPMediaServerVideoRuntimeDescription(runtimeState);
    uint64_t heartbeat = 0;
    uint64_t heartbeatAge = UINT64_MAX;
    if (!VCPGetNotifyChannelState(VCPNotifyChannelMediaServerRuntime,
                                  &heartbeat) ||
        !VCPRuntimeTimestampAge(heartbeat, &heartbeatAge) ||
        heartbeatAge > VC_RUNTIME_HEARTBEAT_MAX_AGE_MS) {
        return [NSString stringWithFormat:@"Estado anterior; el proceso actual no tiene señal de actividad: %@",
                                          stage];
    }
    return stage;
}

static NSString *VCPApplicationVideoRuntimeDescription(uint64_t state) {
    VCApplicationVideoRuntimeEvent event =
        (VCApplicationVideoRuntimeEvent)VCEventFromRuntimeState(state);
    uint64_t age = UINT64_MAX;
    NSString *ageText = VCPRuntimeTimestampAge(VCTimestampFromRuntimeState(state),
                                               &age)
        ? [NSString stringWithFormat:@"hace %@ ms", @(age)]
        : @"Hora no disponible";
    switch (event) {
        case VCApplicationVideoRuntimeInjected:
            return [NSString stringWithFormat:@"Plugin de la aplicación cargado (%@)", ageText];
        case VCApplicationVideoRuntimeDelegateWrapped:
            return [NSString stringWithFormat:@"El proxy de salida de video tomó el control (%@)", ageText];
        case VCApplicationVideoRuntimeSystemReplacementObserved:
            return [NSString stringWithFormat:@"La aplicación recibió una muestra reemplazada por el sistema (%@)", ageText];
        case VCApplicationVideoRuntimeSourceUnavailable:
            return [NSString stringWithFormat:
                @"Llegó la devolución de video, pero la fuente compartida no está visible: %@ (%@)",
                VCPSharedVideoFailureDescription(VCDetailFromRuntimeState(state)),
                ageText];
        case VCApplicationVideoRuntimeConversionFailed:
            return [NSString stringWithFormat:@"Falló la conversión de video en la aplicación (%@)", ageText];
        case VCApplicationVideoRuntimeReplacementSucceeded:
            return [NSString stringWithFormat:@"La muestra de video se reemplazó en la aplicación (%@)", ageText];
        case VCApplicationVideoRuntimePreviewOverlayInstalled:
            return [NSString stringWithFormat:@"Capa de reemplazo de vista previa instalada (%@)", ageText];
        case VCApplicationVideoRuntimePreviewSourceUnavailable:
            return [NSString stringWithFormat:@"La capa de vista previa está activa, pero el fotograma de reemplazo no está visible: %@ (%@)",
                                              VCPSharedVideoFailureDescription(
                                                  VCDetailFromRuntimeState(state)),
                                              ageText];
        case VCApplicationVideoRuntimePreviewFrameDisplayed:
            return [NSString stringWithFormat:@"La vista previa de la aplicación mostró el fotograma de reemplazo (%@)", ageText];
        case VCApplicationVideoRuntimePhotoReplacementSucceeded:
            return [NSString stringWithFormat:@"Los datos de la foto se reemplazaron correctamente (%@)", ageText];
        case VCApplicationVideoRuntimePhotoReplacementFailed:
            return [NSString stringWithFormat:@"Falló el reemplazo de la foto; se conservó la original (%@)", ageText];
        default:
            return @"Aún no hay actividad del hook de AVFoundation en la aplicación; abre primero una aplicación de cámara";
    }
}

static NSString *VCPProducerVideoRuntimeDescription(uint64_t state) {
    VCProducerVideoRuntimeEvent event =
        (VCProducerVideoRuntimeEvent)VCEventFromRuntimeState(state);
    uint64_t age = UINT64_MAX;
    NSString *ageText = VCPRuntimeTimestampAge(VCTimestampFromRuntimeState(state),
                                               &age)
        ? [NSString stringWithFormat:@"hace %@ ms", @(age)]
        : @"Hora no disponible";
    switch (event) {
        case VCProducerVideoRuntimeNoIOSurface:
            return [NSString stringWithFormat:@"El fotograma producido no tiene IOSurface (%@)", ageText];
        case VCProducerVideoRuntimeSurfaceIDUnavailable:
            return [NSString stringWithFormat:@"El fotograma producido no tiene un Surface ID global (%@)", ageText];
        case VCProducerVideoRuntimeControlSurfaceUnavailable:
            return [NSString stringWithFormat:@"No se pudo crear el IOSurface de control (%@)", ageText];
        case VCProducerVideoRuntimeControlStatePublishFailed:
            return [NSString stringWithFormat:@"No se pudo publicar el estado de control (%@)", ageText];
        case VCProducerVideoRuntimeDirectStatePublishFailed:
            return [NSString stringWithFormat:@"No se pudo publicar el estado del fotograma directo (%@)", ageText];
        case VCProducerVideoRuntimePublishedControlAndDirect:
            return [NSString stringWithFormat:@"Se publicaron el plano de control y el canal de fotograma directo (%@)", ageText];
        case VCProducerVideoRuntimePublishedDirectFallback:
            return [NSString stringWithFormat:@"Canal de fotograma directo publicado; plano de control no disponible (%@)",
                                              ageText];
        case VCProducerVideoRuntimePublishedControlOnly:
            return [NSString stringWithFormat:@"Plano de control publicado; falló el canal directo redundante (%@)",
                                              ageText];
        default:
            return @"Aún no hay estado de publicación de video compartido de SpringBoard";
    }
}

typedef NS_ENUM(uint64_t, VCPStreamStatus) {
    VCPStreamStatusDisabled = 0,
    VCPStreamStatusConnecting = 1,
    VCPStreamStatusReceiving = 2,
    VCPStreamStatusError = 3,
    VCPStreamStatusHoldingLastFrame = 4,
    VCPStreamStatusCompleted = 5,
};

typedef NS_ENUM(NSInteger, VCLocalMediaImportError) {
    VCLocalMediaImportErrorInvalidSource = 1,
    VCLocalMediaImportErrorCreateDirectory = 2,
    VCLocalMediaImportErrorReadSource = 3,
    VCLocalMediaImportErrorInsufficientSpace = 4,
    VCLocalMediaImportErrorCopy = 5,
    VCLocalMediaImportErrorUnsupportedMedia = 6,
    VCLocalMediaImportErrorFinalize = 7,
    VCLocalMediaImportErrorTrackLoading = 8,
    VCLocalMediaImportErrorTrackLoadingTimeout = 9,
};

static const NSTimeInterval VCLocalMediaTrackLoadingTimeout = 30.0;

static NSError *VCLocalMediaError(VCLocalMediaImportError code,
                                  NSString *message,
                                  NSError *underlyingError) {
    NSMutableDictionary *userInfo = [@{NSLocalizedDescriptionKey: message ?: @"No se pudo importar el contenido multimedia."}
                                      mutableCopy];
    if (underlyingError) userInfo[NSUnderlyingErrorKey] = underlyingError;
    return [NSError errorWithDomain:VCLocalMediaImportErrorDomain code:code userInfo:userInfo];
}

static BOOL VCIsPlausibleLocalMediaExtension(NSString *extension) {
    if (extension.length == 0 || extension.length > 16) return NO;
    static NSCharacterSet *invalidExtensionCharacters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        invalidExtensionCharacters =
            NSCharacterSet.alphanumericCharacterSet.invertedSet;
    });
    return [extension rangeOfCharacterFromSet:invalidExtensionCharacters].location ==
        NSNotFound;
}

static BOOL VCIsKnownLocalMediaExtension(NSString *extension) {
    static NSSet<NSString *> *knownExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        knownExtensions = [NSSet setWithArray:@[
            @"mp4", @"mov", @"m4v", @"3gp", @"3g2", @"avi",
            @"mpg", @"mpeg", @"ts", @"mts", @"m2ts",
            @"mp3", @"m4a", @"aac", @"wav", @"aif", @"aiff",
            @"caf", @"flac",
        ]];
    });
    return [knownExtensions containsObject:extension.lowercaseString];
}

static NSString *VCPreferredLocalMediaExtension(NSURL *sourceURL,
                                                 BOOL requiresVideoTrack) {
    UTType *contentType = nil;
    [sourceURL getResourceValue:&contentType forKey:NSURLContentTypeKey error:nil];
    NSString *extension = contentType.preferredFilenameExtension.lowercaseString;
    if (VCIsPlausibleLocalMediaExtension(extension)) return extension;

    extension = sourceURL.pathExtension.lowercaseString;
    if (VCIsPlausibleLocalMediaExtension(extension)) return extension;
    return requiresVideoTrack ? @"mov" : nil;
}

static NSString *VCSafeLocalMediaFilename(NSURL *sourceURL,
                                           NSString *suggestedName,
                                           BOOL requiresVideoTrack) {
    NSString *filename = suggestedName.lastPathComponent;
    if (filename.length == 0) filename = sourceURL.lastPathComponent;
    if (filename.length == 0) filename = @"media.mov";
    NSMutableCharacterSet *invalidCharacters =
        [NSCharacterSet.controlCharacterSet mutableCopy];
    [invalidCharacters addCharactersInString:@"/\\:"];
    filename = [[filename componentsSeparatedByCharactersInSet:invalidCharacters]
        componentsJoinedByString:@"_"];
    filename = [filename stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (filename.length == 0 || [filename isEqualToString:@"."] ||
        [filename isEqualToString:@".."]) {
        filename = @"media.mov";
    }
    if (!VCIsKnownLocalMediaExtension(filename.pathExtension)) {
        NSString *extension = VCPreferredLocalMediaExtension(sourceURL,
                                                              requiresVideoTrack);
        if (extension.length > 0) {
            filename = [filename stringByAppendingPathExtension:extension];
        }
    }
    return filename;
}

static NSString *VCPDisplaySafeFilename(NSString *filename) {
    if (![filename isKindOfClass:NSString.class] || filename.length == 0) {
        return @"Contenido sin nombre";
    }
    NSArray<NSString *> *parts = [filename componentsSeparatedByCharactersInSet:
        NSCharacterSet.controlCharacterSet];
    NSString *safe = [[parts componentsJoinedByString:@" "]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return safe.length > 0 ? safe : @"Contenido sin nombre";
}

static NSURL *VCUniqueLocalMediaDestination(NSString *directory, NSString *filename) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *extension = filename.pathExtension;
    NSString *stem = filename.stringByDeletingPathExtension;
    for (NSUInteger index = 0; index < 1000; index++) {
        NSString *candidateName = filename;
        if (index > 0) {
            NSString *suffix = [NSString stringWithFormat:@"-%lu", (unsigned long)(index + 1)];
            candidateName = extension.length > 0
                ? [NSString stringWithFormat:@"%@%@.%@", stem, suffix, extension]
                : [stem stringByAppendingString:suffix];
        }
        NSString *candidatePath = [directory stringByAppendingPathComponent:candidateName];
        if (![fileManager fileExistsAtPath:candidatePath]) {
            return [NSURL fileURLWithPath:candidatePath isDirectory:NO];
        }
    }
    NSString *fallbackName = extension.length > 0
        ? [NSString stringWithFormat:@"%@-%@.%@", stem, NSUUID.UUID.UUIDString, extension]
        : [NSString stringWithFormat:@"%@-%@", stem, NSUUID.UUID.UUIDString];
    return [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:fallbackName]
                     isDirectory:NO];
}

static BOOL VCAssetContainsRecognizableMediaTracks(NSURL *url,
                                                    BOOL requiresVideoTrack,
                                                    NSError **errorOut) {
    NSArray<AVAssetTrack *> *videoTracks = nil;
    NSArray<AVAssetTrack *> *audioTracks = nil;
    NSError *loadingError = nil;
    VCMediaTrackLoadResult result = VCMediaLoadTracksFromURL(
        url,
        @{AVURLAssetPreferPreciseDurationAndTimingKey: @NO},
        VCLocalMediaTrackLoadingTimeout,
        2,
        nil,
        nil,
        nil,
        &videoTracks,
        &audioTracks,
        &loadingError);
    if (result == VCMediaTrackLoadResultTimedOut) {
        if (errorOut) {
            *errorOut = VCLocalMediaError(
                VCLocalMediaImportErrorTrackLoadingTimeout,
                @"Se agotó el tiempo para leer las pistas. Si el video está en iCloud, espera a que termine la descarga e inténtalo de nuevo.",
                nil);
        }
        return NO;
    }
    if (result == VCMediaTrackLoadResultFailed) {
        if (errorOut) {
            NSString *message = [NSString stringWithFormat:
                @"AVFoundation no puede leer las pistas del archivo seleccionado: %@",
                loadingError.localizedDescription ?: @"Error de análisis desconocido"];
            *errorOut = VCLocalMediaError(
                VCLocalMediaImportErrorTrackLoading,
                message,
                loadingError);
        }
        return NO;
    }
    if (requiresVideoTrack && videoTracks.count == 0) {
        if (errorOut) {
            *errorOut = VCLocalMediaError(
                VCLocalMediaImportErrorUnsupportedMedia,
                @"El archivo devuelto por Fotos no contiene una pista de video legible. Descarga el video original en Fotos e inténtalo de nuevo.",
                nil);
        }
        return NO;
    }
    if (videoTracks.count > 0 || audioTracks.count > 0) return YES;
    if (errorOut) {
        *errorOut = VCLocalMediaError(
            VCLocalMediaImportErrorUnsupportedMedia,
            @"El archivo se leyó por completo, pero no contiene pistas de video ni audio. Usa MP4/MOV (H.264/HEVC) o M4A/MP3.",
            nil);
    }
    return NO;
}

static NSURL *VCImportLocalMediaURL(NSURL *sourceURL,
                                    NSString *suggestedName,
                                    BOOL stopSecurityScopedAccess,
                                    BOOL requiresVideoTrack,
                                    NSError **errorOut) {
    if (!sourceURL.isFileURL || sourceURL.path.length == 0) {
        if (errorOut) {
            *errorOut = VCLocalMediaError(VCLocalMediaImportErrorInvalidSource,
                                          @"La selección no es un archivo local legible.", nil);
        }
        if (stopSecurityScopedAccess) [sourceURL stopAccessingSecurityScopedResource];
        return nil;
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSError *directoryError = nil;
    if (![fileManager createDirectoryAtPath:VCLocalMediaDirectory
                withIntermediateDirectories:YES
                                 attributes:@{NSFileProtectionKey:
                                     NSFileProtectionCompleteUntilFirstUserAuthentication}
                                      error:&directoryError]) {
        if (errorOut) {
            *errorOut = VCLocalMediaError(VCLocalMediaImportErrorCreateDirectory,
                                          @"No se pudo crear el directorio permanente para contenido multimedia.", directoryError);
        }
        if (stopSecurityScopedAccess) [sourceURL stopAccessingSecurityScopedResource];
        return nil;
    }

    NSString *filename = VCSafeLocalMediaFilename(sourceURL,
                                                   suggestedName,
                                                   requiresVideoTrack);
    NSString *extension = filename.pathExtension;
    NSString *stagingName = extension.length > 0
        ? [NSString stringWithFormat:@".%@.importing.%@", NSUUID.UUID.UUIDString, extension]
        : [NSString stringWithFormat:@".%@.importing", NSUUID.UUID.UUIDString];
    NSURL *stagingURL = [NSURL fileURLWithPath:
        [VCLocalMediaDirectory stringByAppendingPathComponent:stagingName]];
    NSURL *destinationURL = VCUniqueLocalMediaDestination(VCLocalMediaDirectory, filename);

    __block NSError *accessError = nil;
    __block BOOL copied = NO;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    NSError *coordinationError = nil;
    [coordinator coordinateReadingItemAtURL:sourceURL
                                    options:0
                                      error:&coordinationError
                                 byAccessor:^(NSURL *coordinatedURL) {
        NSDictionary *attributes = [fileManager attributesOfItemAtPath:coordinatedURL.path
                                                                  error:&accessError];
        if (!attributes) return;
        if (![attributes[NSFileType] isEqual:NSFileTypeRegular]) {
            accessError = VCLocalMediaError(VCLocalMediaImportErrorReadSource,
                                            @"El elemento seleccionado no es un archivo multimedia normal.", nil);
            return;
        }
        unsigned long long sourceSize = [attributes[NSFileSize] unsignedLongLongValue];
        if (sourceSize == 0) {
            accessError = VCLocalMediaError(VCLocalMediaImportErrorReadSource,
                                            @"El archivo multimedia seleccionado está vacío.", nil);
            return;
        }
        NSDictionary *fileSystem =
            [fileManager attributesOfFileSystemForPath:VCLocalMediaDirectory error:&accessError];
        if (!fileSystem) return;
        unsigned long long freeBytes = [fileSystem[NSFileSystemFreeSize] unsignedLongLongValue];
        unsigned long long requiredBytes = sourceSize > ULLONG_MAX - VCLocalMediaReserveBytes
            ? ULLONG_MAX : sourceSize + VCLocalMediaReserveBytes;
        if (freeBytes < requiredBytes) {
            accessError = VCLocalMediaError(VCLocalMediaImportErrorInsufficientSpace,
                [NSString stringWithFormat:@"Espacio insuficiente: se necesitan al menos %.1f MiB disponibles (incluido el margen de seguridad).",
                    (double)requiredBytes / (1024.0 * 1024.0)], nil);
            return;
        }
        copied = [fileManager copyItemAtURL:coordinatedURL toURL:stagingURL error:&accessError];
    }];
    if (stopSecurityScopedAccess) [sourceURL stopAccessingSecurityScopedResource];

    NSError *finalError = accessError ?: coordinationError;
    if (!copied || finalError) {
        [fileManager removeItemAtURL:stagingURL error:nil];
        if (errorOut) {
            *errorOut = VCLocalMediaError(VCLocalMediaImportErrorCopy,
                                          @"No se pudo copiar el contenido al directorio permanente.", finalError);
        }
        return nil;
    }

    NSError *trackLoadingError = nil;
    if (!VCAssetContainsRecognizableMediaTracks(stagingURL,
                                                requiresVideoTrack,
                                                &trackLoadingError)) {
        [fileManager removeItemAtURL:stagingURL error:nil];
        if (errorOut) *errorOut = trackLoadingError;
        return nil;
    }

    NSError *moveError = nil;
    if (![fileManager moveItemAtURL:stagingURL toURL:destinationURL error:&moveError]) {
        [fileManager removeItemAtURL:stagingURL error:nil];
        if (errorOut) {
            *errorOut = VCLocalMediaError(VCLocalMediaImportErrorFinalize,
                                          @"El contenido se verificó, pero no se pudo completar el guardado atómico.", moveError);
        }
        return nil;
    }
    [fileManager setAttributes:@{NSFileProtectionKey:
        NSFileProtectionCompleteUntilFirstUserAuthentication}
                         ofItemAtPath:destinationURL.path error:nil];
    return destinationURL;
}

static BOOL VCPGetSystemStreamStatus(uint64_t *statusOut) {
    return VCPGetNotifyChannelState(VCPNotifyChannelStreamStatus, statusOut);
}

static uint64_t VCPMonotonicMilliseconds(void) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ mach_timebase_info(&timebase); });
    uint64_t ticks = mach_continuous_time();
    long double nanos = ((long double)ticks * timebase.numer) / timebase.denom;
    return (uint64_t)(nanos / 1000000.0L);
}

static int VCPNotifyTokenForChannel(VCPNotifyChannel channel) {
    static dispatch_once_t onceToken;
    static int tokens[VCPNotifyChannelCount];
    static uint64_t lastAttemptMilliseconds[VCPNotifyChannelCount];
    static os_unfair_lock tokenLock = OS_UNFAIR_LOCK_INIT;
    dispatch_once(&onceToken, ^{
        for (NSUInteger index = 0; index < VCPNotifyChannelCount; index++) {
            tokens[index] = -1;
        }
    });
    if (channel >= VCPNotifyChannelCount) return -1;

    os_unfair_lock_lock(&tokenLock);
    int token = tokens[channel];
    uint64_t now = VCPMonotonicMilliseconds();
    uint64_t lastAttempt = lastAttemptMilliseconds[channel];
    BOOL retryDue = lastAttempt == 0 || now < lastAttempt ||
                    now - lastAttempt >= 5000;
    if (token < 0 && retryDue) {
        lastAttemptMilliseconds[channel] = now;
        int candidate = -1;
        if (notify_register_check(VCPNotifyChannelNames[channel], &candidate) ==
            NOTIFY_STATUS_OK) {
            tokens[channel] = candidate;
            token = candidate;
        }
    }
    os_unfair_lock_unlock(&tokenLock);
    return token;
}

static BOOL VCPGetNotifyChannelState(VCPNotifyChannel channel,
                                     uint64_t *stateOut) {
    if (!stateOut) return NO;
    int token = VCPNotifyTokenForChannel(channel);
    return token >= 0 && notify_get_state(token, stateOut) == NOTIFY_STATUS_OK;
}

static BOOL VCPReadFinitePreferenceNumber(id value, double *numberOut) {
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

static NSInteger VCPReadIntegerPreference(id value,
                                          NSInteger minimum,
                                          NSInteger maximum,
                                          NSInteger defaultValue) {
    double number = 0;
    int64_t integer = 0;
    return VCPReadFinitePreferenceNumber(value, &number) &&
           VCPreferenceValidateInteger(number, minimum, maximum, &integer)
        ? (NSInteger)integer : defaultValue;
}

static double VCPReadRealPreference(id value,
                                    double minimum,
                                    double maximum,
                                    double defaultValue) {
    double number = 0;
    double normalized = 0;
    return VCPReadFinitePreferenceNumber(value, &number) &&
           VCPreferenceValidateReal(number, minimum, maximum, &normalized)
        ? normalized : defaultValue;
}

static BOOL VCPReadBooleanPreference(id value, BOOL defaultValue) {
    if (![value isKindOfClass:NSNumber.class] &&
        ![value isKindOfClass:NSString.class]) {
        return defaultValue;
    }
    if ([value isKindOfClass:NSString.class] && [value length] > 16) {
        return defaultValue;
    }
    return [value boolValue];
}

static BOOL VCPSetPreferenceValueIfDifferent(CFStringRef key, id value) {
    id current = CFBridgingRelease(CFPreferencesCopyAppValue(key,
                                                             VCPreferencesDomain));
    if ((current == value) || [current isEqual:value]) return NO;
    CFPreferencesSetAppValue(key, (__bridge CFPropertyListRef)value,
                             VCPreferencesDomain);
    return YES;
}

static BOOL VCPRepairStoredPreferences(void) {
    __block BOOL changed = NO;
    NSArray<NSDictionary *> *integerRules = @[
        @{ @"key": @"sourceType", @"default": @0,
           @"minimum": @0, @"maximum": @2,
           @"allowed": @[@0, @1, @2] },
        @{ @"key": @"preferredFPS", @"default": @60,
           @"minimum": @1, @"maximum": @240 },
        @{ @"key": @"sourceRotation", @"default": @0,
           @"minimum": @0, @"maximum": @270,
           @"allowed": @[@0, @90, @180, @270] },
        @{ @"key": @"maximumPixelDimension", @"default": @1920,
           @"minimum": @1280, @"maximum": @3840,
           @"allowed": @[@1280, @1920, @2560, @3840] },
    ];
    for (NSDictionary *rule in integerRules) {
        NSString *key = rule[@"key"];
        id value = CFBridgingRelease(CFPreferencesCopyAppValue(
            (__bridge CFStringRef)key, VCPreferencesDomain));
        double number = 0;
        int64_t integer64 = 0;
        BOOL valid = VCPReadFinitePreferenceNumber(value, &number) &&
                     VCPreferenceValidateInteger(
                         number,
                         [rule[@"minimum"] longLongValue],
                         [rule[@"maximum"] longLongValue],
                         &integer64);
        NSInteger integer = valid ? (NSInteger)integer64 : 0;
        NSArray<NSNumber *> *allowed = rule[@"allowed"];
        if (valid && allowed) valid = [allowed containsObject:@(integer)];
        NSNumber *normalized = valid ? @(integer) : rule[@"default"];
        changed |= VCPSetPreferenceValueIfDifferent(
            (__bridge CFStringRef)key, normalized);
    }

    NSArray<NSDictionary *> *realRules = @[
        @{ @"key": @"jpegQuality", @"default": @1.0,
           @"minimum": @0.5, @"maximum": @1.0 },
        @{ @"key": @"staleFrameTimeout", @"default": @8.0,
           @"minimum": @2.0, @"maximum": @30.0 },
    ];
    for (NSDictionary *rule in realRules) {
        NSString *key = rule[@"key"];
        id value = CFBridgingRelease(CFPreferencesCopyAppValue(
            (__bridge CFStringRef)key, VCPreferencesDomain));
        double number = 0;
        double normalizedNumber = 0;
        BOOL valid = VCPReadFinitePreferenceNumber(value, &number) &&
                     VCPreferenceValidateReal(
                         number,
                         [rule[@"minimum"] doubleValue],
                         [rule[@"maximum"] doubleValue],
                         &normalizedNumber);
        NSNumber *normalized = valid ? @(normalizedNumber) : rule[@"default"];
        changed |= VCPSetPreferenceValueIfDifferent(
            (__bridge CFStringRef)key, normalized);
    }

    NSDictionary<NSString *, NSNumber *> *booleanDefaults = @{
        @"enabled": @NO,
        @"floatingControlEnabled": @YES,
        @"loopLocalMedia": @YES,
        @"mirrorSource": @NO,
        @"aspectFill": @YES,
        @"holdLastFrame": @YES,
    };
    [booleanDefaults enumerateKeysAndObjectsUsingBlock:^(
        NSString *key, NSNumber *defaultValue, __unused BOOL *stop) {
        id value = CFBridgingRelease(CFPreferencesCopyAppValue(
            (__bridge CFStringRef)key, VCPreferencesDomain));
        NSNumber *normalized = nil;
        if ([value isKindOfClass:NSNumber.class] ||
            [value isKindOfClass:NSString.class]) {
            normalized = @(VCPReadBooleanPreference(value,
                                                     defaultValue.boolValue));
        } else {
            normalized = defaultValue;
        }
        changed |= VCPSetPreferenceValueIfDifferent(
            (__bridge CFStringRef)key, normalized);
    }];

    NSDictionary<NSString *, NSDictionary *> *stringRules = @{
        @"streamURL": @{ @"default": @"", @"maximumLength": @4096 },
        @"localMediaPath": @{ @"default": @"", @"maximumLength": @4096 },
        @"sourceRestartToken": @{ @"default": @"", @"maximumLength": @128 },
    };
    [stringRules enumerateKeysAndObjectsUsingBlock:^(
        NSString *key, NSDictionary *rule, __unused BOOL *stop) {
        id value = CFBridgingRelease(CFPreferencesCopyAppValue(
            (__bridge CFStringRef)key, VCPreferencesDomain));
        NSUInteger maximumLength = [rule[@"maximumLength"] unsignedIntegerValue];
        NSString *normalized = [value isKindOfClass:NSString.class] &&
                               [value length] <= maximumLength
            ? value : rule[@"default"];
        changed |= VCPSetPreferenceValueIfDifferent(
            (__bridge CFStringRef)key, normalized);
    }];

    id targetValue = CFBridgingRelease(CFPreferencesCopyAppValue(
        CFSTR("targetBundleIdentifiers"), VCPreferencesDomain));
    NSMutableOrderedSet<NSString *> *targetIdentifiers =
        [NSMutableOrderedSet orderedSet];
    if ([targetValue isKindOfClass:NSArray.class]) {
        NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
        for (id candidate in (NSArray *)targetValue) {
            if (![candidate isKindOfClass:NSString.class]) continue;
            NSString *identifier = [candidate stringByTrimmingCharactersInSet:whitespace];
            if (identifier.length == 0 || identifier.length > 255) continue;
            if ([identifier rangeOfCharacterFromSet:whitespace].location != NSNotFound) continue;
            [targetIdentifiers addObject:identifier];
            if (targetIdentifiers.count >= 128) break;
        }
    }
    NSArray<NSString *> *normalizedTargets = [targetIdentifiers.array
        sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    changed |= VCPSetPreferenceValueIfDifferent(
        CFSTR("targetBundleIdentifiers"), normalizedTargets);

    if (changed) CFPreferencesAppSynchronize(VCPreferencesDomain);
    return changed;
}

@interface VCPRootListController : PSListController
    <NSURLSessionDataDelegate, UIDocumentPickerDelegate, PHPickerViewControllerDelegate> {
    VCJPEGParserState _streamTestJPEGParserState;
    NSUInteger _streamTestJPEGOffset;
    uint64_t _lastPreferencesSyncMilliseconds;
    BOOL _runtimePresentationDisabled;
}
@property (nonatomic, strong) NSURLSession *streamTestSession;
@property (nonatomic, strong) NSURLSessionDataTask *streamTestTask;
@property (nonatomic, strong) NSMutableData *streamTestData;
@property (nonatomic, copy) NSString *streamTestResponseSummary;
@property (nonatomic, strong) UIAlertController *streamTestAlert;
@property (nonatomic, assign) BOOL localMediaImportInProgress;
@property (nonatomic, strong) UIAlertController *localMediaImportAlert;
@property (nonatomic, strong) NSTimer *statusRefreshTimer;
- (void)finishStreamTestWithTitle:(NSString *)title message:(NSString *)message;
- (void)showStreamTestResultWithTitle:(NSString *)title message:(NSString *)message;
- (void)beginImportingLocalMediaURLs:(NSArray<NSURL *> *)urls
                      suggestedNames:(NSArray<NSString *> *)suggestedNames
                 securityAccessFlags:(NSArray<NSNumber *> *)securityAccessFlags;
- (void)finishLocalMediaImportsWithURLs:(NSArray<NSURL *> *)urls
                                  errors:(NSArray<NSError *> *)errors;
- (void)showLocalMediaImportProgressWithMessage:(NSString *)message
                                      completion:(dispatch_block_t)completion;
- (void)showLocalMediaResultWithTitle:(NSString *)title message:(NSString *)message;
- (void)refreshRuntimePresentation;
- (void)startStatusRefreshTimer;
- (void)stopStatusRefreshTimer;
- (void)performSafeRuntimePresentationRefresh;
- (void)disableRuntimePresentationAfterException:(NSException *)exception;
- (void)synchronizePreferencesIfNeeded:(BOOL)force;
- (NSArray<NSURL *> *)localMediaLibraryEntries;
- (id)currentPackageVersion:(PSSpecifier *)specifier;
- (id)currentNetworkEndpointSummary:(PSSpecifier *)specifier;
- (id)currentSourceConfigurationSummary:(PSSpecifier *)specifier;
- (id)currentLocalMediaName:(PSSpecifier *)specifier;
- (id)currentLocalMediaLibrarySummary:(PSSpecifier *)specifier;
- (id)currentSourceRuntimeStatus:(PSSpecifier *)specifier;
- (id)currentSharedVideoBusStatus:(PSSpecifier *)specifier;
- (id)currentSystemVideoPipelineStatus:(PSSpecifier *)specifier;
- (id)currentApplicationFallbackStatus:(PSSpecifier *)specifier;
- (id)currentTargetApplicationsSummary:(PSSpecifier *)specifier;
- (void)chooseTargetApplications:(PSSpecifier *)specifier;
- (id)currentLocalTransformStatus:(PSSpecifier *)specifier;
- (id)currentLocalVolumeHookStatus:(PSSpecifier *)specifier;
@end

@implementation VCPRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"VirtualCamPro";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                            target:self
                            action:@selector(refreshControlPanel:)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"Actualizar estado de ejecución";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    @try {
        if (_specifiers) [self reloadSpecifiers];
    } @catch (NSException *exception) {
        [self disableRuntimePresentationAfterException:exception];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Preferences.framework is private and differs between iOS point releases.
    // Wait until its table transition is complete before touching individual
    // rows; a failed optional refresh must never terminate the Settings app.
    [self performSafeRuntimePresentationRefresh];
    [self startStatusRefreshTimer];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopStatusRefreshTimer];
}

- (void)startStatusRefreshTimer {
    if (_runtimePresentationDisabled || self.statusRefreshTimer || !self.view.window) return;
    __weak VCPRootListController *weakSelf = self;
    self.statusRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                              repeats:YES
                                                                block:^(__unused NSTimer *timer) {
        VCPRootListController *strongSelf = weakSelf;
        if (strongSelf.view.window) [strongSelf performSafeRuntimePresentationRefresh];
    }];
    self.statusRefreshTimer.tolerance = 0.20;
}

- (void)stopStatusRefreshTimer {
    [self.statusRefreshTimer invalidate];
    self.statusRefreshTimer = nil;
}

- (void)performSafeRuntimePresentationRefresh {
    if (_runtimePresentationDisabled || !NSThread.isMainThread) return;
    @try {
        [self refreshRuntimePresentation];
    } @catch (NSException *exception) {
        [self disableRuntimePresentationAfterException:exception];
    }
}

- (void)disableRuntimePresentationAfterException:(NSException *)exception {
    if (_runtimePresentationDisabled) return;
    _runtimePresentationDisabled = YES;
    [self stopStatusRefreshTimer];
    NSLog(@"[VirtualCamPro] Optional Settings live refresh disabled after %@: %@",
          exception.name ?: @"exception", exception.reason ?: @"unknown reason");
    // Keep the native PreferenceLoader rows usable. Live status is optional,
    // so any private-framework mismatch degrades to the static list.
    @try {
        self.navigationItem.rightBarButtonItem = nil;
    } @catch (__unused NSException *cleanupException) {
    }
}

- (void)synchronizePreferencesIfNeeded:(BOOL)force {
    uint64_t now = VCPMonotonicMilliseconds();
    if (!force && _lastPreferencesSyncMilliseconds > 0 &&
        now >= _lastPreferencesSyncMilliseconds &&
        now - _lastPreferencesSyncMilliseconds < 750) {
        return;
    }
    CFPreferencesAppSynchronize(VCPreferencesDomain);
    _lastPreferencesSyncMilliseconds = now;
}

- (void)refreshControlPanel:(id)sender {
    [self performSafeRuntimePresentationRefresh];
    UISelectionFeedbackGenerator *feedback = [UISelectionFeedbackGenerator new];
    [feedback selectionChanged];
}

- (id)currentTargetApplicationsSummary:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:YES];
    id value = CFBridgingRelease(CFPreferencesCopyAppValue(
        CFSTR("targetBundleIdentifiers"), VCPreferencesDomain));
    if (![value isKindOfClass:NSArray.class] || [value count] == 0) {
        return @"Todas las apps";
    }
    NSUInteger count = MIN((NSUInteger)[value count], (NSUInteger)128);
    return count == 1 ? @"1 aplicación" : [NSString stringWithFormat:@"%@ aplicaciones", @(count)];
}

- (void)chooseTargetApplications:(PSSpecifier *)specifier {
    VCPApplicationSelectorController *controller =
        [VCPApplicationSelectorController new];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)refreshRuntimePresentation {
    [self synchronizePreferencesIfNeeded:NO];
    // Only lightweight, read-only status rows opt into the one-second refresh.
    // Editing cells and sliders are never reloaded under the user's finger.
    for (PSSpecifier *specifier in [_specifiers copy]) {
        if ([[specifier propertyForKey:@"vcLiveStatus"] boolValue]) {
            // The one-argument selector exists across older iOS 15
            // Preferences.framework variants and internally requests a
            // non-animated reload.
            [self reloadSpecifier:specifier];
        }
    }
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        VCPRepairStoredPreferences();
        [self synchronizePreferencesIfNeeded:YES];
        id sourceValue = CFBridgingRelease(
            CFPreferencesCopyAppValue(CFSTR("sourceType"), VCPreferencesDomain));
        NSInteger sourceTypeValue = VCPReadIntegerPreference(sourceValue, 0, 2, 0);
        NSNumber *sourceType = @(sourceTypeValue);
        NSArray *allSpecifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
        NSMutableArray *visible = [NSMutableArray arrayWithCapacity:allSpecifiers.count];
        for (PSSpecifier *specifier in allSpecifiers) {
            NSArray *sourceTypes = [specifier propertyForKey:@"vcSourceTypes"];
            if (![sourceTypes isKindOfClass:NSArray.class] ||
                [sourceTypes containsObject:sourceType]) {
                [visible addObject:specifier];
            }
        }
        _specifiers = visible;
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:@"preferredFPS"]) {
        double number = 0;
        int64_t integer = 60;
        if (!VCPReadFinitePreferenceNumber(value, &number) ||
            !VCPreferenceValidateInteger(number, 1, 240, &integer)) {
            integer = 60;
        }
        value = @(integer);
    }
    if ([key isEqualToString:@"streamURL"] && [value isKindOfClass:NSString.class]) {
        value = [value stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([value length] > 4096) value = @"";
    }
    [super setPreferenceValue:value specifier:specifier];
    [self synchronizePreferencesIfNeeded:YES];
    [VCPreferences.sharedPreferences reload];
    [VCPreferences.sharedPreferences publishSharedConfiguration];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         VCPreferencesChangedNotification,
                                         NULL,
                                         NULL,
                                          YES);
    if ([key isEqualToString:@"sourceType"]) {
        _specifiers = nil;
        @try {
            [self reloadSpecifiers];
        } @catch (NSException *exception) {
            [self disableRuntimePresentationAfterException:exception];
        }
    }
    for (PSSpecifier *statusSpecifier in [_specifiers copy]) {
        if ([[statusSpecifier propertyForKey:@"vcConfigurationStatus"] boolValue]) {
            @try {
                [self reloadSpecifier:statusSpecifier];
            } @catch (NSException *exception) {
                [self disableRuntimePresentationAfterException:exception];
                break;
            }
        }
    }
    [self performSafeRuntimePresentationRefresh];
}

- (void)chooseLocalMedia:(PSSpecifier *)specifier {
    if (self.localMediaImportInProgress || self.presentedViewController) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Seleccionar contenido local"
                                                                    message:@"El archivo se copiará y verificará, y después se establecerá automáticamente como fuente de reemplazo."
                                                             preferredStyle:UIAlertControllerStyleActionSheet];
    __weak VCPRootListController *weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Elegir video o audio desde Archivos"
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        VCPRootListController *strongSelf = weakSelf;
        if (!strongSelf) return;
        UIDocumentPickerViewController *picker =
            [[UIDocumentPickerViewController alloc]
                initWithDocumentTypes:@[@"public.movie", @"public.audio",
                                        @"public.audiovisual-content"]
                                 inMode:UIDocumentPickerModeOpen];
        picker.delegate = strongSelf;
        picker.allowsMultipleSelection = YES;
        if (@available(iOS 13.0, *)) picker.shouldShowFileExtensions = YES;
        [strongSelf presentViewController:picker animated:YES completion:nil];
    }]];
    if (@available(iOS 14.0, *)) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Elegir video desde Fotos"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *action) {
            VCPRootListController *strongSelf = weakSelf;
            if (!strongSelf) return;
            PHPickerConfiguration *configuration = [[PHPickerConfiguration alloc] init];
            configuration.filter = PHPickerFilter.videosFilter;
            // A bounded batch makes the stable import directory immediately
            // useful as a volume-button playlist without opening unbounded
            // parallel iCloud downloads.
            configuration.selectionLimit = 20;
            // Edited, rotated, HDR and iCloud-backed assets may expose a
            // current representation that older iOS 15 AVFoundation cannot
            // parse reliably. Ask Photos for its most compatible file instead.
            configuration.preferredAssetRepresentationMode =
                PHPickerConfigurationAssetRepresentationModeCompatible;
            PHPickerViewController *picker =
                [[PHPickerViewController alloc] initWithConfiguration:configuration];
            picker.delegate = strongSelf;
            [strongSelf presentViewController:picker animated:YES completion:nil];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancelar"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = self.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                        CGRectGetMidY(self.view.bounds), 1.0, 1.0);
        popover.permittedArrowDirections = 0;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (id)currentPackageVersion:(PSSpecifier *)specifier {
    NSString *version = [[NSBundle bundleForClass:self.class]
        objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] && version.length > 0
        ? version : @"Desconocido";
}

- (id)currentNetworkEndpointSummary:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:NO];
    id value = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("streamURL"), VCPreferencesDomain));
    if (![value isKindOfClass:NSString.class] || [value length] == 0 ||
        [value length] > 4096) {
        return @"URL aún no configurada";
    }
    NSURL *url = [NSURL URLWithString:[value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    NSString *scheme = url.scheme.lowercaseString;
    if ((!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) ||
        url.host.length == 0 || url.user.length > 0 || url.password.length > 0 ||
        url.fragment.length > 0) {
        return @"Formato de URL no válido";
    }
    BOOL hls = [url.absoluteString.lowercaseString containsString:@".m3u8"];
    NSString *host = url.port
        ? [NSString stringWithFormat:@"%@:%@", url.host, url.port] : url.host;
    return [NSString stringWithFormat:@"%@ · %@", hls ? @"HLS" : @"MJPEG", host];
}

- (id)currentSourceConfigurationSummary:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:NO];
    id sourceValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("sourceType"), VCPreferencesDomain));
    switch (VCPReadIntegerPreference(sourceValue, 0, 2, 0)) {
        case 1:
            return @"Duplicación de pantalla en tiempo real · orientación del sistema";
        case 2: {
            NSString *name = [self currentLocalMediaName:nil];
            if ([name isEqualToString:@"Sin seleccionar"]) {
                return @"Contenido local del iPhone · ningún archivo seleccionado";
            }
            id pathValue = CFBridgingRelease(
                CFPreferencesCopyAppValue(VCLocalMediaPathKey, VCPreferencesDomain));
            if (![pathValue isKindOfClass:NSString.class] ||
                ![NSFileManager.defaultManager fileExistsAtPath:pathValue]) {
                return [NSString stringWithFormat:@"Contenido local del iPhone · %@ (el archivo no existe)", name];
            }
            return [@"Contenido local del iPhone · " stringByAppendingString:name];
        }
        default:
            return [@"Transmisión de red · " stringByAppendingString:
                [self currentNetworkEndpointSummary:nil]];
    }
}

- (NSArray<NSURL *> *)localMediaLibraryEntries {
    NSArray<NSURL *> *entries = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:[NSURL fileURLWithPath:VCLocalMediaDirectory isDirectory:YES]
       includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
                          options:NSDirectoryEnumerationSkipsHiddenFiles
                            error:nil];
    NSIndexSet *regularIndexes = [entries indexesOfObjectsPassingTest:^BOOL(
        NSURL *entry, NSUInteger index, BOOL *stop) {
        NSNumber *regular = nil;
        [entry getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        return regular.boolValue;
    }];
    return [[entries objectsAtIndexes:regularIndexes]
        sortedArrayUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        return [left.lastPathComponent localizedStandardCompare:right.lastPathComponent];
    }];
}

- (id)currentLocalMediaLibrarySummary:(PSSpecifier *)specifier {
    NSArray<NSURL *> *entries = [self localMediaLibraryEntries];
    unsigned long long totalBytes = 0;
    for (NSURL *entry in entries) {
        NSNumber *fileSize = nil;
        [entry getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
        unsigned long long bytes = fileSize.unsignedLongLongValue;
        totalBytes = ULLONG_MAX - totalBytes < bytes ? ULLONG_MAX : totalBytes + bytes;
    }
    NSByteCountFormatter *formatter = [NSByteCountFormatter new];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    NSString *size = [formatter stringFromByteCount:
        totalBytes > (unsigned long long)LLONG_MAX ? LLONG_MAX : (long long)totalBytes];
    return [NSString stringWithFormat:@"%lu archivos · %@",
        (unsigned long)entries.count, size ?: @"0 bytes"];
}

- (id)currentLocalMediaName:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:NO];
    id pathValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(VCLocalMediaPathKey, VCPreferencesDomain));
    if (![pathValue isKindOfClass:NSString.class] || [pathValue length] == 0) {
        return @"Sin seleccionar";
    }
    NSString *filename = [pathValue lastPathComponent];
    return filename.length > 0 ? VCPDisplaySafeFilename(filename) : @"Sin seleccionar";
}

- (id)currentLocalVideoPlaylistSummary:(PSSpecifier *)specifier {
    static NSSet<NSString *> *videoExtensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        videoExtensions = [NSSet setWithArray:@[
            @"mp4", @"mov", @"m4v", @"3gp", @"3g2", @"avi",
            @"mpg", @"mpeg", @"ts", @"mts", @"m2ts",
        ]];
    });
    NSArray<NSURL *> *entries = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:[NSURL fileURLWithPath:VCLocalMediaDirectory isDirectory:YES]
       includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                          options:NSDirectoryEnumerationSkipsHiddenFiles
                            error:nil];
    NSUInteger count = 0;
    for (NSURL *entry in entries) {
        NSNumber *regular = nil;
        [entry getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        if (regular.boolValue &&
            [videoExtensions containsObject:entry.pathExtension.lowercaseString]) {
            count++;
        }
    }
    return count >= 2
        ? [NSString stringWithFormat:@"%lu videos; usa volumen +/− para cambiar", (unsigned long)count]
        : [NSString stringWithFormat:@"%lu videos; se necesitan al menos 2", (unsigned long)count];
}

- (id)currentLocalTransformStatus:(PSSpecifier *)specifier {
    uint64_t state = 0;
    if (!VCPGetNotifyChannelState(VCPNotifyChannelLocalTransform, &state)) {
        return @"Estado de SpringBoard no disponible";
    }
    if (!(state & 1ULL)) {
        return @"Esperando que se active el contenido local";
    }
    BOOL ready = (state & (1ULL << 1)) != 0;
    BOOL userMirror = (state & (1ULL << 2)) != 0;
    BOOL aspectFill = (state & (1ULL << 3)) != 0;
    BOOL trackMirror = (state & (1ULL << 4)) != 0;
    NSInteger userRotation = (NSInteger)((state >> 8) & 0x3) * 90;
    NSInteger trackRotation = (NSInteger)((state >> 10) & 0x3) * 90;
    NSInteger finalRotation = (trackRotation + userRotation) % 360;
    BOOL finalMirror = trackMirror != userMirror;
    return [NSString stringWithFormat:@"%@：%ld° · %@ · %@",
        ready ? @"Aplicado" : @"Esperando el primer fotograma",
        (long)finalRotation,
        finalMirror ? @"Reflejado" : @"Sin reflejo",
        aspectFill ? @"Rellenar" : @"Mostrar completo"];
}

- (id)currentLocalVolumeHookStatus:(PSSpecifier *)specifier {
    uint64_t state = 0;
    if (!VCPGetNotifyChannelState(VCPNotifyChannelLocalVolumeHook, &state)) {
        return @"Estado de SpringBoard no disponible";
    }
    BOOL installed = (state & VC_VOLUME_HOOK_STATUS_INSTALLED) != 0;
    BOOL buttons = (state & VC_VOLUME_HOOK_STATUS_BUTTON_PAIR) != 0;
    BOOL delta = (state & VC_VOLUME_HOOK_STATUS_DELTA) != 0;
    BOOL scanComplete = (state & VC_VOLUME_HOOK_STATUS_SCAN_COMPLETE) != 0;
    uint8_t directionalCount = VCDirectionalHookCountFromStatus(state);
    uint8_t deltaCount = VCDeltaHookCountFromStatus(state);
    if (!installed) {
        return scanComplete ? @"Análisis completado; no se encontró una entrada compatible. Se conserva el volumen del sistema"
                            : @"Buscando entradas de volumen de SpringBoard";
    }
    NSString *route = buttons && delta ? @"Botones + incremento"
        : (buttons ? @"Botones de volumen" : (delta ? @"Incremento de volumen" : @"Botones parciales"));
    return [NSString stringWithFormat:@"Instalado: %@ (dirección %u · incremento %u)",
            route, directionalCount, deltaCount];
}

- (id)currentSourceRuntimeStatus:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:NO];
    id enabledValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("enabled"), VCPreferencesDomain));
    if (!VCPReadBooleanPreference(enabledValue, NO)) return @"Desactivado";
    uint64_t producerHeartbeat = 0;
    uint64_t producerAge = UINT64_MAX;
    if (!VCPGetNotifyChannelState(VCPNotifyChannelSpringBoardRuntime,
                                  &producerHeartbeat) ||
        !VCPRuntimeTimestampAge(producerHeartbeat, &producerAge)) {
        return @"Plugin de SpringBoard no inyectado / sin señal de actividad";
    }
    if (producerAge > VC_RUNTIME_HEARTBEAT_MAX_AGE_MS) {
        return @"Plugin de SpringBoard sin conexión; se ignoró el estado anterior de la fuente";
    }
    uint64_t status = VCPStreamStatusDisabled;
    if (!VCPGetSystemStreamStatus(&status)) return @"Estado de SpringBoard no disponible";
    switch (status) {
        case VCPStreamStatusConnecting: return @"Inicializando / reconectando";
        case VCPStreamStatusReceiving: return @"Produciendo fotogramas de forma estable";
        case VCPStreamStatusError: return @"Error de la fuente; recuperando";
        case VCPStreamStatusHoldingLastFrame: return @"Transmisión interrumpida; conservando el último fotograma";
        case VCPStreamStatusCompleted: return @"Reproducción del contenido local completada";
        default: return @"Esperando que SpringBoard tome el control";
    }
}

- (id)currentSharedVideoBusStatus:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:NO];
    id enabledValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("enabled"), VCPreferencesDomain));
    if (!VCPReadBooleanPreference(enabledValue, NO)) return @"Desactivado";
    uint64_t heartbeat = 0;
    uint64_t heartbeatAge = UINT64_MAX;
    if (!VCPGetNotifyChannelState(VCPNotifyChannelSpringBoardRuntime,
                                  &heartbeat) ||
        !VCPRuntimeTimestampAge(heartbeat, &heartbeatAge) ||
        heartbeatAge > VC_RUNTIME_HEARTBEAT_MAX_AGE_MS) {
        return @"SpringBoard no tiene señal de actividad; se ignoró el estado de publicación";
    }
    uint64_t runtimeState = 0;
    if (!VCPGetNotifyChannelState(VCPNotifyChannelProducerVideoRuntime,
                                  &runtimeState) || runtimeState == 0) {
        return @"SpringBoard está activo, pero aún no informó una publicación de video compartido";
    }
    return VCPProducerVideoRuntimeDescription(runtimeState);
}

- (id)currentSystemVideoPipelineStatus:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:NO];
    id enabledValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("enabled"), VCPreferencesDomain));
    if (!VCPReadBooleanPreference(enabledValue, NO)) return @"Desactivado";
    uint64_t mediaServerHeartbeat = 0;
    uint64_t mediaServerAge = UINT64_MAX;
    if (!VCPGetNotifyChannelState(VCPNotifyChannelMediaServerRuntime,
                                  &mediaServerHeartbeat) ||
        !VCPRuntimeTimestampAge(mediaServerHeartbeat, &mediaServerAge)) {
        return @"Plugin de mediaserverd no inyectado / sin señal de actividad";
    }
    if (mediaServerAge > VC_RUNTIME_HEARTBEAT_MAX_AGE_MS) {
        return @"Plugin de mediaserverd sin conexión; se ignoró el estado anterior de la canalización";
    }
    uint64_t timestamp = 0;
    uint64_t replacementAge = UINT64_MAX;
    if (VCPGetNotifyChannelState(VCPNotifyChannelVideoPipeline, &timestamp) &&
        VCPRuntimeTimestampAge(timestamp, &replacementAge) &&
        replacementAge <= 1500) {
        return @"mediaserverd reemplazó video recientemente";
    }
    uint64_t runtimeState = 0;
    if (!VCPGetNotifyChannelState(VCPNotifyChannelMediaServerVideoRuntime,
                                  &runtimeState) || runtimeState == 0) {
        return @"mediaserverd está activo, pero aún no informó la etapa del hook";
    }
    return VCPMediaServerVideoRuntimeDescription(runtimeState);
}

- (id)currentApplicationFallbackStatus:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:NO];
    id enabledValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("enabled"), VCPreferencesDomain));
    if (!VCPReadBooleanPreference(enabledValue, NO)) return @"Desactivado";
    uint64_t runtimeState = 0;
    if (!VCPGetNotifyChannelState(VCPNotifyChannelApplicationVideoRuntime,
                                  &runtimeState) || runtimeState == 0) {
        return @"Aún no hay actividad del hook de AVFoundation; abre primero una aplicación de cámara";
    }
    return VCPApplicationVideoRuntimeDescription(runtimeState);
}

- (void)reloadCurrentSource:(PSSpecifier *)specifier {
    NSString *token = NSUUID.UUID.UUIDString;
    CFPreferencesSetAppValue(VCSourceRestartTokenKey,
                             (__bridge CFStringRef)token,
                             VCPreferencesDomain);
    if (!CFPreferencesAppSynchronize(VCPreferencesDomain)) {
        [self showLocalMediaResultWithTitle:@"Error al recargar"
                                    message:@"No se pudo guardar la generación interna de recarga. Inténtalo de nuevo más tarde."];
        return;
    }
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         VCPreferencesChangedNotification,
                                         NULL, NULL, YES);
    _specifiers = nil;
    [self reloadSpecifiers];
    [self showLocalMediaResultWithTitle:@"Recarga solicitada"
                                message:@"SpringBoard está deteniendo y reconstruyendo atómicamente la fuente actual; la URL, los archivos locales y los parámetros de imagen no cambiarán."];
}

- (void)showCurrentSourceGuide:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:YES];
    id sourceValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("sourceType"), VCPreferencesDomain));
    NSString *title = @"Cómo usar una transmisión de red";
    NSString *message = @"1. Inicia el puente de OBS en el centro de control de Windows.\n2. Escribe una URL HTTP/HTTPS accesible desde el iPhone.\n3. Pulsa «Probar transmisión actual».\n4. Activa el reemplazo y vuelve a abrir la aplicación de cámara.\n\nLa orientación, la frecuencia de fotogramas y la calidad dependen de OBS o del emisor; el iPhone conserva su micrófono nativo.";
    switch (VCPReadIntegerPreference(sourceValue, 0, 2, 0)) {
        case 1:
            title = @"Cómo usar la duplicación de pantalla";
            message = @"1. Selecciona la duplicación de pantalla del dispositivo.\n2. Activa el reemplazo de la cámara del sistema.\n3. Abre la aplicación de cámara de destino.\n\nLa orientación y la frecuencia de actualización siguen automáticamente al dispositivo; la rotación, el reflejo, los FPS y la calidad del video local no afectan esta fuente.";
            break;
        case 2:
            title = @"Cómo usar contenido local";
            message = @"1. Pulsa «Seleccionar video/audio local» para importar.\n2. Ajusta la rotación, el reflejo, los FPS y la calidad del video local.\n3. Activa el reemplazo y abre la aplicación de cámara.\n\nSi hay al menos dos videos en el mismo directorio, volumen +/− cambia al siguiente o anterior; los archivos de solo audio reemplazan únicamente el micrófono.";
            break;
        default:
            break;
    }
    [self showLocalMediaResultWithTitle:title message:message];
}

- (void)showLocalMediaLibrary:(PSSpecifier *)specifier {
    NSArray<NSURL *> *entries = [self localMediaLibraryEntries];
    NSString *selectedName = [self currentLocalMediaName:nil];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSUInteger visibleCount = MIN((NSUInteger)15, entries.count);
    NSByteCountFormatter *formatter = [NSByteCountFormatter new];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    for (NSUInteger index = 0; index < visibleCount; index++) {
        NSURL *entry = entries[index];
        NSNumber *fileSize = nil;
        [entry getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil];
        NSString *size = [formatter stringFromByteCount:fileSize.longLongValue];
        NSString *displayName = VCPDisplaySafeFilename(entry.lastPathComponent);
        NSString *marker = [displayName isEqualToString:selectedName] ? @"●" : @"○";
        [lines addObject:[NSString stringWithFormat:@"%@ %@  %@",
            marker, displayName, size ?: @""]];
    }
    if (entries.count > visibleCount) {
        [lines addObject:[NSString stringWithFormat:@"…y %lu archivos más",
            (unsigned long)(entries.count - visibleCount)]];
    }
    NSString *message = entries.count > 0
        ? [lines componentsJoinedByString:@"\n"]
        : @"La biblioteca está vacía. Usa «Seleccionar video/audio local» para importar archivos.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        [NSString stringWithFormat:@"Biblioteca local · %@",
            [self currentLocalMediaLibrarySummary:nil]]
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copiar ruta de la biblioteca"
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = VCLocalMediaDirectory;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cerrar"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)copyRuntimeDiagnostics:(PSSpecifier *)specifier {
    [self synchronizePreferencesIfNeeded:YES];
    id enabledValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("enabled"), VCPreferencesDomain));
    id holdValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("holdLastFrame"), VCPreferencesDomain));
    id staleValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("staleFrameTimeout"), VCPreferencesDomain));
    id fpsValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("preferredFPS"), VCPreferencesDomain));
    id rotationValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("sourceRotation"), VCPreferencesDomain));
    id mirrorValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("mirrorSource"), VCPreferencesDomain));
    id dimensionValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("maximumPixelDimension"), VCPreferencesDomain));
    BOOL enabled = VCPReadBooleanPreference(enabledValue, NO);
    BOOL mirror = VCPReadBooleanPreference(mirrorValue, NO);
    BOOL hold = VCPReadBooleanPreference(holdValue, YES);
    NSInteger fps = VCPReadIntegerPreference(fpsValue, 1, 240, 60);
    NSInteger rotation = VCPReadIntegerPreference(rotationValue, 0, 270, 0);
    NSInteger dimension = VCPReadIntegerPreference(dimensionValue, 1280, 3840, 1920);
    double staleTimeout = VCPReadRealPreference(staleValue, 2.0, 30.0, 8.0);
    NSISO8601DateFormatter *dateFormatter = [NSISO8601DateFormatter new];
    NSString *report = [NSString stringWithFormat:
        @"VirtualCamPro %@ runtime diagnostics\n"
         "generated=%@\n"
         "device=%@ / iOS %@\n"
         "enabled=%@\n"
         "source=%@\n"
         "sourceStatus=%@\n"
         "sharedVideoBus=%@\n"
         "springBoardRuntime=%@\n"
         "mediaServerRuntime=%@\n"
         "systemVideoPipeline=%@\n"
         "mediaServerVideoStage=%@\n"
         "applicationVideoStage=%@\n"
         "networkEndpoint=%@\n"
         "localMedia=%@\n"
         "localLibrary=%@\n"
         "localTransform=%@\n"
         "volumeHook=%@\n"
         "localFPS=%@ rotation=%@ mirror=%@ maxDimension=%@\n"
         "holdLastFrame=%@ staleTimeout=%@\n",
        [self currentPackageVersion:nil],
        [dateFormatter stringFromDate:NSDate.date],
        UIDevice.currentDevice.model,
        UIDevice.currentDevice.systemVersion,
        enabled ? @"yes" : @"no",
        [self currentSourceConfigurationSummary:nil],
        [self currentSourceRuntimeStatus:nil],
        [self currentSharedVideoBusStatus:nil],
        VCPRuntimeHeartbeatDescription(VCPNotifyChannelSpringBoardRuntime,
                                       @"SpringBoard"),
        VCPRuntimeHeartbeatDescription(VCPNotifyChannelMediaServerRuntime,
                                       @"mediaserverd"),
        [self currentSystemVideoPipelineStatus:nil],
        VCPCurrentMediaServerVideoRuntimeDescription(),
        [self currentApplicationFallbackStatus:nil],
        [self currentNetworkEndpointSummary:nil],
        [self currentLocalMediaName:nil],
        [self currentLocalMediaLibrarySummary:nil],
        [self currentLocalTransformStatus:nil],
        [self currentLocalVolumeHookStatus:nil],
        @(fps),
        @(rotation),
        mirror ? @"yes" : @"no",
        @(dimension),
        hold ? @"yes" : @"no",
        @(staleTimeout)];
    UIPasteboard.generalPasteboard.string = report;
    [self showLocalMediaResultWithTitle:@"Diagnóstico copiado"
                                message:@"Se copiaron el estado de ejecución y un resumen protegido de la fuente; los parámetros de consulta y tokens de acceso de la URL no se incluyen."];
}

- (void)clearLocalMedia:(PSSpecifier *)specifier {
    if (self.localMediaImportInProgress) {
        [self showLocalMediaResultWithTitle:@"Importación en curso"
                                    message:@"Espera a que termine la copia y verificación antes de borrar la selección."];
        return;
    }
    CFPreferencesSetAppValue(VCLocalMediaPathKey, NULL, VCPreferencesDomain);
    BOOL synchronized = CFPreferencesAppSynchronize(VCPreferencesDomain);
    if (!synchronized) {
        [self showLocalMediaResultWithTitle:@"No se pudo borrar"
                                    message:@"La configuración no se puede guardar en este momento. Inténtalo más tarde."];
        return;
    }
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         VCPreferencesChangedNotification,
                                         NULL, NULL, YES);
    _specifiers = nil;
    [self reloadSpecifiers];
    [self showLocalMediaResultWithTitle:@"Selección actual eliminada"
                                message:@"Los archivos importados permanecen en el directorio y no se eliminan automáticamente."];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
   didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSArray<NSURL *> *selectedURLs = urls.count > 64
        ? [urls subarrayWithRange:NSMakeRange(0, 64)] : urls;
    if (selectedURLs.count == 0) return;
    NSMutableArray<NSNumber *> *securityFlags =
        [NSMutableArray arrayWithCapacity:selectedURLs.count];
    NSMutableArray<NSString *> *suggestedNames =
        [NSMutableArray arrayWithCapacity:selectedURLs.count];
    for (NSURL *url in selectedURLs) {
        [securityFlags addObject:@([url startAccessingSecurityScopedResource])];
        [suggestedNames addObject:url.lastPathComponent ?: @"media.mov"];
    }
    __weak VCPRootListController *weakSelf = self;
    [controller dismissViewControllerAnimated:YES completion:^{
        VCPRootListController *strongSelf = weakSelf;
        if (!strongSelf) {
            [selectedURLs enumerateObjectsUsingBlock:^(NSURL *url,
                                                       NSUInteger index,
                                                       BOOL *stop) {
                if ([securityFlags[index] boolValue]) {
                    [url stopAccessingSecurityScopedResource];
                }
            }];
            return;
        }
        [strongSelf beginImportingLocalMediaURLs:selectedURLs
                                  suggestedNames:suggestedNames
                             securityAccessFlags:securityFlags];
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentAtURL:(NSURL *)url {
    [self documentPicker:controller didPickDocumentsAtURLs:url ? @[url] : @[]];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [controller dismissViewControllerAnimated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker
didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14.0)) {
    __weak VCPRootListController *weakSelf = self;
    [picker dismissViewControllerAnimated:YES completion:^{
        VCPRootListController *strongSelf = weakSelf;
        if (!strongSelf || results.count == 0) return;
        BOOL containsVideo = [results indexOfObjectPassingTest:^BOOL(
            PHPickerResult *result, NSUInteger index, BOOL *stop) {
            return [result.itemProvider hasItemConformingToTypeIdentifier:@"public.movie"];
        }] != NSNotFound;
        if (!containsVideo) {
            [strongSelf showLocalMediaResultWithTitle:@"No se pudo leer el video"
                                               message:@"La selección de Fotos no contiene ningún video que se pueda importar."];
            return;
        }
        strongSelf.localMediaImportInProgress = YES;
        [strongSelf showLocalMediaImportProgressWithMessage:@"Leyendo, copiando y verificando videos desde Fotos…"
                                                 completion:^{
            NSMutableArray *orderedURLs = [NSMutableArray arrayWithCapacity:results.count];
            NSMutableArray *orderedErrors = [NSMutableArray arrayWithCapacity:results.count];
            for (NSUInteger index = 0; index < results.count; index++) {
                [orderedURLs addObject:NSNull.null];
                [orderedErrors addObject:NSNull.null];
            }
            dispatch_group_t group = dispatch_group_create();
            [results enumerateObjectsUsingBlock:^(PHPickerResult *result,
                                                   NSUInteger index,
                                                   BOOL *stop) {
                NSItemProvider *provider = result.itemProvider;
                if (![provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
                    @synchronized (orderedURLs) {
                        orderedErrors[index] = VCLocalMediaError(
                            VCLocalMediaImportErrorReadSource,
                            @"Uno de los elementos de Fotos no contiene un archivo de video.", nil);
                    }
                    return;
                }
                dispatch_group_enter(group);
                [provider loadFileRepresentationForTypeIdentifier:@"public.movie"
                    completionHandler:^(NSURL *url, NSError *providerError) {
                    NSError *importError = providerError;
                    NSURL *importedURL = nil;
                    if (url && !providerError) {
                        // Providers may callback concurrently and temporary URLs
                        // are only valid inside this block. Serialize final-name
                        // reservation/copy while keeping each URL alive.
                        @synchronized ([VCPRootListController class]) {
                            importedURL = VCImportLocalMediaURL(url,
                                                               provider.suggestedName,
                                                               NO,
                                                               YES,
                                                               &importError);
                        }
                    }
                    if (!url && !importError) {
                        importError = VCLocalMediaError(VCLocalMediaImportErrorReadSource,
                            @"Fotos no devolvió un archivo de video legible.", nil);
                    }
                    @synchronized (orderedURLs) {
                        if (importedURL) orderedURLs[index] = importedURL;
                        if (importError) orderedErrors[index] = importError;
                    }
                    dispatch_group_leave(group);
                }];
            }];
            dispatch_group_notify(group,
                                  dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSMutableArray<NSURL *> *imported = [NSMutableArray array];
                NSMutableArray<NSError *> *errors = [NSMutableArray array];
                @synchronized (orderedURLs) {
                    for (NSUInteger index = 0; index < orderedURLs.count; index++) {
                        if ([orderedURLs[index] isKindOfClass:NSURL.class]) {
                            [imported addObject:orderedURLs[index]];
                        }
                        if ([orderedErrors[index] isKindOfClass:NSError.class]) {
                            [errors addObject:orderedErrors[index]];
                        }
                    }
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf finishLocalMediaImportsWithURLs:imported errors:errors];
                });
            });
        }];
    }];
}

- (void)beginImportingLocalMediaURLs:(NSArray<NSURL *> *)urls
                      suggestedNames:(NSArray<NSString *> *)suggestedNames
                 securityAccessFlags:(NSArray<NSNumber *> *)securityAccessFlags {
    if (urls.count == 0 || self.localMediaImportInProgress) {
        [urls enumerateObjectsUsingBlock:^(NSURL *url, NSUInteger index, BOOL *stop) {
            if (index < securityAccessFlags.count && securityAccessFlags[index].boolValue) {
                [url stopAccessingSecurityScopedResource];
            }
        }];
        return;
    }
    self.localMediaImportInProgress = YES;
    __weak VCPRootListController *weakSelf = self;
    [self showLocalMediaImportProgressWithMessage:@"Copiando y verificando el contenido; espera…"
                                       completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSMutableArray<NSURL *> *importedURLs = [NSMutableArray array];
            NSMutableArray<NSError *> *importErrors = [NSMutableArray array];
            [urls enumerateObjectsUsingBlock:^(NSURL *url, NSUInteger index, BOOL *stop) {
                NSError *importError = nil;
                NSString *suggestedName = index < suggestedNames.count
                    ? suggestedNames[index] : url.lastPathComponent;
                BOOL stopSecurityAccess = index < securityAccessFlags.count
                    ? securityAccessFlags[index].boolValue : NO;
                NSURL *importedURL = VCImportLocalMediaURL(url,
                                                           suggestedName,
                                                           stopSecurityAccess,
                                                           NO,
                                                           &importError);
                if (importedURL) [importedURLs addObject:importedURL];
                if (importError) [importErrors addObject:importError];
            }];
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf finishLocalMediaImportsWithURLs:importedURLs errors:importErrors];
            });
        });
    }];
}

- (void)showLocalMediaImportProgressWithMessage:(NSString *)message
                                      completion:(dispatch_block_t)completion {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Importando contenido local"
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *indicator = nil;
    if (@available(iOS 13.0, *)) {
        indicator = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    } else {
        indicator = [[UIActivityIndicatorView alloc]
            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    }
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [indicator startAnimating];
    [alert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor],
        [indicator.bottomAnchor constraintEqualToAnchor:alert.view.bottomAnchor constant:-18.0],
    ]];
    self.localMediaImportAlert = alert;
    [self presentViewController:alert animated:YES completion:completion];
}

- (void)finishLocalMediaImportsWithURLs:(NSArray<NSURL *> *)urls
                                  errors:(NSArray<NSError *> *)errors {
    if (![NSThread isMainThread]) {
        __weak VCPRootListController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishLocalMediaImportsWithURLs:urls errors:errors];
        });
        return;
    }
    UIAlertController *progressAlert = self.localMediaImportAlert;
    self.localMediaImportAlert = nil;
    self.localMediaImportInProgress = NO;

    NSURL *url = urls.firstObject;
    NSError *error = errors.firstObject;
    NSString *title = @"Error de importación";
    NSString *message = error.localizedDescription ?: @"No se pudo importar el contenido seleccionado.";
    if (url) {
        CFPreferencesSetAppValue(VCLocalMediaPathKey,
                                 (__bridge CFPropertyListRef)url.path,
                                 VCPreferencesDomain);
        if (CFPreferencesAppSynchronize(VCPreferencesDomain)) {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 VCPreferencesChangedNotification,
                                                 NULL, NULL, YES);
            _specifiers = nil;
            [self reloadSpecifiers];
            title = urls.count > 1 ? @"Lista de videos locales lista" : @"Contenido local listo";
            message = urls.count > 1
                ? [NSString stringWithFormat:
                    @"Se importaron %lu archivos correctamente; la reproducción comienza con %@. Volumen +/− cambia al video siguiente o anterior del directorio permanente.%@",
                    (unsigned long)urls.count,
                    url.lastPathComponent,
                    errors.count > 0
                        ? [NSString stringWithFormat:@"\n\nNo se pudieron importar otros %lu archivos.",
                            (unsigned long)errors.count] : @""]
                : [NSString stringWithFormat:@"Seleccionado: %@\n\nRuta permanente: %@%@",
                    url.lastPathComponent,
                    url.path,
                    errors.count > 0 ? @"\n\nNo se pudieron importar los demás elementos seleccionados." : @""];
        } else {
            title = @"El contenido se copió, pero no se guardó la configuración";
            message = [NSString stringWithFormat:@"El archivo se guardó en %@. Vuelve a seleccionarlo.", url.path];
        }
    }

    void (^showResult)(void) = ^{
        [self showLocalMediaResultWithTitle:title message:message];
    };
    if (progressAlert.presentingViewController) {
        [progressAlert dismissViewControllerAnimated:YES completion:showResult];
    } else {
        showResult();
    }
}

- (void)showLocalMediaResultWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Aceptar"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)testStreamConnection:(PSSpecifier *)specifier {
    if (self.streamTestTask) return;
    [self synchronizePreferencesIfNeeded:YES];
    id enabledValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("enabled"), VCPreferencesDomain));
    id sourceTypeValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("sourceType"), VCPreferencesDomain));
    NSString *streamValue = CFBridgingRelease(
        CFPreferencesCopyAppValue(CFSTR("streamURL"), VCPreferencesDomain));
    NSString *trimmedValue = [streamValue isKindOfClass:[NSString class]] &&
                             [streamValue length] <= 4096
        ? [streamValue stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : @"";
    NSURL *streamURL = [NSURL URLWithString:trimmedValue];
    if (VCPReadIntegerPreference(sourceTypeValue, 0, 2, 0) != 0) {
        [self showStreamTestResultWithTitle:@"La fuente actual no es de red"
                                   message:@"Cambia «Fuente de reemplazo» a HLS/MJPEG de red antes de probar la URL. SpringBoard lee localmente la pantalla y el contenido del dispositivo sin crear una conexión de red."];
        return;
    }
    NSString *scheme = streamURL.scheme.lowercaseString;
    if ((!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) ||
        streamURL.host.length == 0 || streamURL.user.length > 0 ||
        streamURL.password.length > 0 || streamURL.fragment.length > 0 ||
        streamURL.absoluteString.length > 4096) {
        [self showStreamTestResultWithTitle:@"URL no válida"
                                   message:@"Escribe primero una URL HTTP/HTTPS completa para la transmisión."];
        return;
    }

    if (VCPReadBooleanPreference(enabledValue, NO)) {
        uint64_t status = VCPStreamStatusDisabled;
        VCPGetSystemStreamStatus(&status);
        switch (status) {
            case VCPStreamStatusReceiving:
                [self showStreamTestResultWithTitle:@"Transmisión disponible"
                                           message:@"El servicio multimedia de SpringBoard está recibiendo fotogramas válidos; no es necesario abrir una segunda conexión de prueba."];
                return;
            case VCPStreamStatusConnecting:
                [self showStreamTestResultWithTitle:@"Conectando"
                                           message:@"El servicio multimedia de SpringBoard está conectándose a la URL actual. Confirma que el puente de Windows esté activo e inténtalo de nuevo más tarde."];
                return;
            case VCPStreamStatusError:
                [self showStreamTestResultWithTitle:@"La conexión necesita recuperarse"
                                           message:@"El servicio multimedia de SpringBoard detectó una interrupción y está reconectando automáticamente. Revisa el puente de Windows, la IP y el firewall."];
                return;
            case VCPStreamStatusHoldingLastFrame:
                [self showStreamTestResultWithTitle:@"Conservando el último fotograma"
                                           message:@"La conexión de red se está recuperando; la cámara del sistema sigue mostrando el último fotograma recibido. Revisa el puente de Windows y la estabilidad de la red."];
                return;
            default:
                [self showStreamTestResultWithTitle:@"El servicio multimedia aún no tomó el control"
                                           message:@"El reemplazo está activado, pero SpringBoard aún no informó el estado de la fuente. Confirma que la inyección se haya completado y revisa el registro del sistema."];
                return;
        }
    }

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 8.0;
    configuration.timeoutIntervalForResource = 8.0;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.HTTPMaximumConnectionsPerHost = 1;
    self.streamTestData = [NSMutableData data];
    _streamTestJPEGOffset = NSNotFound;
    VCJPEGParserReset(&_streamTestJPEGParserState);
    self.streamTestResponseSummary = @"El servidor respondió";
    self.streamTestSession = [NSURLSession sessionWithConfiguration:configuration
                                                           delegate:self
                                                      delegateQueue:[NSOperationQueue mainQueue]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:streamURL];
    [request setValue:@"multipart/x-mixed-replace,image/jpeg,application/vnd.apple.mpegurl,*/*;q=0.1"
   forHTTPHeaderField:@"Accept"];
    self.streamTestTask = [self.streamTestSession dataTaskWithRequest:request];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Probando la transmisión de red"
                                                                    message:@"Esperando datos de video válidos del servidor…"
                                                             preferredStyle:UIAlertControllerStyleAlert];
    __weak VCPRootListController *weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancelar"
                                             style:UIAlertActionStyleCancel
                                           handler:^(__unused UIAlertAction *action) {
        [weakSelf finishStreamTestWithTitle:@"Cancelado" message:@"Se canceló la prueba de la transmisión."];
    }]];
    self.streamTestAlert = alert;
    [self presentViewController:alert animated:YES completion:nil];
    [self.streamTestTask resume];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    if (session != self.streamTestSession || dataTask != self.streamTestTask) {
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]]
        ? (NSHTTPURLResponse *)response : nil;
    if (httpResponse && (httpResponse.statusCode < 200 || httpResponse.statusCode >= 300)) {
        completionHandler(NSURLSessionResponseCancel);
        [self finishStreamTestWithTitle:@"Error de conexión"
                                message:[NSString stringWithFormat:@"El servidor devolvió HTTP %ld.",
                                         (long)httpResponse.statusCode]];
        return;
    }
    NSString *mimeType = response.MIMEType.lowercaseString ?: @"Tipo desconocido";
    if ([mimeType isEqualToString:@"text/html"] ||
        [mimeType isEqualToString:@"application/json"]) {
        completionHandler(NSURLSessionResponseCancel);
        [self finishStreamTestWithTitle:@"Tipo de contenido incorrecto"
                                message:[NSString stringWithFormat:@"El servidor devolvió %@, que no es una transmisión de video.",
                                         mimeType]];
        return;
    }
    self.streamTestResponseSummary = [NSString stringWithFormat:@"Conexión HTTP correcta; tipo de contenido: %@", mimeType];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    if (session != self.streamTestSession || dataTask != self.streamTestTask || data.length == 0) return;
    NSUInteger remainingCapacity = self.streamTestData.length < VCPStreamTestMaximumBytes
        ? VCPStreamTestMaximumBytes - self.streamTestData.length : 0;
    if (remainingCapacity > 0) {
        [self.streamTestData appendBytes:data.bytes
                                  length:MIN(data.length, remainingCapacity)];
    }

    static NSData *jpegStartMarker;
    static NSData *hlsHeader;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        static const unsigned char markerBytes[] = {0xFF, 0xD8};
        jpegStartMarker = [NSData dataWithBytes:markerBytes length:sizeof(markerBytes)];
        hlsHeader = [@"#EXTM3U" dataUsingEncoding:NSUTF8StringEncoding];
    });
    NSRange range = NSMakeRange(0, self.streamTestData.length);
    BOOL containsJPEG = NO;
    while (!containsJPEG && self.streamTestData.length >= 2) {
        if (_streamTestJPEGOffset == NSNotFound) {
            NSRange jpegStart = [self.streamTestData rangeOfData:jpegStartMarker
                                                         options:0
                                                           range:range];
            if (jpegStart.location == NSNotFound) break;
            _streamTestJPEGOffset = jpegStart.location;
            VCJPEGParserReset(&_streamTestJPEGParserState);
        }
        const uint8_t *jpegBytes =
            (const uint8_t *)self.streamTestData.bytes + _streamTestJPEGOffset;
        NSUInteger jpegBytesLength = self.streamTestData.length - _streamTestJPEGOffset;
        size_t parsedFrameLength = 0;
        VCJPEGParserResult parserResult = VCJPEGParserConsume(jpegBytes,
                                                               jpegBytesLength,
                                                               &_streamTestJPEGParserState,
                                                               &parsedFrameLength);
        if (parserResult == VCJPEGParserResultFrameComplete) {
            containsJPEG = parsedFrameLength > 0;
            break;
        }
        if (parserResult == VCJPEGParserResultNeedMoreData) break;

        NSUInteger nextSearchOffset = _streamTestJPEGOffset + jpegStartMarker.length;
        VCJPEGParserReset(&_streamTestJPEGParserState);
        _streamTestJPEGOffset = NSNotFound;
        if (nextSearchOffset >= self.streamTestData.length) break;
        NSRange nextRange = NSMakeRange(nextSearchOffset,
                                        self.streamTestData.length - nextSearchOffset);
        NSRange nextStart = [self.streamTestData rangeOfData:jpegStartMarker
                                                     options:0
                                                       range:nextRange];
        if (nextStart.location == NSNotFound) break;
        _streamTestJPEGOffset = nextStart.location;
    }
    BOOL containsHLS = [self.streamTestData rangeOfData:hlsHeader
                                                options:0
                                                  range:range].location != NSNotFound;
    if (containsJPEG || containsHLS) {
        NSString *format = containsJPEG ? @"MJPEG/JPEG" : @"HLS";
        [self finishStreamTestWithTitle:@"Transmisión disponible"
                                message:[NSString stringWithFormat:@"%@; se recibieron datos %@ válidos.",
                                         self.streamTestResponseSummary, format]];
    } else if (self.streamTestData.length >= VCPStreamTestMaximumBytes) {
        [self finishStreamTestWithTitle:@"No se detectó video"
                                message:@"El servidor es accesible, pero los primeros 8 MiB no contienen un JPEG completo ni marcadores HLS."];
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (session != self.streamTestSession || task != self.streamTestTask) return;
    NSString *message = error.localizedDescription ?: @"El servidor cerró la conexión antes de devolver video.";
    [self finishStreamTestWithTitle:@"Error de conexión" message:message];
}

- (void)finishStreamTestWithTitle:(NSString *)title message:(NSString *)message {
    if (!self.streamTestTask) return;
    NSURLSessionDataTask *task = self.streamTestTask;
    NSURLSession *session = self.streamTestSession;
    UIAlertController *progressAlert = self.streamTestAlert;
    self.streamTestTask = nil;
    self.streamTestSession = nil;
    self.streamTestData = nil;
    self.streamTestResponseSummary = nil;
    self.streamTestAlert = nil;
    _streamTestJPEGOffset = NSNotFound;
    VCJPEGParserReset(&_streamTestJPEGParserState);
    [task cancel];
    [session invalidateAndCancel];

    void (^showResult)(void) = ^{
        [self showStreamTestResultWithTitle:title message:message];
    };
    if (progressAlert.presentingViewController) {
        [progressAlert dismissViewControllerAnimated:YES completion:showResult];
    } else {
        showResult();
    }
}

- (void)showStreamTestResultWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Aceptar"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)dealloc {
    [self stopStatusRefreshTimer];
    [self.streamTestTask cancel];
    [self.streamTestSession invalidateAndCancel];
}

@end
