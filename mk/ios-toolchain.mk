# Shared Linux -> iOS toolchain configuration.
# Include this after defining ROOT, BUILD, ARCH and MIN_IOS.

ARCH ?= arm64
MIN_IOS ?= 16.0
DARWIN_SDK_BUNDLE ?= $(HOME)/.swiftpm/swift-sdks/darwin.artifactbundle
SDK ?= $(firstword $(wildcard $(DARWIN_SDK_BUNDLE)/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS*.sdk))
SWIFT_RESOURCE_DIR ?= $(DARWIN_SDK_BUNDLE)/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift
PLATFORM_LIB_DIR ?= $(DARWIN_SDK_BUNDLE)/Developer/Platforms/iPhoneOS.platform/Developer/usr/lib
LD64 ?= $(DARWIN_SDK_BUNDLE)/toolset/bin/orig/ld64.lld
CLANG_RT ?= $(firstword $(wildcard $(DARWIN_SDK_BUNDLE)/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/*/lib/darwin/libclang_rt.ios.a))

SWIFTLY_BIN ?= $(HOME)/.local/share/swiftly/bin
export PATH := $(PATH):$(SWIFTLY_BIN)
ifeq ($(origin CC),default)
CC := clang
endif
ifeq ($(origin CXX),default)
CXX := clang++
endif
SWIFTC ?= swiftc
PYTHON ?= python3
ZIP ?= zip

BUILD ?= build
MODULE_CACHE ?= $(abspath $(BUILD)/ModuleCache)
TARGET := $(ARCH)-apple-ios$(MIN_IOS)
OPT ?= -Os

IOS_CFLAGS = -target $(TARGET) -isysroot $(SDK) $(OPT) -g0 -fmodules   -fmodules-cache-path=$(MODULE_CACHE) -fno-common -MMD -MP
IOS_OBJCFLAGS = $(IOS_CFLAGS) -fobjc-arc -fobjc-weak -std=gnu17
IOS_CXXFLAGS = $(IOS_CFLAGS) -std=gnu++20 -stdlib=libc++
IOS_SWIFTFLAGS = -target $(TARGET) -sdk $(SDK) -resource-dir $(SWIFT_RESOURCE_DIR)   -I $(PLATFORM_LIB_DIR) -L $(PLATFORM_LIB_DIR) -module-cache-path $(MODULE_CACHE)   -O -wmo -suppress-warnings
IOS_LDFLAGS = -target $(TARGET) -isysroot $(SDK) -fuse-ld=lld --ld-path=$(LD64)   -Wl,-dead_strip -Wl,-headerpad_max_install_names $(CLANG_RT)
IOS_SWIFT_LDFLAGS = $(IOS_SWIFTFLAGS) -use-ld=lld -ld-path=$(LD64)   -Xlinker -dead_strip -Xlinker -headerpad_max_install_names -Xlinker $(CLANG_RT)

LDID ?= $(ROOT)/build/tools/ldid
LDID_VERSION ?= v2.1.5-procursus7
LDID_URL ?= https://github.com/ProcursusTeam/ldid/releases/download/$(LDID_VERSION)/ldid_linux_$(shell uname -m)

.PHONY: toolchain-check

toolchain-check:
	@set -eu; 	for tool in $(CC) $(SWIFTC) $(PYTHON) $(ZIP) curl unzip; do 	  command -v $$tool >/dev/null || { echo "missing tool: $$tool" >&2; exit 1; }; 	done; 	for path in "$(SDK)" "$(SWIFT_RESOURCE_DIR)" "$(LD64)" "$(CLANG_RT)"; do 	  test -e "$$path" || { echo "missing toolchain path: $$path" >&2; echo "run: xtool setup" >&2; exit 1; }; 	done; 	echo "target: $(TARGET)"; 	echo "sdk: $(SDK)"; 	echo "clang: $$(command -v $(CC))"; 	echo "swiftc: $$(command -v $(SWIFTC))"; 	echo "ld64.lld: $(LD64)"

$(LDID):
	@mkdir -p $(@D)
	@echo "  FETCH ldid $(LDID_VERSION)"
	@curl -fsSL -o $@ $(LDID_URL)
	@chmod +x $@
