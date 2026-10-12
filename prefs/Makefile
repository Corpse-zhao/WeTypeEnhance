TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = WeTypeEnhancePrefs

WeTypeEnhancePrefs_FILES = WTERootListController.m
WeTypeEnhancePrefs_INSTALL_PATH = /Library/PreferenceBundles
WeTypeEnhancePrefs_FRAMEWORKS = UIKit
WeTypeEnhancePrefs_PRIVATE_FRAMEWORKS = Preferences
WeTypeEnhancePrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
