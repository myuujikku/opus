# Opus for Windows x64 (MSYS2 UCRT64)

Builds **opus**, **opusfile**, **libopusenc** and **opus-tools** as Windows
x64 binaries with MSYS2 UCRT64 in GitHub Actions, in two source modes:

- **stable** (default): official Xiph release tarballs verified against SHA-256
  hashes pinned in `manifest.json`.
- **nightly**: full clones of the canonical upstream default branches at build
  time, with exact resolved commit hashes recorded.

The result is a self-contained zip containing:

- `opusenc.exe`, `opusdec.exe`, `opusinfo.exe`
- Opus, opusfile/opusurl and libopusenc DLLs, headers and import libraries
- Every required non-system MinGW runtime DLL, collected recursively
- License files and source/build provenance, including a resolved manifest

The workflow runs on **workflow_dispatch**, **pushes to `main`**, and **pull
requests**. It never publishes a GitHub Release; download the zip from the
workflow run's **Artifacts** section. A scheduled nightly run is optional and
is not enabled here.

Build order is fixed: `opus -> opusfile -> libopusenc -> opus-tools`.

## Manifest (`manifest.json`)

`manifest.json` is the source of truth for stable versions, canonical
repositories, tags, source commit hashes, archive URLs/checksums, and the
nightly repository/branch for each component. The script reads it with `jq`
and never modifies it. At build time it emits a **resolved manifest** into the
package and the binary artifact.

Stable pins (commits are source commits, not annotated tag objects):

| Component | Version | Tag | Commit | Repository | Nightly branch |
|---|---|---|---|---|---|
| opus | 1.6.1 | `v1.6.1` | `22244de5a79bd1d6d623c32e72bf1954b56235be` | `https://gitlab.xiph.org/xiph/opus.git` | `main` |
| opusfile | 0.12 | `v0.12` | `a55c164e9891a9326188b7d4d216ec9a88373739` | `https://gitlab.xiph.org/xiph/opusfile.git` | `main` |
| libopusenc | 0.3 | `v0.3` | `0dba1bea736ab8bb811409dce80c994a00a2ced9` | `https://gitlab.xiph.org/xiph/libopusenc.git` | `master` |
| opus-tools | 0.2 | `v0.2` | `0c1337f57e5b87fd23421904303fed3e575ce354` | `https://gitlab.xiph.org/xiph/opus-tools.git` | `master` |

Official archives are downloaded from
`https://downloads.xiph.org/releases/opus/`:

| Component | Archive SHA-256 |
|---|---|
| opus | `6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1` |
| opusfile | `118d8601c12dd6a44f52423e68ca9083cc9f2bfe72da7a8c1acb22a80ae3550b` |
| libopusenc | `f616d3aff9b2034547894ccb8ab56c36cf1a4acb0d922c5d7119f97bbe58642c` |
| opus-tools | `b4e56cb00d3e509acfba9a9b627ffd8273b876b4e2408642259f6da28fa0ff86` |

To update a pin, edit the stable entry in `manifest.json` (version, tag,
source commit, commit date, archive URL, SHA-256). Do not leave an override in
the workflow without a matching checksum.

## Stable and nightly usage

Trigger a build from the Actions UI, or use GitHub CLI:

```bash
# Stable, pinned release archives (default)
gh workflow run build-windows.yml -f source=stable

# Nightly, latest upstream branch HEADs
gh workflow run build-windows.yml -f source=nightly
```

Stable version/checksum overrides are available as dispatch inputs or local
environment variables. They are **rejected in nightly mode**, never silently
mixed with HEAD sources:

| Component | Version override | Checksum override |
|---|---|---|
| opus | `OPUS_VERSION` | `OPUS_SHA256` |
| opusfile | `OPUSFILE_VERSION` | `OPUSFILE_SHA256` |
| libopusenc | `LIBOPUSENC_VERSION` | `LIBOPUSENC_SHA256` |
| opus-tools | `OPUS_TOOLS_VERSION` | `OPUS_TOOLS_SHA256` |

Checksums are never silently skipped. If a stable version differs from the
manifest pin, the matching checksum must be supplied or the script stops before
downloading.

### Nightly mechanics

- Clones each canonical GitLab repository with
  `git clone --single-branch --branch <branch>` using **full history**, then
  `git fetch --tags`.
- Full history and tags are required because upstream version generation uses
  `git describe`/tags. Shallow clones can produce `unknown`/`0` versions.
