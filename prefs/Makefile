TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = WeTypeEnhancePrefs

WeTypeEnhancePrefs_FILES = WTERootListController.m
WeTypeEnhancePrefs_INSTALL_PATH = /Library/PreferenceBundles
WeTypeEnhancePrefs_FRAMEWORKS = UIKit PhotosUI

# Preferences 是 iOS 私有框架：iOS SDK 里没有它的 .tbd，不能直接链接。
# 它在运行时由 Preferences 进程（设置 App）提供符号，因此：
#   1) 只加头文件搜索路径，让它能编译过
#   2) 用 dynamic_lookup 让链接器允许未定义符号（运行时再解析）
WeTypeEnhancePrefs_CFLAGS = -fobjc-arc \
  -Wno-deprecated-declarations \
  -Wno-int-conversion \
  -Wno-incompatible-pointer-types \
  -Wno-implicit-function-declaration
WeTypeEnhancePrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk
