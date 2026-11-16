# idlproj.yml reference

`idlproj.yml` is the only configuration file. It has four top-level keys:

```yaml
toolchain: { ... }   # optional: where the compilers and SDK live
defaults:  { ... }   # optional: target keys applied to every target
configurations: { ... } # optional: debug/release overrides
targets:   [ ... ]   # required: one entry per app
```

`idl` rejects unknown keys, so a typo such as `sorces:` is an error instead of
being ignored. Write version numbers as text and quote them when you like:
`min_ios: 16.0` and `min_ios: "16.0"` both mean the string `16.0`, and
`16.10` is never read as a float.

## toolchain

| Key | Default | Meaning |
| --- | --- | --- |
| `sdk_bundle` | `~/.swiftpm/swift-sdks/darwin.artifactbundle` | Darwin SDK bundle from `xtool setup` |
| `sdk` | newest `iPhoneOS*.sdk` in the bundle | explicit SDK path |
| `swiftly_bin` | `~/.local/share/swiftly/bin` | added to the end of `PATH` for every tool idl runs |
| `cc` / `cxx` / `swiftc` | `clang` / `clang++` / `swiftc` | compilers, looked up by name on `PATH` or given as paths |
| `xtool` | `xtool` | xtool executable (needed for `builder: xtool`) |
| `ldid` | `ldid` | ldid path or command name (needed when a target signs) |
| `jobs` | `0` | number of parallel compile jobs (`0` = number of CPUs) |
| `actool` | `idl-actool` | asset catalog compiler (`zig build actool`); a path, or a name looked up on PATH and next to `idl` |
| `jimpactor_dir` | `$XDG_CONFIG_HOME/Jimpactor` or `~/.config/Jimpactor` | Jimpactor data dir, used by `idl devices` and `idl install` |

`~` is expanded in paths.

## targets

Each target is a mapping. Paths inside a target are relative to its `dir`, and
they must stay inside it (no absolute paths, no `..`).

### Identity

| Key | Default | Meaning |
| --- | --- | --- |
| `name` | required | product name, executable name, and Xcode target name |
| `bundle_id` | required | `CFBundleIdentifier` |
| `dir` | `.` | target directory, relative to `idlproj.yml` |
| `builder` | `direct` | `direct` (idl runs clang/swiftc) or `xtool` (idl runs `xtool dev build`) |
| `version` | `1.0` | `MARKETING_VERSION` / `CFBundleShortVersionString` |
| `build_number` | `1` | `CURRENT_PROJECT_VERSION` / `CFBundleVersion` |
| `min_ios` | `16.0` | deployment target, triple suffix and `MinimumOSVersion` |

### Sources and compilation

| Key | Default | Meaning |
| --- | --- | --- |
| `sources` | `[Sources]` | files or directories, scanned recursively. Supported: `.c .m .mm .cc .cpp .cxx .s .S .swift` |
| `arch` | `arm64` | target architecture |
| `opt` | `-Os` | optimization flag for C-family code |
| `swift_opt` | `-O` | optimization flag for Swift |
| `debug_symbols` | `false` | emit DWARF in C-family and Swift objects |
| `strict` | `false` | reject unsupported resources and IB features rather than warn/skip |
| `swift_version` | `5.0` | written to the Xcode project |
| `defines` | `[]` | `NAME` or `NAME=VALUE`. Both forms go to C-family code; only `NAME` goes to Swift |
| `include_dirs` | `[]` | `-I` for clang and swiftc |
| `bridging_header` | none | Objective-C header that Swift imports (`-import-objc-header`) |
| `quote_include_dirs` | `[]` | `-iquote` dirs (clang, and swiftc via `-Xcc`): only `#include "..."` sees them, like Xcode's header map |
| `framework_dirs` | `[]` | `-F` dirs for clang, swiftc and the linker |
| `dead_strip` | `true` | pass `-dead_strip` to the linker |
| `cflags` / `swiftflags` | `[]` | extra compiler flags |
| `ldflags` | `[]` | extra linker arguments, each passed as `-Xlinker <arg>` |
| `frameworks` | `[UIKit, Foundation]` | SDK frameworks (`X` or `X.framework`) |
| `weak_frameworks` | `[]` | weakly linked frameworks |
| `libraries` | `[]` | `-l` libraries, e.g. `[z, sqlite3]` |
| `build_dir` | `build` | where objects, the app bundle and the IPA go |

If a target has any `.swift` file, swiftc compiles all Swift sources in one
whole-module compilation and links the clang-compiled objects. Debug builds
compile Swift to a persistent `.swift.o` and link separately, retaining DWARF
without requiring `dsymutil`. Otherwise clang links. C++ sources add `-lc++`.

### Bundle