- Runs `autoreconf -fiv` for `opusfile`, `libopusenc` and `opus-tools`, because
  git checkouts lack generated `configure` and `package_version` files. Opus is
  built with CMake.
- Records the exact HEAD commit, commit date and `git describe` value in
  `build-logs/nightly-commits.log`, each clone log, and the resolved manifest.
- Fails on clone/bootstrap/build errors; there is no fallback to stable.
- Nightly artifacts are moving targets. Reproductibility requires checking out
  the recorded commit hashes.

A scheduled nightly run is optional and not enabled. Add a `schedule:` trigger
that invokes the same build with `BUILD_MODE=nightly` if desired.

## Artifacts

| Mode | Binary artifact | Log artifact |
|---|---|---|
| stable | `opus-windows-x64-ucrt64` | `opus-windows-x64-ucrt64-logs` |
| nightly | `opus-windows-x64-ucrt64-nightly` | `opus-windows-x64-ucrt64-nightly-logs` |

Each binary artifact contains:

- `opus-windows-x64-ucrt64[-nightly].zip`
- `opus-windows-x64-ucrt64[-nightly]-manifest.json` (resolved provenance)
- `SHA256SUMS.txt` (checksums for both files)

Zip layout:

```text
opus-windows-x64-ucrt64[-nightly]/
├── bin/
│   ├── opusenc.exe, opusdec.exe, opusinfo.exe
│   └── <MinGW runtime and dependency DLLs, collected recursively>
├── include/opus/
│   ├── opus.h, opus_types.h, opus_multistream.h, ...
│   ├── opusfile.h
│   └── opusenc.h
├── lib/
│   ├── libopus.dll.a, libopusfile.dll.a, libopusurl.dll.a,
│   │   libopusenc.dll.a
│   └── pkgconfig/*.pc        (relocatable; prefix=${pcfiledir}/../..)
└── share/
    ├── licenses/{opus,opusfile,libopusenc,opus-tools}/COPYING
    └── doc/opus-build/
        ├── README.txt
        ├── VERSION.txt
        ├── sources.txt
        └── manifest.json     (resolved build-time provenance)
```

The resolved manifest records `build_mode`, `generated_at`, the target, and per
component: resolved version/describe, repository, tag, branch, exact commit,
commit date, source type/provenance, and archive URL/SHA-256 (null for
nightly). It is never written back to the checked-in `manifest.json`.

Download with GitHub CLI:

```bash
gh run download <run-id> -n opus-windows-x64-ucrt64
gh run download <run-id> -n opus-windows-x64-ucrt64-nightly
```

To use the binaries, add the extracted `bin` directory to `PATH`, or keep the
extracted directory intact and invoke the executables by path. Keep the DLLs
next to the `.exe` files.

## Local MSYS2 build

Use an **MSYS2 UCRT64** terminal (not MINGW64, not CLANG64). From the
repository root:

```bash
pacman -S --needed \
  mingw-w64-ucrt-x86_64-gcc \
  mingw-w64-ucrt-x86_64-cmake \
  mingw-w64-ucrt-x86_64-ninja \
  mingw-w64-ucrt-x86_64-pkgconf \
  mingw-w64-ucrt-x86_64-libogg \
  mingw-w64-ucrt-x86_64-flac \
  mingw-w64-ucrt-x86_64-ntldd \
  autotools autoconf-archive git jq make zip curl tar

# Stable (default)
bash scripts/build-windows.sh

# Nightly
BUILD_MODE=nightly bash scripts/build-windows.sh
```

The script refuses to run outside `MSYSTEM=UCRT64` / `MINGW_PREFIX=/ucrt64` and
fails fast if a required tool is missing. Stable mode needs `jq`; nightly
additionally needs `git` and `autoreconf`.

Outputs:

```text
dist/opus-windows-x64-ucrt64[-nightly].zip
dist/opus-windows-x64-ucrt64[-nightly]-manifest.json
dist/SHA256SUMS.txt
build-logs/
```

Build directories (`build/`, `build-logs/`, `dist/`) are disposable and ignored
by Git.

## Logs and debugging

Logging is deliberately verbose and preserved for post-mortem analysis:

- Every configure/build/install command is timestamped and captured to its own
  file under `build-logs/`, while still streaming to the console.
- `pipefail` is enabled, so a failing compiler/make/CMake pipeline fails the
  step immediately and keeps captured output.
