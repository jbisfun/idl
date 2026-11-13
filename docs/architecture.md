# Architecture

`idl` is a single Zig executable (libplist is compiled in; only libc is linked dynamically). It reads `idlproj.yml` and
either generates files or runs external compilers. It contains no
general-purpose build system: dependencies are tracked per object file.

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
| `src/builder.zig` | parallel incremental compile, link, bundle assembly, signing, packaging, xtool runs, clean |
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

## Dependencies

All dependencies are pinned in `build.zig.zon`:

- **zig-clap**: argument parsing and help text.
- **zig-yaml**: YAML tokenizer and parser. `idl` walks its `Tree` directly
  rather than using `Yaml.parse`, because the typed parser coerces `16.10` to
  a float and drops quoting.
- **libplist** (libimobiledevice): reads and writes XML, binary, JSON and
  OpenStep plists. It is fetched as `git+https://…#2.8.1` (pinned to a commit)
  and compiled from C source by `buildLibplist` in `build.zig` instead of its
  autotools build. Only the C core is built, not libplist++.
- **zig-xml** (ianprime0509): XML reader for Interface Builder documents.
  Pinned to the last commit that supports Zig 0.14.
- **AssetKit** (xtool-org): `.xcassets` to `Assets.car`, used only by
  `tools/idl-actool` (Swift package, pinned to 1.0.0). It is not linked into
  `idl`.
- **Zig std**: deflate, CRC-32, SHA-1, JSON and processes. `idl` makes no
  network requests except to Jimpactor on 127.0.0.1.

## Design notes

- **Deterministic codegen.** Xcode object IDs are
  `SHA1("pbxprojgen:<section>:<key>")[0..12]`, so the same input always gives
  the same `project.pbxproj`. The output is byte-identical to the earlier
  Python generator, so projects regenerate without diffs after the
  migration.
- **Safe publishing.** A new `.xcodeproj` is written to a private sibling
  directory and moved into place with directory-FD-relative, no-follow
  operations (`fstatat(AT_SYMLINK_NOFOLLOW)`, `openat(O_NOFOLLOW)`,
  `renameat`). A symlink swapped in at the last moment can therefore not
  redirect the write. Unit tests cover this.
- **Never overwrite hand-written files.** Generated source-tree files carry a
  marker, and files without it are left alone.
- **Incremental builds.** Each object has a `.cmd` file with its exact
  command line, and clang's `-MMD` depfile lists its headers. A change to
  either recompiles the object.
- **Reproducible IPAs.** Entries are sorted, timestamps are fixed and Unix
  modes are preserved. Deflate is used only when it makes an entry smaller.
- **Scoped environment.** The swiftly bin directory is appended to `PATH`, not
  prepended, and only in the environment passed to child processes. Host
  tools keep priority.