| Key | Default | Meaning |
| --- | --- | --- |
| `info_plist` | none | optional base Info.plist (XML, binary, JSON or OpenStep); otherwise generated entirely from YAML |
| `info` | none | keys merged into Info.plist (see below) |
| `plist_vars` | none | extra `$(VAR)` values for Info.plist and entitlements |
| `entitlements` | none | YAML mapping of entitlement keys, or an explicit legacy plist path; no capabilities are added implicitly |
| `resources` | `[]` | files or directories copied into the bundle (see [limitations](limitations.md)) |
| `sign` | `true` for `direct`, `false` for `xtool` | ad-hoc sign with ldid / pass `--sign` to xtool |
| `app_icon` | `AppIcon` | asset-catalog icon name in the Xcode project |
| `icon` | none | xtool targets only: a PNG copied to the app root and set as `CFBundleIconFile` (xtool `iconPath`) |
| `device_family` | `1,2` | generated `UIDeviceFamily` and Xcode `TARGETED_DEVICE_FAMILY` |

Info.plist processing, in order:

1. Start with an empty dictionary (or the explicit `info_plist` base). Add any missing standard keys: `CFBundleExecutable`, `CFBundleIdentifier`,
   `CFBundleName`, `CFBundlePackageType`, `CFBundleInfoDictionaryVersion`,
   `CFBundleShortVersionString`, `CFBundleVersion`. Also default display name
   to the target name, development region to `en`, `LSRequiresIPhoneOS` to true,
   device family to `device_family`, orientations to portrait, and `UILaunchScreen`
   to an empty dictionary unless a launch storyboard is configured.
2. Merge the `info:` mapping. Unquoted `true`/`false` become booleans,
   unquoted integers become `<integer>`, lists become arrays, mappings become
   dictionaries, and quoted values stay strings. Version keys such as
   `CFBundleVersion` always stay strings.
3. Set `MinimumOSVersion` to `min_ios`.
4. For direct builds, merge the asset compiler’s generated icon keys.
5. Expand `$(VAR)`, `${VAR}` and `$(VAR:modifier)` in every string. Values
   come from `plist_vars`, then the built-in variables, then the environment.
   Unknown variables become empty strings. The modifier is ignored.

Built-in variables: `EXECUTABLE_NAME`, `PRODUCT_NAME`, `TARGET_NAME`,
`PRODUCT_MODULE_NAME`, `PRODUCT_BUNDLE_IDENTIFIER`,
`PRODUCT_BUNDLE_PACKAGE_TYPE`, `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`,
`IPHONEOS_DEPLOYMENT_TARGET`, `DEVELOPMENT_LANGUAGE`.

No hand-written XML is required:

```yaml
targets:
  - name: MyApp
    bundle_id: com.example.myapp
    version: "1.0"
    build_number: "1"
    info:
      CFBundleDisplayName: My App
      NSCameraUsageDescription: Take a profile photo
      UIMainStoryboardFile: Main
      UILaunchStoryboardName: LaunchScreen
      UIBackgroundModes: [audio]
    entitlements:
      get-task-allow: true
      com.apple.security.application-groups: ["group.com.example.myapp"]
```

Omit storyboard keys for a programmatic UI. Omit `entitlements` when no
capabilities are needed; `get-task-allow` is opt-in, not a release default.
Entitlements support the same YAML types and variable expansion as `info`.
They are requests, not provisioning: Apple capabilities still need an
appropriate signing identity/profile. An explicit `info_plist` or string-valued
`entitlements: Support/App.entitlements` remains supported. Missing explicit
files are errors, never silently ignored.

`idl gen` and `idl xcodeproj` write `.idl/Info.plist` and, when configured,
`.idl/Entitlements.plist` inside each target directory. Xcode and xtool reference
these generated files. Run `idl gen` after editing YAML before building in
Xcode. Both `.idl/debug/` and `.idl/release/` metadata sets are also generated;
Xcode configurations reference their matching set. Variables are expanded at
generation time using each profile, not re-evaluated from YAML by Xcode.
Direct builds generate bundle metadata themselves; xtool metadata is regenerated
before each xtool build. `.idl/` is disposable and should be gitignored.

### Products

| Key | Default | Meaning |
| --- | --- | --- |
| `type` | `app` | `app`, `framework`, `dylib`, `appex` or `static` |
| `link` | `[]` | project `framework`/`dylib`/`static` targets to link against |
| `embed` | `[]` | apps only: project `framework`/`dylib`/`appex` targets to copy into the bundle |
| `post_build` | `[]` | apps only: command (argv) run after the IPA is built and verified |

`idl build X` builds X plus every target it links or embeds, with dependencies
first. Cycles are an error. Each kind produces:

- `framework`: `<build>/products/<name>.framework` (binary, generated Info.plist
  with `FMWK`, resources), install name `@rpath/<name>.framework/<name>`, bundle
  signed with ldid. Dependents link with `-F <build>/link -framework <name>`.
  Apps embed it under `Frameworks/`.
- `dylib`: `<build>/products/<name>.dylib`, install name `@rpath/<name>.dylib`,
  embedded under `Frameworks/`. No `bundle_id`, Info.plist or resources.
