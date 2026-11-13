# idlproj.yml reference

`idlproj.yml` is the only configuration file. It has three top-level keys:

```yaml
toolchain: { ... }   # optional: where the compilers and SDK live
defaults:  { ... }   # optional: target keys applied to every target
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
| `swift_version` | `5.0` | written to the Xcode project |
| `defines` | `[]` | `NAME` or `NAME=VALUE`. Both forms go to C-family code; only `NAME` goes to Swift |
| `include_dirs` | `[]` | `-I` for clang and swiftc |
| `bridging_header` | none | Objective-C header that Swift imports (`-import-objc-header`) |
| `cflags` / `swiftflags` | `[]` | extra compiler flags |
| `ldflags` | `[]` | extra linker arguments, each passed as `-Xlinker <arg>` |
| `frameworks` | `[UIKit, Foundation]` | SDK frameworks (`X` or `X.framework`) |
| `weak_frameworks` | `[]` | weakly linked frameworks |
| `libraries` | `[]` | `-l` libraries, e.g. `[z, sqlite3]` |
| `build_dir` | `build` | where objects, the app bundle and the IPA go |

If a target has any `.swift` file, swiftc compiles all Swift sources in one
whole-module invocation and links the clang-compiled objects. Otherwise clang
links. C++ sources add `-lc++`.

### Bundle

| Key | Default | Meaning |
| --- | --- | --- |
| `info_plist` | `Info.plist` | source Info.plist (XML, binary, JSON or OpenStep) |
| `info` | none | keys merged into Info.plist (see below) |
| `plist_vars` | none | extra `$(VAR)` values for Info.plist and entitlements |
| `entitlements` | none | entitlements plist passed to `ldid -S` |
| `resources` | `[]` | files or directories copied into the bundle (see [limitations](limitations.md)) |
| `sign` | `true` for `direct`, `false` for `xtool` | ad-hoc sign with ldid / pass `--sign` to xtool |
| `app_icon` | `AppIcon` | asset-catalog icon name in the Xcode project |
| `device_family` | `1,2` | `TARGETED_DEVICE_FAMILY` in the Xcode project |

Info.plist processing, in order:

1. Add any missing standard keys: `CFBundleExecutable`, `CFBundleIdentifier`,
   `CFBundleName`, `CFBundlePackageType`, `CFBundleInfoDictionaryVersion`,
   `CFBundleShortVersionString`, `CFBundleVersion`.
2. Merge the `info:` mapping. Unquoted `true`/`false` become booleans,
   unquoted integers become `<integer>`, lists become arrays, mappings become
   dictionaries, and quoted values stay strings. Version keys such as
   `CFBundleVersion` always stay strings.
3. Set `MinimumOSVersion` to `min_ios`.
4. Expand `$(VAR)`, `${VAR}` and `$(VAR:modifier)` in every string. Values
   come from `plist_vars`, then the built-in variables, then the environment.
   Unknown variables become empty strings. The modifier is ignored.

Built-in variables: `EXECUTABLE_NAME`, `PRODUCT_NAME`, `TARGET_NAME`,
`PRODUCT_MODULE_NAME`, `PRODUCT_BUNDLE_IDENTIFIER`,
`PRODUCT_BUNDLE_PACKAGE_TYPE`, `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`,
`IPHONEOS_DEPLOYMENT_TARGET`, `DEVELOPMENT_LANGUAGE`.

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

## defaults

`defaults:` accepts any target key except `name`, `dir` and `bundle_id`. A
target's own value replaces the default; lists are replaced, not merged.

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
    entitlements: Entitlements.plist
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
    info_plist: Support/Info.plist
    frameworks: [UIKit]
```
