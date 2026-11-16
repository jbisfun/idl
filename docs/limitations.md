# Known limitations

## Signing and installing

- Signatures are ad-hoc `ldid` signatures. They make the bundle structurally
  complete but are not Apple provisioning. Re-sign before installing.
- No IPA built here has been installed or run on a device by this tooling. The
  checks are structural: ZIP, plist and Mach-O load commands.
- xtool targets are unsigned unless `sign: true`, which passes `--sign` to
  xtool and needs an xtool login.

## Xcode-only build steps

These tools have no Linux replacement here. Permissive builds warn and skip
their inputs; `--strict` rejects them before app compilation:

- Core Data models (`.xcdatamodeld`, `momc`).
- Metal shaders (`.metal`) are listed in generated Xcode projects but are not
  compiled by `direct` builds.

String Catalogs (`.xcstrings`), storyboards, XIBs and asset catalogs are
compiled on Linux, with the limits below.

## Storyboards and XIBs (`idl ibtool`)

The compiler is a Zig port of
[davidquesada/ibtool](https://github.com/davidquesada/ibtool), a
reverse-engineered NIB writer. Apple's format is undocumented, so:

- **Not verified on a device yet.** The output decodes with idl's own reader and
  has the same NIBArchive layout as Xcode's nibs, but no nib from `idl` has
  been loaded by UIKit on a device. Test before relying on it.
- **A subset of UIKit.** Supported elements: view controllers (plain,
  navigation, table), `view`, `label`, `button` (title per state), `imageView`,
  `textView`, `searchBar`, `navigationBar`/`navigationItem`/`barButtonItem`,
  `visualEffectView` with blur/vibrancy, `tableView` with prototype cells,
  frames, autoresizing masks, colors, fonts, constraints, outlets, actions and
  segues (`show`, `showDetail`, `presentation`, `push`, `modal`, `replace`,
  `custom`, and `rootViewController` relationships). `textField`, `switch`,
  `slider`, `scrollView`, `activityIndicatorView` and `progressView` get their
  class, frame and colors but none of their own attributes. Anything else (stack
  views, collection views, tab bar controllers, images, gesture recognizers,
  user-defined runtime attributes, trait variations, localization) is skipped
  with diagnostics in permissive builds; strict builds reject unsupported nodes
  and attributes before app compilation.
- **Safe-area layout guides** are treated as the view that owns them, so a
  constraint to the safe area pins to the view's edge instead.
- Constraints that refer to unsupported objects are dropped with a warning.
- Named colors (`systemColor` / `name`) resolve through the document's own
  `<resources>` section, so they become fixed colors and do not follow dark
  mode. Text styles become fixed-size system fonts.
- Only iOS documents (`targetRuntime="iOS.CocoaTouch"`). Each document produces
  one nib per view controller and view; there are no per-device-idiom
  variants.

## Asset catalogs (`.xcassets`, AssetKit)

Asset catalogs are compiled by `idl-actool`, a small Swift wrapper around
[xtool-org/AssetKit](https://github.com/xtool-org/AssetKit). It is a separate
binary because AssetKit is a Swift library.

- Build it with `zig build actool`. This needs `swift` on PATH. By default it
  uses the toolchain’s shared Swift runtime (about 1.2 MB here). Swift embeds
  a runtime search path pointing at that toolchain: if you remove it, rebuild
  `idl-actool`. Use `zig build actool -Dactool-static=true` for a standalone
  Swift runtime (about 59 MB here). xtool’s private embedded runtime cannot
  be shared with another executable.
- Only image sets, color sets and one app icon are supported, as far as AssetKit
  supports them. Data sets, symbol sets, sprite atlases, on-demand resource tags
  and named app icon alternates are not.
- App icons need an explicit `scale` for every image, e.g. iPhone `60x60` @2x
  and @3x. Xcode's single 1024 pt "universal" icon has no scale and AssetKit
  rejects it. The `app_icon` setting is not passed on: AssetKit uses whichever
  `.appiconset` the catalog has.
- One `.xcassets` per target. Merge catalogs if you have several.
- SVG images need `rsvg-convert` (librsvg) on PATH.
- Catalogs, storyboards, XIBs and strings are cached by input content and compiler
  identity. Direct-target bundling/signing/packaging also skip unchanged outputs.

## Project model

- `direct` targets can be apps, dynamic frameworks, dylibs, app extensions or
  static (objects + Swift module) targets; see "Products" in the configuration
  reference. Only apps are packaged; the other kinds are built for an app's
  `link`/`embed` lists. Watch apps, test bundles, XCFrameworks and real `.a`
  archives are not supported, and the generated Xcode project and xtool
  builder only handle app targets. Prebuilt `.framework` resources are copied
  to `Frameworks/` (without Headers, Modules or _CodeSignature) and ad-hoc
  signed, and `@executable_path/Frameworks` is always an rpath.
- Debug/release profiles are supported. Arbitrary additional configurations and
  profile-dependent source/dependency graphs are not. Omitting `-c` preserves
  the legacy unprofiled flags/output paths.
- Debug symbols stay in object files; no `.dSYM` archive/export is produced.
- C-family incremental compilation remains mtime/depfile-based; content-based
  caching applies to resources and final bundle/IPA state. This is a local cache,
  not a cross-machine hermetic/reproducible build guarantee.
- Resources are flattened into the bundle root like Xcode does, except that
  `*.lproj/` folders and package directories (`.bundle`, `.framework`,
  `.mlmodelc`) are kept. Two resources with the same file name are an error.
  A `.xcstrings` file and an `.lproj/Localizable.strings` resource that
  produce the same language file will conflict.
- Swift uses whole-module compilation, so changing a Swift source recompiles
  all Swift in the target. Debug compilation and linking are separate steps.
- Swift compiles before the target's C-family sources. If a target mixes them,
  idl generates `<Module>-Swift.h` and puts it on the include path, so
  Objective-C can `#import "<Name>-Swift.h"`. Swift calls Objective-C through
  `bridging_header`.
- Swift `defines` must be plain flags. `NAME=VALUE` only applies to C-family
  code.
- Only `arm64` device builds are tested. There is no simulator SDK.

## xtool builder

- xtool targets pass `resources:` to xtool.yml, which copies them verbatim into
  the app root (`.lproj` folders, plain files). Resources that need a compiler
  (`.xcassets`, storyboards, XIBs, `.xcstrings`, Core Data, Metal, Core ML) are
  rejected; use `builder: direct` for those. xtool manages its own build and
  packaging cache.

- SwiftPM cannot mix Swift and C-family files in one target, so an xtool
  target is either all Swift or all C/Objective-C. Use `builder: direct` for
  mixed code.
- An xtool target with Objective-C must not name its `main()` file `main.m`:
  SwiftPM would treat it as an executable target. The example uses
  `appmain.m`.
- The generated `Package.swift` has one library target. For anything more
  complex, write your own and set `package_swift: false`.

## Toolchain

- `idl-actool` must support `--version`; rebuild it with `zig build actool` when
  upgrading idl from a version whose helper lacked that command.
- xtool's entitlement-rewrite path can drop executable ZIP permission bits.
  idl normalizes the main executable's ZIP metadata without changing its code
  bytes or signature, then performs normal IPA verification.

- xtool's `ld64.lld` prints `This version of lld does not support linking for
  platform iOS`. The output is correct: the Mach-O has `LC_BUILD_VERSION`
  platform iOS. `idl verify` checks this.
- File and header paths are case-sensitive on Linux, unlike a default macOS
  volume.
- `idl` does not install or download tools. Install the Swift toolchain,
  Darwin SDK, ldid and xtool yourself. `idl check` lists what is missing.
  `idl-actool` is built from this repository with `zig build actool`.

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
