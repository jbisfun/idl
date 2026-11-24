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
| `appintents` | `appintentsmetadataprocessor` | App Intents metadata processor ([re-appintentsmetadataprocessor](https://codeberg.org/viraptor/re-appintentsmetadataprocessor), same CLI as Xcode's); a path or a name on PATH. Needed by `app_intents` targets |
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
| `app_intents` | on when `frameworks` has `AppIntents` or `WidgetKit`, or a linked static target has intents | extract App Intents metadata into `Metadata.appintents` (see below) |

If a target has any `.swift` file, swiftc compiles all Swift sources in one
whole-module compilation and links the clang-compiled objects. Debug builds
compile Swift to a persistent `.swift.o` and link separately, retaining DWARF
without requiring `dsymutil`. Otherwise clang links. C++ sources add `-lc++`.

### App Intents metadata

iOS reads a bundle's `Metadata.appintents` to find its App Intents: Shortcuts
actions, `AppIntentConfiguration` widget settings and interactive widget
buttons (`Button(intent:)`). Without it the intents compile but never run.
For an `app_intents` target (app, appex or framework) idl does what Xcode's
ExtractAppIntentsMetadata step does:

1. swiftc writes the module's const values (`-emit-const-values-path` with the
   App Intents protocol list as `-const-gather-protocols-file`).
2. After linking, `toolchain.appintents` reads the binary, sources and const
   values (`--compile-time-extraction`) and writes
   `<obj>/appintents/Metadata.appintents` (`extract.actionsdata`, `version.json`).
3. The bundle gets it at its root, e.g. `PlugIns/Widgets.appex/Metadata.appintents`.

A `static` target with `app_intents` only records its const values; every
bundle that links it extracts the static module together with its own (so an
intent shared by an app and its widget extension, such as an
`AudioPlaybackIntent` that must run in the app, lives in one static target
linked by both). Linking such a target turns extraction on for the bundle.

A module that declares no intents produces no metadata. With the default
(WidgetKit/AppIntents in `frameworks`) a missing processor is a warning; with
`app_intents: true` or `--strict` it is an error. `app_intents: false` turns
it off.

A WidgetKit extension is an `appex` with a Swift `@main WidgetBundle` and no
`ldflags` entry point:

```yaml
  - name: Widgets
    type: appex
    bundle_id: com.example.app.widgets
    min_ios: "17.0"
    sources: [Widgets]
    frameworks: [SwiftUI, WidgetKit, AppIntents]
    info:
      NSExtension:
        NSExtensionPointIdentifier: com.apple.widgetkit-extension
```

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
| `post_build` | `[]` | apps only: command (argv list) or list of commands run in order after the IPA is built and verified; skip with `idl build --no-post-build` |

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
  `[-e, _NSExtensionMain]` for principal-class extensions such as keyboards) or
  a Swift `@main` (WidgetKit `WidgetBundle`, ExtensionKit).
- `static`: compiled objects plus `<name>.swiftmodule` and `<name>-Swift.h`. A
  linking target receives the objects in its link, `-I` for the module, and the
  header dir. Not signed. No `bundle_id`.

Swift in non-app targets is compiled with `-parse-as-library` and module name
`<name>`. `post_build` runs in the target directory with `IDL_IPA`, `IDL_APP`,
`IDL_BUILD_DIR`, `IDL_TARGET`, `IDL` (path of the running idl) and, with `-c`,
`IDL_CONFIGURATION` set. A command that exits non-zero fails the build.

In `info:`, `Key: ~` removes a key inherited from `info_plist`. Info.plist and
entitlement expansion can also use `$(GIT_BRANCH)` and `$(GIT_COMMIT)` from the
project root's git checkout (environment variables override them). Source and
resource entries may use `*` in their last path component, e.g.
`Resources/*.lproj`.

### Formatting, linting and tests (`idl fmt`, `idl lint`, `idl test`)

