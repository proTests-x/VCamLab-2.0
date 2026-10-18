export THEOS_PACKAGE_SCHEME = rootless
export TARGET = iphone:clang:16.5:15.0
ARCHS ?= arm64 arm64e
export ARCHS

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AVFCameraSupport VCMediaServer VCFloatingControl

VC_SHARED_FILES = AVAssetStreamAdapter.m VCPreferences.m VCStreamCoordinator.m VCFrameConverter.m \
	VCSharedMediaBus.m VCAudioSampleConverter.m VCScreenCaptureSource.m VCLocalMediaSource.m

AVFCameraSupport_FILES = Tweak.x $(VC_SHARED_FILES)
AVFCameraSupport_CFLAGS = -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
AVFCameraSupport_FRAMEWORKS = UIKit AVFoundation AudioToolbox CoreImage CoreMedia CoreVideo QuartzCore CoreGraphics Foundation ImageIO IOSurface VideoToolbox
AVFCameraSupport_LDFLAGS = -Wl,-dead_strip
AVFCameraSupport_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

VCMediaServer_FILES = MediaServer.x $(VC_SHARED_FILES)
VCMediaServer_CFLAGS = -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
VCMediaServer_FRAMEWORKS = AVFoundation AudioToolbox CoreImage CoreMedia CoreVideo QuartzCore CoreGraphics Foundation ImageIO IOSurface VideoToolbox
VCMediaServer_LDFLAGS = -Wl,-dead_strip
VCMediaServer_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

VCFloatingControl_FILES = VCFloatingControl.x VCPreferences.m
VCFloatingControl_CFLAGS = -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
VCFloatingControl_FRAMEWORKS = UIKit QuartzCore Foundation
VCFloatingControl_LDFLAGS = -Wl,-dead_strip
VCFloatingControl_INSTALL_PATH = /Library/MobileSubstrate/DynamicLibraries

INSTALL_TARGET_PROCESSES = SpringBoard Camera mediaserverd

before-package:: $(THEOS_STAGING_DIR)/DEBIAN/control
	chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/postrm"
	install -d "$(THEOS_STAGING_DIR)/usr/bin"
	install -m 0755 "$(THEOS_PROJECT_DIR)/setup-config.sh" \
		"$(THEOS_STAGING_DIR)/usr/bin/virtualcampro-config"

SUBPROJECTS += prefs

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
