# Architecture

`idl` is a single Zig executable (libplist is compiled in; only libc is linked dynamically). It reads `idlproj.yml` and
either generates files or runs external compilers. It contains no
general-purpose task language: it tracks compiler dependencies, prepares a
collision-checked resource plan, and caches resource and bundle outputs.

```
idlproj.yml ──► config ──► codegen ─► .xcodeproj, xtool.yml, Package.swift, compile_commands.json
                  │
                  └──► builder ─► clang / clang++ / swiftc ─► ld64.lld (xtool SDK)
                         │            (parallel, incremental)
                         ├─► plist (libplist): Info.plist, entitlements
                         ├─► resources: xcstrings, ibtool (storyboard/xib ─► nib),
                         │              idl-actool (xcassets ─► Assets.car)
                         ├─► ldid (from PATH or toolchain.ldid)
                         ├─► zip writer ─► .ipa
                         └─► verify: zip reader + plist + Mach-O parser
```

## Source map

| File | Responsibility |
| --- | --- |
| `src/main.zig` | CLI: zig-clap top-level command plus a parser per subcommand |
| `src/config.zig` | `idlproj.yml` schema, merging `defaults`, validation, upward file search |
| `src/ynode.zig` | lossless YAML view on zig-yaml's parse tree (keeps scalar text; strips comments) |
| `src/toolchain.zig` | SDK/compiler/ldid discovery, compiler and linker flag sets, `idl check` |
| `src/resources.zig` | resource cache, strict validation, output collision plan and storyboard/nib reference checks |
| `src/buildstate.zig` | SHA-256 tree fingerprints, cache records/output integrity and per-directory OS locks |
| `src/builder.zig` | parallel incremental compile, link, bundle assembly, signing, packaging, xtool runs, clean |
| `src/hosttest.zig` | `type: test` targets: SwiftPM package (copied sources) + `swift test`, or host clang build + run |
| `src/codegen.zig` | `xtool.yml`, `Package.swift`, `compile_commands.json`, protection against overwriting non-generated files |
| `src/pbxproj.zig` | deterministic Xcode project + scheme; atomic, symlink-safe publishing |
| `src/metadata.zig` | YAML-driven Info.plist and entitlements, shared by direct, Xcode and xtool builds |
| `src/plist.zig` | libplist wrapper, Xcode `$(VAR)` expansion, CLI value parsing |
| `src/xcstrings.zig` | String Catalog to `.strings` / `.stringsdict` |
| `src/zip.zig` | deterministic ZIP writer (std.compress.flate) and CRC-checking reader |
| `src/macho.zig` | Mach-O header and load-command inspection |
| `src/verify.zig` | IPA validation used by `build` and `verify` |
| `src/ibtool.zig` | `.xib` / `.storyboard` to nib object graphs (port of davidquesada/ibtool) |
| `src/nib.zig` | NIBArchive object model, encoder and decoder (`idl ibtool --dump`) |
| `src/xmldom.zig` | small DOM over zig-xml's streaming reader |
| `tools/idl-actool` | Swift wrapper around AssetKit; separate executable, built by `zig build actool` |
| `src/jimpactor.zig` | client for Jimpactor's local IPC protocol v1 (`devices`, `install`) |
| `src/scaffold.zig` | `idl init` (sources are embedded from `examples/` by `build.zig`) |
| `src/fsutil.zig` | discovery rules shared with Xcode, path validation, symlink checks |
| `src/diag.zig` | the single user-facing error message channel |
| `src/sys.zig` | process-wide `std.Io` and environment (set once in `main`), file/process helpers |

## Dependencies

All dependencies are pinned in `build.zig.zon`:

- **zig-clap**: argument parsing and help text.
- **zig-yaml**: YAML tokenizer and parser, pinned to a Zig 0.17 port of
  upstream `main` (0.3.0; upstream has no 0.17 release). `idl` walks its `Tree` directly
  rather than using `Yaml.parse`, because the typed parser coerces `16.10` to
  a float and drops quoting.
- **libplist** (libimobiledevice): reads and writes XML, binary, JSON and
  OpenStep plists. It is fetched as `git+https://…#2.8.1` (pinned to a commit)
  and compiled from C source by `buildLibplist` in `build.zig` instead of its
  autotools build. Only the C core is built, not libplist++.
- **zig-xml** (ianprime0509): XML reader for Interface Builder documents.
  Pinned to release 0.2.2 (Zig 0.16/0.17).
- **AssetKit** (xtool-org): `.xcassets` to `Assets.car`, used only by
  `tools/idl-actool` (Swift package, pinned to 1.0.0). It is not linked into
  `idl`.
- **Zig std**: deflate, CRC-32, SHA-1, JSON, processes and `translate-c`
  (`plist.h` is translated by `build.zig`; Zig 0.16+ has no `@cImport`). `idl` makes no
  network requests except to Jimpactor on 127.0.0.1.

## Design notes

- **Deterministic codegen.** Xcode object IDs are
  `SHA1("pbxprojgen:<section>:<key>")[0..12]`, so the same input always gives
  the same `project.pbxproj`. Low-level IDs retain compatibility with the earlier
  Python generator; profile-specific settings intentionally extend the output.
- **Safe publishing.** A new `.xcodeproj` is written to a private sibling
  directory and moved into place with directory-FD-relative, no-follow
  operations (`fstatat(AT_SYMLINK_NOFOLLOW)`, `openat(O_NOFOLLOW)`,
  `renameat`). A symlink swapped in at the last moment can therefore not
  redirect the write. Unit tests cover this.
- **Never overwrite hand-written files.** Generated source-tree files carry a
  marker, and files without it are left alone.
- **Preflight before compilation.** All selected tools are probed before any
  resource compiler runs; all resource plans are prepared before application
  compilation starts. Strict mode rejects unsupported/omitted inputs.
- **Incremental builds.** Each object has a `.cmd` command/tool fingerprint and
  clang's `-MMD` depfile lists headers. Resources use SHA-256 content-addressed
  cache entries and verify their output tree on hits. Bundling/signing/ZIP skip
  only if input fingerprints and both the payload and IPA integrity match.
- **Locking.** Build/check/gen/clean hold OS advisory locks in `.idl/build.lock`.
  Lock files are never unlinked during cleanup; closing the descriptor releases
  the lock. Builds acquire every selected lock before modifying outputs.
- **Profile generation.** YAML maps deep-merge into resolved debug/release
  targets. Metadata for each is written under `.idl/<profile>/`; Xcode receives
  both profiles, while xtool's manifests describe the selected profile.
- **Reproducible IPAs.** Entries are sorted, timestamps are fixed and Unix
  modes are preserved. Deflate is used only when it makes an entry smaller.
- **Scoped environment.** The swiftly bin directory is appended to `PATH`, not
  prepended, and only in the environment passed to child processes. Host
  tools keep priority.
