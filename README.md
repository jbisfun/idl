# iOS development on Linux

A small, working toolkit for building Objective-C and Swift iOS apps on Linux.
It extracts the reusable pieces of the Linux build used by LiveContainer:
Darwin SDK discovery, clang/Swift compiler flags, `ld64.lld`, compiler-rt,
Info.plist processing, ad-hoc signing, IPA packaging, and validation.

## What is included

- `mk/ios-toolchain.mk` — shared GNU Make configuration for clang, Swift,
  the xtool Darwin SDK, `ld64.lld`, compiler-rt, ldid, packaging, and checks.
- `templates/objc-app` — programmatic UIKit app built with Objective-C/ARC.
- `templates/swift-app` — programmatic UIKit app built with Swift.
- `templates/xtool-swiftpm` — minimal Objective-C UIKit app packaged as a SwiftPM project for `xtool dev`.
- `tools/plisttool.py` — expand Xcode-style `$(VAR)` values and edit plists;
  also converts `.xcstrings` catalogs into `.strings`/`.stringsdict` files.
- `tools/verify_ipa.py` — checks ZIP integrity, bundle metadata, executable mode,
  Mach-O magic, and optionally load commands with `llvm-objdump`.
- `xcconfigs/` — generic bundle-ID/team configuration patterns for Xcode projects.

## Requirements

Install a Linux Swift toolchain with [swiftly], install [xtool], then download
its Darwin SDK:

    xtool setup
    make check

The default SDK location is:

    ~/.swiftpm/swift-sdks/darwin.artifactbundle

Override it with `DARWIN_SDK_BUNDLE=/path/to/darwin.artifactbundle`.
The Makefiles expect `swiftc` and `clang` from a modern Swift toolchain. The
Swiftly bin directory is appended to `PATH` automatically.

## Build the examples

    make objc
    make swift
    make examples

Outputs:

    templates/objc-app/build/ObjCExample.ipa
    templates/swift-app/build/SwiftExample.ipa
    templates/xtool-swiftpm/xtool/XtoolExample.ipa

The direct Makefile examples receive an ldid ad-hoc signature so their bundles
are structurally complete; the default xtool `ipa` target is unsigned. Neither
is an Apple provisioning profile: re-sign the IPA with your normal
sideloading/signing tool before installing it.

Each template can be copied and renamed. Its important configuration is near the
top of its Makefile:

    APP := MyApp
    BUNDLE_ID := com.example.myapp
    MIN_IOS := 16.0

## xtool SwiftPM project

The xtool template demonstrates the smaller path for a SwiftPM-compatible app:

    cp -r templates/xtool-swiftpm MyApp
    cd MyApp
    xtool dev build -c release --ipa

Use the direct Makefile templates when you need exact control, a mixed-language
build, custom framework/dylib targets, or an existing Xcode project that cannot
be represented as a Swift package.

## Reusable compiler/linker configuration

`mk/ios-toolchain.mk` exports:

- `SDK`, `SWIFT_RESOURCE_DIR`, `PLATFORM_LIB_DIR`
- `CC`, `CXX`, `SWIFTC`, `LD64`, `CLANG_RT`, `LDID`
- `IOS_CFLAGS`, `IOS_OBJCFLAGS`, `IOS_CXXFLAGS`
- `IOS_SWIFTFLAGS`, `IOS_LDFLAGS`, `IOS_SWIFT_LDFLAGS`

Notable details learned from real Linux builds:

- Use xtool's `toolset/bin/orig/ld64.lld`; the host linker may reject modern
  arm64e SDK stubs.
- Swift needs the Darwin SDK's `-resource-dir`, or `SwiftShims` is missing.
- Link `libclang_rt.ios.a` for helpers such as `__isPlatformVersionAtLeast`.
- On Linux, framework/header paths are case-sensitive.
- Xcode tools such as `actool`, `ibtool`, and `xcstringstool` are macOS binaries;
  use programmatic UI and the included plist/xcstrings helper, or prebuild assets.
- Sign embedded frameworks/extensions before signing the containing executable.

## Tests and validation

    make test
    make examples

`make examples` performs real arm64 iOS compilation, links and signs both apps,
packages IPAs, verifies ZIP CRCs, and runs `tools/verify_ipa.py`.

[swiftly]: https://www.swift.org/install/linux/
[xtool]: https://github.com/xtool-org/xtool
