# Known limitations

## Signing and installing

- Signatures are ad-hoc `ldid` signatures. They make the bundle structurally
  complete but are not Apple provisioning. Re-sign before installing.
- No IPA built here has been installed or run on a device by this tooling. The
  checks are structural: ZIP, plist and Mach-O load commands.
- xtool targets are unsigned unless `sign: true`, which passes `--sign` to
  xtool and needs an xtool login.

## Xcode-only build steps

These tools are macOS binaries and do not run on Linux. `idl` skips their
inputs with a warning:

- asset catalogs (`.xcassets`, needs `actool`): no compiled `Assets.car` and
  no app icon. Ship PNGs as plain resources or build the catalog on a Mac.
- storyboards and XIBs (`ibtool`): build the UI in code. Note that
  `UILaunchScreen` in Info.plist does not need a storyboard.
- Core Data models (`.xcdatamodeld`, `momc`).
- Metal shaders (`.metal`) are listed in generated Xcode projects but are not
  compiled by `direct` builds.

String Catalogs (`.xcstrings`) are supported: `idl` converts them itself.

## Project model

- Each target is one iOS application. There are no app extensions, frameworks,
  static-library targets, watch apps or test bundles, either as build targets
  or in the generated Xcode project. Prebuilt `.framework` resources are
  copied to `Frameworks/` and ad-hoc signed, and `@executable_path/Frameworks`
  is always an rpath. Building frameworks or extensions from source is not
  supported.
- There is one build configuration: `opt`/`swift_opt` select it. The
  generated Xcode project still has Debug and Release.
- Resources are flattened into the bundle root like Xcode does, except that
  `*.lproj/` folders and package directories (`.bundle`, `.framework`,
  `.mlmodelc`) are kept. Two resources with the same file name are an error.
  A `.xcstrings` file and an `.lproj/Localizable.strings` resource that
  produce the same language file will conflict.
- Swift is built in a single whole-module invocation, so changing any Swift
  file recompiles all Swift in the target.
- Objective-C cannot call Swift: no `<Module>-Swift.h` header is generated.
  Swift can call Objective-C through `bridging_header`.
- Swift `defines` must be plain flags. `NAME=VALUE` only applies to C-family
  code.
- Only `arm64` device builds are tested. There is no simulator SDK.

## xtool builder

- SwiftPM cannot mix Swift and C-family files in one target, so an xtool
  target is either all Swift or all C/Objective-C. Use `builder: direct` for
  mixed code.
- An xtool target with Objective-C must not name its `main()` file `main.m`:
  SwiftPM would treat it as an executable target. The example uses
  `appmain.m`.
- The generated `Package.swift` has one library target. For anything more
  complex, write your own and set `package_swift: false`.

## Toolchain

- xtool's `ld64.lld` prints `This version of lld does not support linking for
  platform iOS`. The output is correct: the Mach-O has `LC_BUILD_VERSION`
  platform iOS. `idl verify` checks this.
- File and header paths are case-sensitive on Linux, unlike a default macOS
  volume.
- `idl` does not install or download tools. Install the Swift toolchain,
  Darwin SDK, ldid and xtool yourself. `idl check` lists what is missing.

## Configuration parsing (zig-yaml 0.1.x)

`idl` uses the subset of YAML that config files need. Known issues with the
library:

- A key with an empty value followed by a sibling key (`key:` then
  `other: x`) is parsed as a nested mapping. Write `key: ~` or leave the key
  out.
- Comments and trailing whitespace are removed before parsing, so
  `key: value  # note` works. A `#` inside quotes or one not preceded by
  whitespace (`url: http://x/#frag`) is kept. Multi-line quoted strings and
  block scalars (`|`, `>`) are not supported.
- Anchors, aliases and tags are not supported.

## Packaging

- The IPA writer does not support ZIP64, so an IPA and each file in it must be
  smaller than 4 GiB. Timestamps are fixed at 1980-01-01 so output is
  reproducible.
- Symlinks are rejected in sources, resources, package directories and Xcode
  project output, and are never written into an IPA.