- `appex`: `<build>/products/<name>.appex` (Info.plist with `XPC!`, entitlements,
  signed with `-I<bundle_id>`), built with `-fapplication-extension` /
  `-application-extension`. Rpaths include `@executable_path/../../Frameworks`.
  Apps embed it under `PlugIns/`. The entry point comes from `ldflags` (e.g.
  `[-e, _NSExtensionMain]`) or a Swift `@main`.
- `static`: compiled objects plus `<name>.swiftmodule` and `<name>-Swift.h`. A
  linking target receives the objects in its link, `-I` for the module, and the
  header dir. Not signed. No `bundle_id`.

Swift in non-app targets is compiled with `-parse-as-library` and module name
`<name>`. `post_build` runs in the target directory with `IDL_IPA`, `IDL_APP`,
`IDL_BUILD_DIR`, `IDL_TARGET` (and `IDL_CONFIGURATION` with `-c`) set.

In `info:`, `Key: ~` removes a key inherited from `info_plist`. Info.plist and
entitlement expansion can also use `$(GIT_BRANCH)` and `$(GIT_COMMIT)` from the
project root's git checkout (environment variables override them). Source and
resource entries may use `*` in their last path component, e.g.
`Resources/*.lproj`.

### Code generation

| Key | Default | Generates |
| --- | --- | --- |
| `xcodeproj` | `false` | `<dir>/<name>.xcodeproj` (project + shared scheme) |
| `compile_commands` | `false` | `<dir>/compile_commands.json` (direct targets only) |
| `package_swift` | `true` | `<dir>/Package.swift` (xtool targets only) |
| `configuration` | `release` | xtool build configuration (`debug`/`release`) |

xtool targets always get a generated `xtool.yml`. Generated files start with a
`Generated by idl from idlproj.yml` marker, and `idl` refuses to overwrite a
file without that marker. To keep a hand-written `Package.swift`, set
`package_swift: false`.

An xtool target must have exactly one `sources` entry: the SwiftPM target
directory.

## configurations

Select with `-c debug` / `--configuration release` on `build`, `install`,
`check`, `gen`, `xcodeproj`, `list` and `clean`:

```yaml
configurations:
  debug:
    info:
      CFBundleDisplayName: My App Debug
  release:
    defines: [PRODUCTION]
    entitlements:
      get-task-allow: false

targets:
  - name: MyApp
    bundle_id: com.example.myapp
    configurations:
      debug:
        bundle_id: com.example.myapp.debug
        entitlements:
          get-task-allow: true
```

Built-in debug settings: `opt: -O0`, `swift_opt: -Onone`, `debug_symbols: true`,
and an additional `DEBUG` define. Built-in release settings: `-Os`, `-O`, no
DWARF; an inherited YAML `get-task-allow` is set to false. Profile overrides
can explicitly change those defaults. No entitlement file is manufactured
for an app that requested no capabilities. For a legacy entitlement-file
input, explicitly override entitlements in the release profile if needed.

Precedence, lowest first: `defaults` -> target -> built-in profile -> global
`configurations.<name>` -> target `configurations.<name>`. Mappings merge
recursively, lists replace rather than append, and `~` clears an optional
value. `DEBUG` is appended after merging for debug builds.

Supported profile overrides: `bundle_id`, `opt`, `swift_opt`, `debug_symbols`,
`defines`, `info`, `entitlements`, `plist_vars`, `build_dir`, `cflags`,
`swiftflags`, `ldflags`, `strict`, `sign`. Targets, source lists and dependencies
are not profile-dependent. Unknown profile names/keys are errors.

Profile output paths are `<build_dir>/debug/` and `<build_dir>/release/`, for
both builders (xtool's IPA is copied to that profile path). Xcode receives
matching optimization, defines, debug-symbol, signing and metadata settings.
With no `-c`, legacy flags and output paths are preserved; the old target
`configuration:` key still chooses xtool's underlying configuration.

## defaults

`defaults:` accepts any target key except `name`, `dir` and `bundle_id`. A
target overrides defaults recursively for mappings (`info`, `entitlements`, etc.);
lists are replaced, not merged, and `~` clears an optional mapping/value.

## Complete example

```yaml
toolchain:
  jobs: 8

defaults:
  min_ios: "16.0"
  compile_commands: true

targets:
  - name: MyApp
    dir: app
    bundle_id: com.example.myapp
    version: "2.1"
    build_number: "37"
    sources: [Sources]
    resources: [Resources]
    bridging_header: Sources/MyApp-Bridging-Header.h
    defines: [ENABLE_LOGGING, 'API_HOST="api.example.com"']
    frameworks: [UIKit, Foundation, AVFoundation]
    libraries: [z]
    entitlements:
      get-task-allow: true
    plist_vars:
      APP_GROUP: group.com.example.myapp
    info:
      CFBundleDisplayName: My App
      UIFileSharingEnabled: true
      UIBackgroundModes: [audio]
    xcodeproj: true

  - name: Companion
    builder: xtool
    dir: companion
    bundle_id: com.example.companion
    sources: [Sources/Companion]
    info:
      CFBundleDisplayName: My App
    frameworks: [UIKit]
```
