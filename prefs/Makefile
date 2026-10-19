include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = VirtualCamPro

VirtualCamPro_FILES = VCPRootListController.m VCPApplicationSelectorController.m
VirtualCamPro_FRAMEWORKS = UIKit Foundation AVFoundation PhotosUI UniformTypeIdentifiers
VirtualCamPro_PRIVATE_FRAMEWORKS = Preferences
VirtualCamPro_INSTALL_PATH = /Library/PreferenceBundles
VirtualCamPro_RESOURCE_FILES = Info.plist
VirtualCamPro_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/bundle.mk
