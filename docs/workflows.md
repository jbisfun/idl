# Common workflows

All commands accept `--help`, e.g. `idl build --help`.

## Build, then rebuild only what changed

    idl build              # every target
    idl build MyApp -j 8   # one target, 8 parallel compile jobs
    idl -v build           # print every command (or: idl build -v)

C-family objects reuse clang's `.d` header dependencies, input mtimes and a
command/tool-version fingerprint in `<object>.cmd`. Linking reruns when its
inputs or command/tool fingerprint change.

For direct targets, compiled resources use SHA-256 content fingerprints,
including directory membership, deployment target, strictness, idl and external
resource compiler identities. Same-size edits with preserved mtimes, additions,
deletions and changed compiler versions invalidate the cache. Cached output
content is checked too: missing or corrupted files are rebuilt.

If the executable, resource outputs, generated metadata, entitlements and signer
are unchanged, the bundle, signature and IPA are reused. Otherwise a new payload
is assembled in `Payload.partial`, signed and packaged; deleted resources cannot
linger. `idl build -v` reports cache hits. `idl clean MyApp -c debug` clears that
profile's artifacts/cache. Old content-addressed resource entries remain until
cleaned. xtool still manages its own incremental build and packaging.

## Strict preflight and build profiles

    idl check --strict -c release MyApp  # tools + inputs + resources, no app compile
    idl build --strict -c debug MyApp
    idl build --strict -c release --gen
    idl install "My iPhone" -c debug MyApp
    idl gen -c debug MyApp

Before compiling any application source, idl checks tools for *all selected
targets*, executes compiler/helper version probes (including `idl-actool`, so
missing shared-runtime libraries are caught), processes metadata, prepares
resources and checks their complete bundle-output plan. A bad later target
therefore cannot cause an earlier target to be compiled first. Resource
preparation may run resource compilers and populate caches during `idl check`.
Nothing is installed or downloaded.

`--strict` (or `strict: true` in YAML) rejects unsupported IB elements/attributes,
unresolved references and compiler warnings; unsupported Core Data, Metal and
Core ML inputs; and unsupported asset package types. Missing storyboard/nib
resources (including scene-manifest references), duplicate generated/raw outputs,
reserved-output collisions and inconsistent bundle identities always fail.
Permissive mode diagnoses unsupported inputs instead of silently ignoring them.
Strictness does not certify UIKit runtime compatibility or eliminate documented
safe-area/color approximations.

