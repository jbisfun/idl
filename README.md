# iOS development on Linux

`idl` is a small Zig tool that builds Objective-C, Swift, C and C++ iOS apps
on Linux. One file, `idlproj.yml`, configures the toolchain and every app.
From that file `idl`:

- generates code: deterministic `.xcodeproj` projects with a shared scheme,
  `xtool.yml` + `Package.swift` for xtool, and `compile_commands.json` for
  clangd / sourcekit-lsp
- runs builds: it calls clang, swiftc, xtool's `ld64.lld` and `ldid`,
  processes Info.plist, compiles storyboards, XIBs and asset catalogs, copies
  resources, ad-hoc signs, writes the IPA, and checks the result

The build steps come from the Linux build used by LiveContainer.

## Quick start

    xtool setup                   # Darwin SDK -> ~/.swiftpm/swift-sdks/darwin.artifactbundle
    zig build                     # builds ./zig-out/bin/idl (Zig 0.14.1)
    ./zig-out/bin/idl check       # verify the toolchain
    zig build actool              # optional: .xcassets compiler (needs swift)
    ./zig-out/bin/idl build --strict -c release  # preflight, then build every example

Install on a phone through the running Jimpactor tray app:

    idl devices list
    idl install "JPs iPhone" MyApp

Start a new app:

    idl init MyApp --lang swift --bundle-id com.example.myapp
    cd MyApp && idl build

## Build automation

    idl check --strict -c release
    idl build --strict -c debug MyApp
    idl build --strict -c release MyApp

YAML `configurations:` overrides flags, bundle identity, metadata and entitlements.
Debug/release artifacts are isolated. Direct builds cache resource compilation,
bundling, signing and packaging; concurrent build/gen/clean operations are locked.
See [workflows](docs/workflows.md#strict-preflight-and-build-profiles).

## Layout

    idlproj.yml        configuration for the examples in this repository
    build.zig(.zon)    Zig build; pulls zig-clap, zig-yaml, zig-xml and libplist
    src/               the idl tool (see docs/architecture.md)
    tools/idl-actool/  Swift wrapper around AssetKit for .xcassets
    examples/          ObjC, Swift, storyboard/XIB/asset-catalog and xtool/SwiftPM
                       apps, plus xcconfig patterns
    docs/              documentation

## Documentation

- [Getting started](docs/getting-started.md)
- [idlproj.yml reference](docs/configuration.md)
- [Common workflows](docs/workflows.md)
- [Known limitations](docs/limitations.md)
- [Architecture](docs/architecture.md)

## Tests

    zig build test       # unit tests (config, plist, pbxproj, zip, Mach-O, nib, ibtool, ...)
    zig build check      # idl check
    zig build examples   # idl build --gen for every example (real arm64 builds)

Ad-hoc `ldid` signatures are not provisioning. Re-sign an IPA with your usual
signing or sideloading tool before you install it.
