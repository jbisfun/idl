# Getting started

## Requirements

| Tool | Purpose | Install |
| --- | --- | --- |
| Zig 0.14.1 | builds `idl` | distro package or ziglang.org |
| Swift toolchain (clang, clang++, swiftc) | compiles for `arm64-apple-ios` | [swiftly](https://www.swift.org/install/linux/) |
| xtool + Darwin SDK | iPhoneOS SDK, `ld64.lld`, compiler-rt, Swift resources | [xtool](https://github.com/xtool-org/xtool), then `xtool setup` |
| ldid | ad-hoc signing | [ProcursusTeam/ldid](https://github.com/ProcursusTeam/ldid) release binary or distro package |

`idl` never installs anything. It looks for these tools, and `idl check` (and
every build) stops with an error that names whatever is missing. You do not
need Python, Make, `zip`, `unzip` or `llvm-objdump`: `idl` writes ZIPs, parses
Mach-O files and handles plists (with libplist) itself.

## Build idl

    zig build                         # Debug build in ./zig-out/bin/idl
    zig build -Doptimize=ReleaseSafe  # optimized build
    zig build test                    # unit tests

`zig build` downloads its dependencies, which are pinned in `build.zig.zon`:

- [zig-clap](https://github.com/Hejsil/zig-clap) 0.10.0: command-line parsing
- [zig-yaml](https://github.com/kubkon/zig-yaml) 0.1.1: `idlproj.yml` parsing
- [libplist](https://github.com/libimobiledevice/libplist) 2.8.1: property
  lists. It is fetched from git and compiled from C source by `build.zig`.

To use `idl` anywhere, copy `zig-out/bin/idl` into a directory on your `PATH`,
or use `zig build -p ~/.local`.

`idl init` creates only app source, `.gitignore` and `idlproj.yml`. Info.plist
and entitlements are generated from YAML; configure arbitrary keys under
`info:` and `entitlements:`. No source XML is required.

For asset catalogs, also run `zig build actool` with the Swift toolchain on
PATH. This helper uses shared Swift runtime libraries by default; use
`-Dactool-static=true` when distributing it independently of that toolchain.

## Check the toolchain

    idl check

Example output:

    sdk              ~/.swiftpm/.../iPhoneOS27.2.sdk
    sdk version      27.2
    swift resources  ~/.swiftpm/.../usr/lib/swift
    ld64.lld         ~/.swiftpm/.../toolset/bin/orig/ld64.lld
    compiler-rt      ~/.swiftpm/.../libclang_rt.ios.a
    clang            ~/.local/share/swiftly/bin/clang
    ...

If an entry says `missing`, install that tool, or set its location under
`toolchain:` in `idlproj.yml`. xtool is only required for `builder: xtool`
targets.

## Build the examples

    idl build                 # all targets
    idl build ObjCExample     # one target
    idl -v build              # print every compiler/linker command

Outputs:

    examples/objc-app/build/ObjCExample.ipa
    examples/swift-app/build/SwiftExample.ipa
    examples/xtool-swiftpm/xtool/XtoolExample.ipa

After every build, `idl verify` checks the IPA: ZIP CRCs, Info.plist keys, the
executable's mode, a thin arm64 `MH_EXECUTE` binary, `LC_MAIN`, the iOS
platform in `LC_BUILD_VERSION`, `LC_CODE_SIGNATURE` (unless the target is
unsigned), and that it depends only on system or bundled dylibs.

## Start your own app

    idl init MyApp --lang objc --bundle-id com.example.myapp
    cd MyApp
    idl build
    idl gen         # MyApp.xcodeproj + compile_commands.json

`idl` searches the current directory and its parents for `idlproj.yml`. Pass
`-f path/to/idlproj.yml` to use a different file.