- The environment log records MSYS2 system/prefix, compiler, CMake, Ninja,
  pkg-config, make, ntldd, objdump, jq, git, autoreconf, zip versions, command
  paths, the manifest SHA-256, job count, and installed MSYS2 package versions.
- Stable download/extract, nightly clone/tag fetch, `autoreconf`, recursive DLL
  resolution, and each smoke test have dedicated logs.
- On exit (success or failure), `config.log` from opusfile, libopusenc and
  opus-tools plus CMake caches/configure logs are copied to
  `build-logs/diagnostics/`.
- `build-logs/summary.txt` records mode, versions, commits, result, and all log
  files. The same summary is written to the GitHub Actions step summary.

Key files:

| File | Purpose |
|---|---|
| `build-logs/environment.log` | Toolchain, package versions, manifest hash |
| `build-logs/0-download-*.log`, `0-extract-*.log` | Stable source retrieval |
| `build-logs/30-nightly-clone-*.log`, `31-nightly-tags-*.log` | Nightly clone, tag fetch, resolved HEAD |
| `build-logs/32-*-autoreconf.log` | Nightly Autotools bootstrap |
| `build-logs/nightly-commits.log` | Exact nightly commits (component/repo/branch/commit/date/describe) |
| `build-logs/10-opus-configure.log`, `11-opus-build.log`, `12-opus-install.log` | Opus CMake |
| `build-logs/20-<project>-configure.log`, `21-...-build.log`, `22-...-install.log` | opusfile, libopusenc, opus-tools |
| `build-logs/diagnostics/` | Copies of `config.log`, `CMakeCache.txt`, CMake configure logs |
| `build-logs/runtime-dlls.log` | Bundled vs system DLL decisions |
| `build-logs/ntldd-errors.log` | Dependency-resolution warnings |
| `build-logs/50-52-smoke-*.log` | Runtime tests with restricted `PATH` |
| `build-logs/summary.txt` | Human-readable build summary |

In CI, the `<binary artifact>-logs` artifact is uploaded with `if: always()`,
so it is available when the build fails. It includes `build-logs/` plus
additional `build/**/config.log`, `CMakeCache.txt`, and CMake configure logs.
Paths are kept in sync between the script and the workflow.

No repository secrets are used, and the script does not dump the process
environment; logs therefore contain no credentials.

## Scope and limitations

- **UCRT64 / Windows x64 only.** There is no MINGW64 or multi-architecture
  matrix. Windows 10 or later is expected (UCRT).
- **HTTP support is disabled in opusfile/opusurl.** This avoids OpenSSL and its
  Windows certificate-store problems. `libopusurl` is still built as a stub, so
  opus-tools links and handles local files and `file://` URLs, but `http://`
  and `https://` URLs are not supported by `opusdec`.
- **Shared libraries only.** The package ships DLLs, MinGW import libraries
  (`*.a`/`*.dll.a`), and pkg-config files; it does not ship a standalone static
  Opus build.
- **Nightly is not bit-for-bit reproducible.** Exact commits are recorded, but
  upstream branches move. Stable artifacts are reproducible from pinned
  archives plus the recorded MSYS2 dependency versions.
- **Rolling MSYS2 dependencies.** libogg, FLAC and the MinGW runtime come from
  the MSYS2 rolling repositories; their versions are recorded in
  `build-logs/environment.log` and package metadata.
- **Unsigned binaries.** No code signing is performed.
- **No release publishing.** Artifacts are not attached to GitHub Releases.

## Implementation references

The MSYS2 `MINGW-packages` recipes were used as the reference for dependencies
and build flags:

- <https://github.com/msys2/MINGW-packages/tree/master/mingw-w64-opus>
- <https://github.com/msys2/MINGW-packages/tree/master/mingw-w64-opusfile>
- <https://github.com/msys2/MINGW-packages/tree/master/mingw-w64-libopusenc>
- <https://github.com/msys2/MINGW-packages/tree/master/mingw-w64-opus-tools>

Differences from those recipes are intentional: this builds all four components
from source in one staging prefix, uses CMake for Opus with
`OPUS_STACK_PROTECTOR=OFF` and `OPUS_FORTIFY_SOURCE=OFF` to avoid a `libssp`
runtime dependency, disables opusfile HTTP, performs full-history nightly
clones for correct version generation, and packages the DLL closure for
redistribution.

## License

The build scripts and manifest in this repository are provided as-is. The
bundled upstream components retain their own licenses, copied into
`share/licenses/<component>/COPYING` in the artifact.