idl only orchestrates the tools. It generates their configurations from YAML
into `.idl/quality/<target>/`, so no hand-written `.clang-format` or
`.swift-format` files are needed. It passes the configs explicitly, runs the
tools in parallel, and merges their output into one de-duplicated report:
`file:line:col: severity: message [flag] (tool)`, followed by a per-tool
summary and the most frequent flags/checks.

`format:` (maps merge with `defaults:`):

| Key | Default | Meaning |
| --- | --- | --- |
| `indent` | `4` | indent width (clang-format `IndentWidth`/`ObjCBlockIndentWidth`, swift-format `indentation.spaces`) |
| `line_length` | `0` | 0 = never re-wrap (clang-format `ColumnLimit: 0`) |
| `clang_format` | none | extra clang-format keys; they override the generated ones (nested maps allowed) |
| `swift_format` | none | extra swift-format JSON keys, deep-merged (e.g. `rules:`) |
| `exclude` | `[]` | source paths or directories never formatted (`*` per path component) |
| `editor_configs` | `false` | `idl gen` also writes `.clang-format`, `.clang-tidy` and `.swift-format` for clangd/sourcekit-lsp |

`idl fmt [--check] [target...]` formats C, Objective-C, C++, Objective-C++ and
headers with clang-format, and Swift with swift-format. `--check` changes
nothing and exits 1 if any file would change.

`lint:`:

| Key | Default | Meaning |
| --- | --- | --- |
| `warnings` | `[-Wall]` | clang warning flags added to the compiler pass |
| `swift_flags` | `[]` | extra swiftc flags for the Swift type-check |
| `exclude` | `[]` | paths not linted; diagnostics located there are dropped too |
| `clang_tidy` | auto | run clang-tidy (auto = when installed) |
| `clang_tidy_checks` | idl's set | clang-tidy `Checks`; default is clang-analyzer, bugprone and performance checks minus noisy ones |
| `analyze` | `false` | also run the clang static analyzer (`clang --analyze`) |
| `swift_format` | `false` | also run `swift-format lint` with the generated style |

`idl lint [target...]` first builds the targets and their dependencies
incrementally, so that Swift modules and generated `<Module>-Swift.h` headers
exist. It then re-runs each compiler with the target's exact build flags. Every
C-family file gets `clang -fsyntax-only`, with the target's `-w`, `-Werror`
and depfile flags removed and `lint.warnings` added. Each Swift module gets
`swiftc -typecheck` with warnings enabled. clang-tidy, the static analyzer and
`swift-format lint` reuse the same flags. Diagnostics from the SDK, from
excluded paths, and duplicates of the same header warning across translation
units are dropped. Options: `--werror`, `--analyze`, `--tidy`/`--no-tidy`,
`-q` (summary only) and `--max N`. Errors exit 1, and so do warnings with
`--werror`.

`tests:` (apps only) is a list of commands (argv lists). `idl test [target...]`
builds the targets without running `post_build` (unless `--no-build`). It then
checks each app's built bundle:
- Every Mach-O must be arm64, built for iOS, and signed. Embedded code must
  not require a newer iOS than the app's MinimumOSVersion; extensions are
  exempt.
- Every `@rpath`/`@loader_path`/`@executable_path` dependency must resolve
  inside the bundle, using the image's own rpaths. System libraries must exist
  in the SDK. Private frameworks and weak links only produce warnings.
- Every framework and extension needs an Info.plist and an executable, with
  string version keys.
- Every extension's bundle ID must be prefixed by the app's, and it must have
  `NSExtension`/`EXAppExtensionAttributes`.

After the checks, the `tests:` commands run in the target directory with
`IDL_IPA`, `IDL_APP`, `IDL_BUILD_DIR`, `IDL_TARGET` and `IDL` set. Output is
one PASS/FAIL line per check or command, then a summary.

Tool paths can be set under `toolchain:` as `clang_format`, `clang_tidy` and
`swift_format` (swift-format ships with the swiftly toolchain). A missing
optional tool is skipped with a note.

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