Builds, preflight, project generation and clean hold a nonblocking OS lock at
`<target>/.idl/build.lock`. Conflicts fail with a `build directory busy` message;
there is no stale PID file to remove. The lock is per target directory, across
profiles, because xtool and generated project files share paths. Do not delete
`.idl/` while an operation is running. Different target directories can build
concurrently. See [configuration](configuration.md#configurations) for profile
merging and output paths.

## Regenerate project files

    idl gen                # all targets
    idl gen MyApp
    idl build --gen        # regenerate, then build

`gen` writes whatever the target asks for: `.xcodeproj`,
`compile_commands.json`, and for xtool targets `xtool.yml` and `Package.swift`.
The output is deterministic, so running it twice gives identical files and
version-control diffs only show real changes.

To write a single Xcode project somewhere else:

    idl xcodeproj MyApp --output /tmp/MyApp.xcodeproj

Generated projects use paths relative to the project's location and get a
shared scheme, so they open directly in Xcode on a Mac.

## Editor support on Linux

Set `compile_commands: true` (for all targets, put it under `defaults:`) and
run `idl gen`. clangd reads `compile_commands.json` from the target
directory, and the Swift entries contain the full swiftc command for
sourcekit-lsp. Run `idl build` once so `build/ModuleCache` exists.

## Add a new app to an existing idlproj.yml

```yaml
targets:
  - name: Second
    dir: apps/second
    bundle_id: com.example.second
    sources: [Sources]
    entitlements:
      get-task-allow: true
```

To get starter files, run `idl init Second --dir apps/second` and then move
its target entry into your main `idlproj.yml`.

## Mix Swift, Objective-C and C++

```yaml
sources: [Sources]                 # .swift, .m, .mm, .cpp all together
bridging_header: Sources/Bridge.h  # Objective-C declarations Swift can see
include_dirs: [Sources]
```

clang compiles every C-family file to an object. swiftc then compiles all Swift
files in one module and links the objects. C++ adds `-lc++`.

## Info.plist values per build

```yaml
plist_vars:
  ENV_NAME: staging
info:
  CFBundleDisplayName: MyApp $(ENV_NAME)
```

For a value that differs between machines or CI runs, reference an
environment variable directly: an unknown `$(VAR)` falls back to the process
environment.

## Storyboards, XIBs and asset catalogs

List them as resources like any other file. `idl build` compiles them into the
bundle:

| Resource | Bundle output | Compiled by |
| --- | --- | --- |
| `Main.storyboard` | `Main.storyboardc/` | `idl` (ibtool port) |
| `Banner.xib` | `Banner.nib` | `idl` (ibtool port) |
| `Assets.xcassets` | `Assets.car`, app icon PNGs, Info.plist icon keys | `idl-actool` (AssetKit) |

Asset catalogs need `idl-actool`, which is built once:

    zig build actool             # installs zig-out/bin/idl-actool next to idl
    zig build actool -p zig-out/release   # if you use the release build

`idl` looks for `toolchain.actool` on PATH, then next to its own executable.
Set `info.UIMainStoryboardFile` / `info.UILaunchStoryboardName` in YAML to the
storyboard names (without extension). `examples/ib-app` uses all three.

To compile or inspect a single file:

    idl ibtool Main.storyboard -o /tmp/Main.storyboardc
    idl ibtool Banner.xib --dump          # compile and print the objects
    idl ibtool Some.nib --dump --types    # dump any NIBArchive, even Xcode's

See [limitations](limitations.md#storyboards-and-xibs-idl-ibtool) for what is
supported.

## Install on a device (through Jimpactor)

`idl`'s ad-hoc `ldid` signature is not a provisioning profile. With the
[Jimpactor](https://github.com/jpdagostin0/jimpactor) tray app running, `idl`
can hand IPAs to it, and Jimpactor signs them with your account and installs
them:

    idl devices list                   # devices Jimpactor can reach
    idl install "My iPhone"            # build every target, then install each IPA
    idl install 00008130 MyApp         # device by UDID prefix, one target
    idl install 00008130-... --no-build MyApp   # install the last build
    idl install 00008130-... --ipa ~/Downloads/Other.ipa

`<device>` is a UDID, a unique UDID prefix (4+ characters), or a device name
(case-insensitive). `idl` resolves the device before building, so a closed
Jimpactor or an unknown device fails early. Install progress from Jimpactor
is printed as it arrives.

Jimpactor's IPC protocol (version 1): `idl` connects to 127.0.0.1 on the port
in `<data>/relaunch.port` and sends the token from `<data>/ipc.token`. `<data>`
is `$XDG_CONFIG_HOME/Jimpactor` or `~/.config/Jimpactor`, or
`toolchain.jimpactor_dir` when that's set.

Without Jimpactor, re-sign the IPA with any other tool (AltStore, Sideloadly,
`xtool dev build --sign`, ...).

## Check an IPA from anywhere

    idl verify Some.ipa --bundle-id com.example.app
    idl verify unsigned.ipa --allow-unsigned

## Standalone plist and string-catalog tools

    idl plist -i Info.plist -o out.plist \
        --var PRODUCT_BUNDLE_IDENTIFIER=com.example.app \
        --set CFBundleVersion=42 --set UIRequiredDeviceCapabilities='["arm64"]' \
        --default LSRequiresIPhoneOS=true --delete NSExampleKey
    idl xcstrings Localizable.xcstrings build/strings   # -> <lang>.lproj/Localizable.strings(dict)

`--set` and `--default` treat `[..]`, `{..}`, `true`, `false` and integers as
JSON (parsed by libplist). Everything else is a string.

## Clean

    idl clean          # direct: build/; xtool: .build .bsp xtool/; plus a generated .xcodeproj
    idl clean MyApp

## Use from zig build

The repository's `build.zig` has wrappers around the CLI:

    zig build run -- build MyApp
    zig build check
    zig build examples
