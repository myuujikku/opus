#!/usr/bin/env bash
# Build opus, opusfile, libopusenc and opus-tools for Windows x64 (UCRT64).
#
# Modes:
#   BUILD_MODE=stable   (default) verified official release tarballs from
#                       manifest.json (pinned version + SHA-256 + commit).
#   BUILD_MODE=nightly  full clones of the upstream default branches recorded
#                       in manifest.json; commits are resolved and logged.
#
# The script is intended for an MSYS2 UCRT64 shell, both locally and in GitHub
# Actions. It installs into a staging prefix, collects the required non-system
# runtime DLLs recursively, runs smoke tests, and creates a zip plus a resolved
# manifest. The checked-in manifest.json is never modified.
#
# Requirements:
#   MSYSTEM=UCRT64, MINGW_PREFIX=/ucrt64
#   Packages: mingw-w64-ucrt-x86_64-gcc, cmake, ninja, pkgconf, libogg, flac,
#             ntldd; msys autotools, autoconf-archive, git, jq, make, zip,
#             curl, tar.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly EXPORTED_COMPONENTS=(opus opusfile libopusenc opus-tools)

BUILD_MODE="${BUILD_MODE:-stable}"
case "$BUILD_MODE" in
  stable|nightly) ;;
  *) printf 'FATAL: BUILD_MODE must be "stable" or "nightly", got "%s"\n' "$BUILD_MODE" >&2; exit 1 ;;
esac

if [[ -z "${ARTIFACT_NAME:-}" ]]; then
  if [[ "$BUILD_MODE" == "nightly" ]]; then
    ARTIFACT_NAME="opus-windows-x64-ucrt64-nightly"
  else
    ARTIFACT_NAME="opus-windows-x64-ucrt64"
  fi
fi

JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
MANIFEST_FILE="${MANIFEST_FILE:-$ROOT_DIR/manifest.json}"

# Per-component values are filled in after manifest.json is loaded and the
# source mode has been resolved. Associative arrays keep the build functions
# free of hard-coded version strings.
declare -A SRC_DIR_FOR=()
declare -A VERSION_LABEL=()
declare -A SOURCE_KIND=()
declare -A SOURCE_URL=()
declare -A SOURCE_SHA=()
declare -A ARCHIVE_URL=()
declare -A ARCHIVE_SHA=()
declare -A SOURCE_REPO=()
declare -A SOURCE_TAG=()
declare -A SOURCE_BRANCH=()
declare -A COMMIT=()
declare -A COMMIT_DATE=()
declare -A PROVENANCE=()

# Stable manifest fields, populated by load_manifest().
ARCHIVE_BASE=""

# Stable-mode overrides (empty means "use manifest.json").
OPUS_VERSION="${OPUS_VERSION:-}"
OPUS_SHA256="${OPUS_SHA256:-}"
OPUSFILE_VERSION="${OPUSFILE_VERSION:-}"
OPUSFILE_SHA256="${OPUSFILE_SHA256:-}"
LIBOPUSENC_VERSION="${LIBOPUSENC_VERSION:-}"
LIBOPUSENC_SHA256="${LIBOPUSENC_SHA256:-}"
OPUS_TOOLS_VERSION="${OPUS_TOOLS_VERSION:-}"
OPUS_TOOLS_SHA256="${OPUS_TOOLS_SHA256:-}"

declare -A VERSION_ENV=(
  [opus]="OPUS_VERSION"
  [opusfile]="OPUSFILE_VERSION"
  [libopusenc]="LIBOPUSENC_VERSION"
  [opus-tools]="OPUS_TOOLS_VERSION"
)
declare -A SHA_ENV=(
  [opus]="OPUS_SHA256"
  [opusfile]="OPUSFILE_SHA256"
  [libopusenc]="LIBOPUSENC_SHA256"
  [opus-tools]="OPUS_TOOLS_SHA256"
)

abs_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$ROOT_DIR" "$1" ;;
  esac
}

BUILD_DIR="$(abs_path "${BUILD_DIR:-build}")"
DIST_DIR="$(abs_path "${DIST_DIR:-dist}")"
LOG_DIR="$(abs_path "${LOG_DIR:-build-logs}")"
STAGE_PREFIX="$(abs_path "${STAGE_PREFIX:-$BUILD_DIR/stage/ucrt64}")"
SRC_DIR="$BUILD_DIR/src"
DOWNLOAD_DIR="$BUILD_DIR/downloads"
PKG_ROOT="$DIST_DIR/$ARTIFACT_NAME"
ZIP_NAME="$ARTIFACT_NAME.zip"

readonly BUILD_DIR DIST_DIR LOG_DIR STAGE_PREFIX SRC_DIR DOWNLOAD_DIR PKG_ROOT ZIP_NAME

timestamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

log_info() {
  printf '[%s] %s\n' "$(timestamp)" "$*"
}

log_section() {
  printf '\n==> [%s] %s\n' "$(timestamp)" "$*"
}

die() {
  printf '\n[%s] FATAL: %s\n' "$(timestamp)" "$*" >&2
  if [[ -d "$LOG_DIR" ]]; then
    printf '\n[%s] FATAL: %s\n' "$(timestamp)" "$*" >>"$LOG_DIR/summary.log"
  fi
  exit 1
}

run_logged() {
  local log_file=$1
  shift
  log_info "RUN: $*"
  printf '\n===== [%s] RUN: %s =====\n' "$(timestamp)" "$*" >>"$log_file"
  "$@" 2>&1 | tee -a "$log_file"
}

run_logged_in() {
  local dir=$1
  local log_file=$2
  shift 2
  log_info "RUN (cwd=$dir): $*"
  printf '\n===== [%s] RUN (cwd=%s): %s =====\n' "$(timestamp)" "$dir" "$*" >>"$log_file"
  ( cd "$dir" && "$@" ) 2>&1 | tee -a "$log_file"
}

verify_sha256() {
  local file=$1
  local expected=${2,,}
  local actual
  [[ -f "$file" ]] || die "Expected download is missing: $file"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    die "SHA-256 mismatch for $(basename "$file")
  expected: $expected
  actual:   $actual

If you overrode a *_VERSION, pass the matching *_SHA256 as well."
  fi
  log_info "SHA-256 verified: $(basename "$file") ($actual)"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "Required tool not found: $1. Install the MSYS2 UCRT64 dependencies (see README.md)."
}

require_file() {
  [[ -f "$1" ]] || die "Missing expected file: $1"
}

require_glob() {
  local dir=$1
  local pattern=$2
  local -a matches=("$dir"/$pattern)
  [[ -e "${matches[0]}" ]] || die "Missing expected file matching: $dir/$pattern"
}

copy_diag() {
  local name=$1
  local source=$2
  [[ -f "$source" ]] || return 0
  cp -f "$source" "$LOG_DIR/diagnostics/$name" 2>/dev/null || true
}

collect_diagnostics() {
  mkdir -p "$LOG_DIR/diagnostics"
  copy_diag "opus-CMakeCache.txt" "$BUILD_DIR/opus/CMakeCache.txt"
  copy_diag "opus-CMakeOutput.log" "$BUILD_DIR/opus/CMakeFiles/CMakeOutput.log"
  copy_diag "opus-CMakeError.log" "$BUILD_DIR/opus/CMakeFiles/CMakeError.log"
  copy_diag "opus-CMakeConfigureLog.yaml" "$BUILD_DIR/opus/CMakeFiles/CMakeConfigureLog.yaml"
  copy_diag "opusfile-config.log" "$BUILD_DIR/opusfile/config.log"
  copy_diag "libopusenc-config.log" "$BUILD_DIR/libopusenc/config.log"
  copy_diag "opus-tools-config.log" "$BUILD_DIR/opus-tools/config.log"
}

summary_component_line() {
  local c=$1
  printf '  %-11s %-28s commit=%s source=%s\n' \
    "$c" "${VERSION_LABEL[$c]:-unknown}" "${COMMIT[$c]:-unknown}" "${PROVENANCE[$c]:-unknown}"
}

write_summary() {
  local result=$1
  local detail=${2:-}
  local summary_file="$LOG_DIR/summary.txt"
  local c

  {
    printf 'Opus Windows x64 (UCRT64) build\n'
    printf 'Generated: %s\n\n' "$(timestamp)"
    printf 'Result: %s%s\n' "$result" "$detail"
    printf 'Build mode: %s\n' "$BUILD_MODE"
    printf 'Artifact: %s\n' "$ARTIFACT_NAME"
    printf 'MSYSTEM: %s\n' "${MSYSTEM:-unset}"
    printf 'MINGW_PREFIX: %s\n' "${MINGW_PREFIX:-unset}"
    printf 'Jobs: %s\n\n' "$JOBS"
    printf 'Components:\n'
    for c in "${EXPORTED_COMPONENTS[@]}"; do
      summary_component_line "$c"
    done
    printf '\nArtifacts: %s\n' "$DIST_DIR"
    printf 'Logs:      %s\n' "$LOG_DIR"
    printf '\nLog files:\n'
    find "$LOG_DIR" -maxdepth 2 -type f -printf '  %P\n' 2>/dev/null | sort || true
  } >"$summary_file"

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      printf '## Windows x64 (UCRT64) Opus build — %s\n\n' "$result"
      printf 'Mode: **%s** · artifact: `%s`\n\n' "$BUILD_MODE" "$ARTIFACT_NAME"
      printf '| Component | Version | Commit | Source |\n|---|---|---|---|\n'
      for c in "${EXPORTED_COMPONENTS[@]}"; do
        printf '| %s | %s | `%s` | %s |\n' \
          "$c" "${VERSION_LABEL[$c]:-unknown}" "${COMMIT[$c]:-unknown}" "${PROVENANCE[$c]:-unknown}"
      done
      printf '\nResolved manifest: `%s-manifest.json`  \n' "$ARTIFACT_NAME"
      printf 'Logs: `%s-logs` (always uploaded; see `build-logs/summary.txt`).\n' "$ARTIFACT_NAME"
    } >>"$GITHUB_STEP_SUMMARY"
  fi
}

finalize() {
  local rc=$?
  set +e
  trap - ERR
  collect_diagnostics
  if [[ $rc -eq 0 ]]; then
    write_summary "SUCCESS"
    log_info "BUILD SUCCEEDED"
  else
    write_summary "FAILURE" " (exit $rc)"
    log_info "BUILD FAILED (exit $rc); see $LOG_DIR/summary.log and diagnostics/"
  fi
  log_info "Build logs: $LOG_DIR"
  [[ -f "$DIST_DIR/SHA256SUMS.txt" ]] && log_info "Checksums: $DIST_DIR/SHA256SUMS.txt"
  return "$rc"
}

trap finalize EXIT
trap 'rc=$?; printf "\n[%s] ERROR (exit=%d) at %s:%s\n  failed command: %s\n" "$(timestamp)" "$rc" "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ---------------------------------------------------------------------------
# Environment and manifest
# ---------------------------------------------------------------------------
check_environment() {
  log_section "Checking build environment"
  if [[ "${MSYSTEM:-}" != "UCRT64" ]]; then
    die "Run this script from an MSYS2 UCRT64 shell (MSYSTEM=UCRT64). Current MSYSTEM='${MSYSTEM:-unset}'."
  fi
  if [[ "${MINGW_PREFIX:-}" != "/ucrt64" ]]; then
    die "This build targets UCRT64 only; expected MINGW_PREFIX=/ucrt64, got '${MINGW_PREFIX:-unset}'."
  fi
  if [[ "$(uname -m)" != "x86_64" ]]; then
    die "This build targets x86_64 only; detected $(uname -m)."
  fi

  local -a tools=(gcc cmake ninja pkg-config make ntldd objdump zip curl sha256sum tar sed awk find jq)
  local t
  for t in "${tools[@]}"; do
    require_tool "$t"
  done

  if [[ "$BUILD_MODE" == "nightly" ]]; then
    require_tool git
    require_tool autoreconf
  fi
}

load_manifest() {
  MANIFEST_FILE="$(abs_path "$MANIFEST_FILE")"
  require_file "$MANIFEST_FILE"
  jq -e . "$MANIFEST_FILE" >/dev/null 2>&1 || die "manifest.json is not valid JSON: $MANIFEST_FILE"

  local schema
  schema="$(jq -r '.schema_version // 0' "$MANIFEST_FILE" | tr -d '\r')"
  [[ "$schema" == "1" ]] || die "Unsupported manifest schema_version '$schema' in $MANIFEST_FILE"

  mapfile -t COMPONENTS < <(jq -r '.components[]' "$MANIFEST_FILE" | tr -d '\r')
  local actual expected
  actual="$(printf '%s,' "${COMPONENTS[@]}")"
  actual="${actual%,}"
  expected="opus,opusfile,libopusenc,opus-tools"
  [[ "$actual" == "$expected" ]] || die \
    "manifest.json components must be: $expected (found: $actual)"

  ARCHIVE_BASE="$(jq -r '.archive_base // "https://downloads.xiph.org/releases/opus"' "$MANIFEST_FILE" | tr -d '\r')"
  [[ -n "$ARCHIVE_BASE" ]] || die "manifest.json is missing archive_base"

  local c
  for c in "${COMPONENTS[@]}"; do
    jq -e --arg c "$c" '
      .stable[$c] as $s |
      ($s.version != null) and ($s.repository != null) and ($s.tag != null) and
      ($s.commit != null) and ($s.archive_url != null) and ($s.archive_sha256 != null)
    ' "$MANIFEST_FILE" >/dev/null || die "manifest.json: incomplete stable entry for $c"
    jq -e --arg c "$c" '
      .nightly[$c] as $n | ($n.repository != null) and ($n.branch != null)
    ' "$MANIFEST_FILE" >/dev/null || die "manifest.json: incomplete nightly entry for $c"
  done
  log_info "Manifest: $MANIFEST_FILE (schema $schema)"
}

manifest_get() {
  local component=$1
  local section=$2
  local field=$3
  jq -r --arg c "$component" --arg s "$section" --arg f "$field" \
    '.[$s][$c][$f] // ""' "$MANIFEST_FILE" | tr -d '\r'
}

capture_environment() {
  log_section "Recording tool and package versions"
  {
    printf 'timestamp: %s\n' "$(timestamp)"
    printf 'build_mode: %s\nartifact: %s\n' "$BUILD_MODE" "$ARTIFACT_NAME"
    printf 'uname: %s\n' "$(uname -a)"
    printf 'MSYSTEM=%s\nMINGW_PREFIX=%s\nMINGW_CHOST=%s\n' "${MSYSTEM:-}" "${MINGW_PREFIX:-}" "${MINGW_CHOST:-}"
    printf 'ROOT_DIR=%s\nBUILD_DIR=%s\nSTAGE_PREFIX=%s\nLOG_DIR=%s\nDIST_DIR=%s\nJOBS=%s\n\n' \
      "$ROOT_DIR" "$BUILD_DIR" "$STAGE_PREFIX" "$LOG_DIR" "$DIST_DIR" "$JOBS"
    printf 'manifest: %s\n' "$MANIFEST_FILE"
    printf 'manifest sha256: %s\n\n' "$(sha256sum "$MANIFEST_FILE" | awk '{print $1}')"
    printf 'tool versions:\n'
    gcc --version 2>&1 | head -n 1 || true
    cmake --version 2>&1 | head -n 1 || true
    ninja --version 2>&1 | head -n 1 || true
    pkg-config --version 2>&1 | head -n 1 || true
    make --version 2>&1 | head -n 1 || true
    ntldd --version 2>&1 | head -n 1 || true
    objdump --version 2>&1 | head -n 1 || true
    jq --version 2>&1 | head -n 1 || true
    git --version 2>&1 | head -n 1 || true
    autoreconf --version 2>&1 | head -n 1 || true
    zip --version 2>&1 | head -n 2 || true
    printf '\ncommands:\n'
    command -v gcc cmake ninja pkg-config make ntldd objdump jq git autoreconf zip curl sha256sum tar 2>&1 || true
    printf '\nrelevant pacman packages:\n'
    local p
    for p in \
      mingw-w64-ucrt-x86_64-gcc \
      mingw-w64-ucrt-x86_64-cmake \
      mingw-w64-ucrt-x86_64-ninja \
      mingw-w64-ucrt-x86_64-pkgconf \
      mingw-w64-ucrt-x86_64-libogg \
      mingw-w64-ucrt-x86_64-flac \
      mingw-w64-ucrt-x86_64-ntldd \
      autotools \
      autoconf-archive \
      git \
      jq; do
      if pacman -Q "$p" >/dev/null 2>&1; then
        pacman -Q "$p"
      else
        printf '%s: NOT INSTALLED\n' "$p"
      fi
    done
  } >"$LOG_DIR/environment.log" 2>&1
  log_info "Environment details: $LOG_DIR/environment.log"
}

# ---------------------------------------------------------------------------
# Source acquisition
# ---------------------------------------------------------------------------
download_and_extract() {
  local name=$1
  local version=$2
  local sha256=$3
  local url=$4
  local tarball="$DOWNLOAD_DIR/$(basename "$url")"
  local src_dir="$SRC_DIR/$name-$version"

  if [[ ! -f "$tarball" ]]; then
    log_section "Downloading $name $version"
    run_logged "$LOG_DIR/0-download-$name.log" \
      curl --fail --location --retry 4 --retry-delay 3 --retry-all-errors \
        --silent --show-error --output "$tarball" "$url"
  else
    log_info "Using cached download: $tarball"
  fi

  verify_sha256 "$tarball" "$sha256"

  if [[ ! -d "$src_dir" ]]; then
    run_logged "$LOG_DIR/0-extract-$name.log" tar -xzf "$tarball" -C "$SRC_DIR"
  fi
  [[ -d "$src_dir" ]] || die "Source extraction failed; expected directory: $src_dir"
  SRC_DIR_FOR[$name]="$src_dir"
}

setup_stable_sources() {
  log_section "Resolving stable sources from manifest.json"
  local c manifest_version manifest_repo manifest_tag manifest_commit manifest_date manifest_url manifest_sha
  local requested_version requested_sha version sha commit date url provenance var_name tag

  for c in "${COMPONENTS[@]}"; do
    manifest_version="$(manifest_get "$c" stable version)"
    manifest_repo="$(manifest_get "$c" stable repository)"
    manifest_tag="$(manifest_get "$c" stable tag)"
    manifest_commit="$(manifest_get "$c" stable commit)"
    manifest_date="$(manifest_get "$c" stable commit_date)"
    manifest_url="$(manifest_get "$c" stable archive_url)"
    manifest_sha="$(manifest_get "$c" stable archive_sha256)"

    var_name="${VERSION_ENV[$c]}"
    requested_version="${!var_name}"
    requested_sha="${!SHA_ENV[$c]}"

    version="$manifest_version"
    url="$manifest_url"
    sha="$manifest_sha"
    commit="$manifest_commit"
    date="$manifest_date"
    tag="$manifest_tag"
    provenance="pinned-archive"

    if [[ -n "$requested_version" && "$requested_version" != "$manifest_version" ]]; then
      version="$requested_version"
      url="$ARCHIVE_BASE/$c-$version.tar.gz"
      sha=""
      commit=""
      date=""
      tag=""
      provenance="archive-override"
    fi

    if [[ -n "$requested_sha" ]]; then
      sha="$requested_sha"
      provenance="${provenance}+sha-override"
    fi

    [[ -n "$sha" ]] || die \
      "No checksum is available for $c $version. Set ${SHA_ENV[$c]} to the matching SHA-256."

    VERSION_LABEL[$c]="$version"
    SOURCE_KIND[$c]="archive"
    SOURCE_URL[$c]="$url"
    SOURCE_SHA[$c]="$sha"
    ARCHIVE_URL[$c]="$url"
    ARCHIVE_SHA[$c]="$sha"
    SOURCE_REPO[$c]="$manifest_repo"
    SOURCE_TAG[$c]="$tag"
    SOURCE_BRANCH[$c]=""
    COMMIT[$c]="$commit"
    COMMIT_DATE[$c]="$date"
    PROVENANCE[$c]="$provenance"

    download_and_extract "$c" "$version" "$sha" "$url"
    log_info "$c: $version ($provenance, commit ${commit:-unknown})"
  done
}

setup_nightly_sources() {
  log_section "Cloning upstream default branches (nightly, full history + tags)"
  : >"$LOG_DIR/nightly-commits.log"
  printf 'component\trepository\tbranch\tcommit\tcommit_date\tdescribe\n' >>"$LOG_DIR/nightly-commits.log"

  local c repo branch dir commit date describe
  for c in "${COMPONENTS[@]}"; do
    repo="$(manifest_get "$c" nightly repository)"
    branch="$(manifest_get "$c" nightly branch)"
    [[ -n "$repo" && -n "$branch" ]] || die "manifest.json: incomplete nightly entry for $c"

    dir="$SRC_DIR/$c-nightly"
    rm -rf "$dir"

    # Full history is intentional: upstream version generation uses
    # git describe/tags, and shallow clones produce unknown/0 versions.
    run_logged "$LOG_DIR/30-nightly-clone-$c.log" \
      git clone --single-branch --branch "$branch" "$repo" "$dir"
    run_logged "$LOG_DIR/31-nightly-tags-$c.log" \
      git -C "$dir" fetch --tags --force origin

    commit="$(git -C "$dir" rev-parse HEAD | tr -d '\r')"
    date="$(git -C "$dir" log -1 --format=%cI | tr -d '\r')"
    describe="$(git -C "$dir" describe --tags --always 2>/dev/null | tr -d '\r' || true)"
    [[ -n "$describe" ]] || describe="$commit"

    SRC_DIR_FOR[$c]="$dir"
    VERSION_LABEL[$c]="$describe"
    SOURCE_KIND[$c]="git"
    SOURCE_URL[$c]="$repo"
    SOURCE_SHA[$c]=""
    ARCHIVE_URL[$c]=""
    ARCHIVE_SHA[$c]=""
    SOURCE_REPO[$c]="$repo"
    SOURCE_TAG[$c]=""
    SOURCE_BRANCH[$c]="$branch"
    COMMIT[$c]="$commit"
    COMMIT_DATE[$c]="$date"
    PROVENANCE[$c]="git-nightly"

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "$repo" "$branch" "$commit" "$date" "$describe" \
      >>"$LOG_DIR/nightly-commits.log"
    printf '\n===== [%s] RESOLVED %s =====\nrepository: %s\nbranch: %s\ncommit: %s\ncommit_date: %s\ndescribe: %s\n' \
      "$(timestamp)" "$c" "$repo" "$branch" "$commit" "$date" "$describe" \
      >>"$LOG_DIR/30-nightly-clone-$c.log"

    log_info "$c: $repo @ $branch -> $commit ($describe)"
  done
}

bootstrap_autotools_project() {
  local c=$1
  [[ "${SOURCE_KIND[$c]}" == "git" ]] || return 0
  [[ "$c" == "opus" ]] && return 0
  local src="${SRC_DIR_FOR[$c]}"
  [[ -f "$src/configure.ac" ]] || die "Nightly $c checkout has no configure.ac; cannot bootstrap Autotools."
  log_section "Bootstrapping Autotools metadata for $c"
  run_logged_in "$src" "$LOG_DIR/32-$c-autoreconf.log" \
    env ACLOCAL_FLAGS="-I m4" autoreconf -fiv
}

# ---------------------------------------------------------------------------
# Build steps
# ---------------------------------------------------------------------------
build_opus() {
  log_section "Building opus ${VERSION_LABEL[opus]} (CMake + Ninja)"
  local src="${SRC_DIR_FOR[opus]}"
  local bld="$BUILD_DIR/opus"
  [[ -f "$src/CMakeLists.txt" ]] || die "Opus source has no CMakeLists.txt: $src"

  run_logged "$LOG_DIR/10-opus-configure.log" \
    cmake -S "$src" -B "$bld" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$STAGE_PREFIX" \
      -DBUILD_SHARED_LIBS=ON \
      -DOPUS_BUILD_SHARED_LIBRARY=ON \
      -DOPUS_BUILD_TESTING=OFF \
      -DOPUS_BUILD_PROGRAMS=OFF \
      -DOPUS_CUSTOM_MODES=ON \
      -DOPUS_STACK_PROTECTOR=OFF \
      -DOPUS_FORTIFY_SOURCE=OFF

  run_logged "$LOG_DIR/11-opus-build.log" \
    cmake --build "$bld" --parallel "$JOBS" --verbose
  run_logged "$LOG_DIR/12-opus-install.log" \
    cmake --install "$bld"
}

configure_autotools_project() {
  local project=$1
  shift

  local src="${SRC_DIR_FOR[$project]}"
  local bld="$BUILD_DIR/$project"
  [[ -x "$src/configure" ]] || die "No configure script in $src (run autoreconf for nightly sources)."
  mkdir -p "$bld"
  run_logged_in "$bld" "$LOG_DIR/20-$project-configure.log" \
    "$src/configure" \
      --prefix="$STAGE_PREFIX" \
      --build="$MINGW_CHOST" \
      --host="$MINGW_CHOST" \
      --disable-static \
      --disable-maintainer-mode \
      "$@"
  run_logged_in "$bld" "$LOG_DIR/21-$project-build.log" \
    make V=1 -j"$JOBS"
  run_logged_in "$bld" "$LOG_DIR/22-$project-install.log" \
    make V=1 install
}

build_opusfile() {
  log_section "Building opusfile ${VERSION_LABEL[opusfile]} (autotools, HTTP disabled)"
  # HTTP is intentionally disabled: it avoids OpenSSL and its Windows
  # certificate-store problems. libopusurl is still built as a stub, so
  # opus-tools links and local/file:// playback works. http(s) URLs do not.
  configure_autotools_project "opusfile" \
    --disable-http --disable-doc --disable-examples
}

build_libopusenc() {
  log_section "Building libopusenc ${VERSION_LABEL[libopusenc]} (autotools)"
  configure_autotools_project "libopusenc" \
    --disable-doc --disable-examples
}

build_opus_tools() {
  log_section "Building opus-tools ${VERSION_LABEL[opus-tools]} (autotools)"
  configure_autotools_project "opus-tools"
}

# ---------------------------------------------------------------------------
# Staging validation and packaging
# ---------------------------------------------------------------------------
validate_staging() {
  log_section "Validating staging prefix"
  require_file "$STAGE_PREFIX/include/opus/opus.h"
  require_file "$STAGE_PREFIX/include/opus/opusfile.h"
  require_file "$STAGE_PREFIX/include/opus/opusenc.h"
  require_glob "$STAGE_PREFIX/lib" "libopus.dll.a"
  require_glob "$STAGE_PREFIX/lib" "libopusfile.dll.a"
  require_glob "$STAGE_PREFIX/lib" "libopusurl.dll.a"
  require_glob "$STAGE_PREFIX/lib" "libopusenc.dll.a"
  require_glob "$STAGE_PREFIX/lib/pkgconfig" "opus.pc"
  require_glob "$STAGE_PREFIX/lib/pkgconfig" "opusfile.pc"
  require_glob "$STAGE_PREFIX/lib/pkgconfig" "libopusenc.pc"
  require_file "$STAGE_PREFIX/bin/opusenc.exe"
  require_file "$STAGE_PREFIX/bin/opusdec.exe"
  require_file "$STAGE_PREFIX/bin/opusinfo.exe"
}

package_files() {
  log_section "Assembling distributable tree"
  rm -rf "$PKG_ROOT"
  mkdir -p "$PKG_ROOT/bin" "$PKG_ROOT/include" "$PKG_ROOT/lib/pkgconfig" \
    "$PKG_ROOT/share/licenses/opus" \
    "$PKG_ROOT/share/licenses/opusfile" \
    "$PKG_ROOT/share/licenses/libopusenc" \
    "$PKG_ROOT/share/licenses/opus-tools" \
    "$PKG_ROOT/share/doc/opus-build"

  local -a dlls=("$STAGE_PREFIX"/bin/*.dll)
  [[ -e "${dlls[0]}" ]] || die "No DLLs found in $STAGE_PREFIX/bin"
  cp -f "${dlls[@]}" "$PKG_ROOT/bin/"

  local exe
  for exe in opusenc.exe opusdec.exe opusinfo.exe; do
    require_file "$STAGE_PREFIX/bin/$exe"
    cp -f "$STAGE_PREFIX/bin/$exe" "$PKG_ROOT/bin/"
  done

  cp -R "$STAGE_PREFIX/include/." "$PKG_ROOT/include/"

  local -a archives=("$STAGE_PREFIX"/lib/*.a)
  [[ -e "${archives[0]}" ]] || die "No import/static libraries found in $STAGE_PREFIX/lib"
  cp -f "${archives[@]}" "$PKG_ROOT/lib/"

  # Make the pkg-config files relocatable inside the extracted package.
  local pc
  for pc in "$STAGE_PREFIX"/lib/pkgconfig/*.pc; do
    [[ -f "$pc" ]] || continue
    sed -E 's|^prefix=.*|prefix=${pcfiledir}/../..|' "$pc" >"$PKG_ROOT/lib/pkgconfig/$(basename "$pc")"
  done

  cp -f "${SRC_DIR_FOR[opus]}/COPYING" "$PKG_ROOT/share/licenses/opus/COPYING"
  cp -f "${SRC_DIR_FOR[opusfile]}/COPYING" "$PKG_ROOT/share/licenses/opusfile/COPYING"
  cp -f "${SRC_DIR_FOR[libopusenc]}/COPYING" "$PKG_ROOT/share/licenses/libopusenc/COPYING"
  cp -f "${SRC_DIR_FOR[opus-tools]}/COPYING" "$PKG_ROOT/share/licenses/opus-tools/COPYING"
}

list_imports() {
  local file=$1
  local out=""
  if command -v ntldd >/dev/null 2>&1; then
    out="$(ntldd "$file" 2>>"$LOG_DIR/ntldd-errors.log" \
      | tr -d '\r' \
      | sed -nE 's/^[[:space:]]*([^[:space:]]+)[[:space:]]*=>.*/\1/p' || true)"
  fi
  if [[ -z "$out" ]]; then
    out="$(objdump -p "$file" | tr -d '\r' | sed -n 's/^[[:space:]]*DLL Name: /\1/p')"
  fi
  printf '%s\n' "$out"
}

resolve_runtime_dlls() {
  log_section "Collecting non-system runtime DLLs (recursive)"
  : >"$LOG_DIR/runtime-dlls.log"
  : >"$LOG_DIR/ntldd-errors.log"

  local -a queue=()
  local -A seen=()
  local file base key dll

  for file in "$PKG_ROOT"/bin/*.exe "$PKG_ROOT"/bin/*.dll; do
    [[ -e "$file" ]] || continue
    key="$(basename "$file")"
    key="${key,,}"
    seen["$key"]=1
    queue+=("$file")
  done

  while ((${#queue[@]} > 0)); do
    file="${queue[0]}"
    queue=("${queue[@]:1}")

    while IFS= read -r dll; do
      [[ -n "$dll" ]] || continue
      base="${dll##*/}"
      [[ "$base" == *.dll || "$base" == *.DLL ]] || continue
      key="${base,,}"
      [[ -z "${seen[$key]:-}" ]] || continue

      if [[ -f "$PKG_ROOT/bin/$base" ]]; then
        seen["$key"]=1
        queue+=("$PKG_ROOT/bin/$base")
        continue
      fi

      if [[ -f "$MINGW_PREFIX/bin/$base" ]]; then
        cp -f "$MINGW_PREFIX/bin/$base" "$PKG_ROOT/bin/"
        printf 'bundled: %-24s (needed by %s)\n' "$base" "$(basename "$file")" >>"$LOG_DIR/runtime-dlls.log"
        seen["$key"]=1
        queue+=("$PKG_ROOT/bin/$base")
        continue
      fi

      printf 'system:  %-24s (needed by %s)\n' "$base" "$(basename "$file")" >>"$LOG_DIR/runtime-dlls.log"
      seen["$key"]=1
    done < <(list_imports "$file")
  done

  log_info "Runtime DLL inventory: $LOG_DIR/runtime-dlls.log"
  grep '^bundled:' "$LOG_DIR/runtime-dlls.log" 2>/dev/null || true
}

smoke_test() {
  log_section "Smoke testing packaged executables with restricted PATH"
  # Remove /ucrt64/bin from PATH so a missing bundled DLL cannot be silently
  # resolved from the build environment.
  (
    cd "$PKG_ROOT/bin"
    export PATH="/c/Windows/System32:/usr/bin"
    run_logged "$LOG_DIR/50-smoke-opusenc.log" ./opusenc.exe --version
    run_logged "$LOG_DIR/51-smoke-opusdec.log" ./opusdec.exe --version
    run_logged "$LOG_DIR/52-smoke-opusinfo.log" ./opusinfo.exe -V
  )
}

write_package_docs() {
  log_section "Writing package documentation"
  local dll_list c
  dll_list="$(cd "$PKG_ROOT/bin" && for f in *.dll; do printf '  %s\n' "$f"; done)"

  {
    printf 'Opus / opusfile / libopusenc / opus-tools for Windows x64 (UCRT64)\n'
    printf '========================================================================\n\n'
    printf 'Built: %s\n' "$(timestamp)"
    printf 'Build mode: %s\n' "$BUILD_MODE"
    printf 'Toolchain: %s\n\n' "$(gcc --version | head -n 1)"

    printf 'Versions\n--------\n'
    for c in "${EXPORTED_COMPONENTS[@]}"; do
      printf '  %-11s %s\n' "$c" "${VERSION_LABEL[$c]}"
      printf '              commit %s (%s)\n' "${COMMIT[$c]:-unknown}" "${PROVENANCE[$c]}"
    done
    printf '\n'

    printf 'Contents\n--------\n'
    printf '  bin/      opusenc.exe, opusdec.exe, opusinfo.exe and bundled DLLs\n'
    printf '  include/  Opus, opusfile and libopusenc headers\n'
    printf '  lib/      MinGW import libraries (.dll.a) and relocatable\n'
    printf '            pkg-config files under lib/pkgconfig/\n'
    printf '  share/    Copyright licenses and build/source metadata\n\n'

    printf 'Usage\n-----\n'
    printf '  Add the bin directory to PATH, then run:\n'
    printf '    opusenc --help\n'
    printf '    opusdec --help\n'
    printf '    opusinfo --help\n\n'
    printf '  Embedded copy: keep the DLLs next to the executables.\n\n'

    printf 'Important limitation\n--------------------\n'
    printf '  opusfile/opusurl was built with HTTP support disabled to avoid\n'
    printf '  OpenSSL certificate-store issues on Windows. libopusurl exists as\n'
    printf '  a stub: local files and file:// URLs work, http:// and https://\n'
    printf '  URLs do not. This matches the deliberate scope of this build.\n\n'

    printf 'Bundled non-system DLLs\n-----------------------\n%s\n\n' "$dll_list"

    printf 'Build metadata\n--------------\n'
    printf '  See share/doc/opus-build/sources.txt, manifest.json and VERSION.txt.\n'
    printf '  Stable builds use verified release archives. Nightly builds use\n'
    printf '  upstream default branches and record the exact commit hashes.\n'
  } >"$PKG_ROOT/share/doc/opus-build/README.txt"

  {
    printf 'build_mode=%s\n' "$BUILD_MODE"
    printf 'artifact=%s\n' "$ARTIFACT_NAME"
    printf 'msystem=UCRT64\narch=x86_64\nhttp_support=disabled\n'
    printf 'build_timestamp=%s\n' "$(timestamp)"
    printf 'compiler=%s\n' "$(gcc --version | head -n 1)"
    for c in "${EXPORTED_COMPONENTS[@]}"; do
      printf '%s_version=%s\n' "$c" "${VERSION_LABEL[$c]}"
      printf '%s_commit=%s\n' "$c" "${COMMIT[$c]:-unknown}"
      printf '%s_source=%s\n' "$c" "${PROVENANCE[$c]}"
    done
  } >"$PKG_ROOT/share/doc/opus-build/VERSION.txt"

  {
    printf 'Build mode: %s\nGenerated: %s\n\n' "$BUILD_MODE" "$(timestamp)"
    printf 'Upstream sources and resolved commits\n'
    printf '=====================================\n\n'
    for c in "${EXPORTED_COMPONENTS[@]}"; do
      printf '%s %s\n' "$c" "${VERSION_LABEL[$c]}"
      printf '  repository:  %s\n' "${SOURCE_REPO[$c]}"
      if [[ "$BUILD_MODE" == "stable" ]]; then
        printf '  tag:         %s\n' "${SOURCE_TAG[$c]:-unknown}"
        printf '  commit:      %s\n' "${COMMIT[$c]:-unknown}"
        printf '  commit_date: %s\n' "${COMMIT_DATE[$c]:-unknown}"
        printf '  archive:     %s\n' "${ARCHIVE_URL[$c]}"
        printf '  sha256:      %s\n\n' "${ARCHIVE_SHA[$c]}"
      else
        printf '  branch:      %s\n' "${SOURCE_BRANCH[$c]}"
        printf '  commit:      %s\n' "${COMMIT[$c]}"
        printf '  commit_date: %s\n' "${COMMIT_DATE[$c]}"
        printf '  source:      git clone (full history + tags)\n\n'
      fi
    done
    printf 'Runtime dependencies (unchanged sources) are provided by MSYS2 UCRT64:\n'
    printf '  libogg, flac, and the MinGW-w64 runtime DLLs.\n'
  } >"$PKG_ROOT/share/doc/opus-build/sources.txt"
}

write_resolved_manifest() {
  log_section "Writing resolved manifest"
  local components='[]'
  local c component_json
  local pkg_manifest="$PKG_ROOT/share/doc/opus-build/manifest.json"
  local dist_manifest="$DIST_DIR/$ARTIFACT_NAME-manifest.json"

  for c in "${EXPORTED_COMPONENTS[@]}"; do
    component_json="$(jq -n \
      --arg name "$c" \
      --arg version "${VERSION_LABEL[$c]:-}" \
      --arg repository "${SOURCE_REPO[$c]:-}" \
      --arg tag "${SOURCE_TAG[$c]:-}" \
      --arg branch "${SOURCE_BRANCH[$c]:-}" \
      --arg commit "${COMMIT[$c]:-}" \
      --arg commit_date "${COMMIT_DATE[$c]:-}" \
      --arg source_type "${SOURCE_KIND[$c]:-}" \
      --arg provenance "${PROVENANCE[$c]:-}" \
      --arg archive_url "${ARCHIVE_URL[$c]:-}" \
      --arg archive_sha256 "${ARCHIVE_SHA[$c]:-}" \
      'def s($v): if $v == "" then null else $v end;
       {
         version: $version,
         repository: $repository,
         tag: s($tag),
         branch: s($branch),
         commit: s($commit),
         commit_date: s($commit_date),
         source_type: $source_type,
         provenance: $provenance,
         archive_url: s($archive_url),
         archive_sha256: s($archive_sha256)
       } | {($name): .}')"
    components="$(jq -n --argjson acc "$components" --argjson item "$component_json" \
      '$acc + [$item]')"
  done

  jq -n \
    --arg mode "$BUILD_MODE" \
    --arg generated "$(timestamp)" \
    --arg artifact "$ARTIFACT_NAME" \
    --argjson components "$components" \
    '{
       schema_version: 1,
       build_mode: $mode,
       generated_at: $generated,
       target: {
         platform: "windows",
         arch: "x86_64",
         msystem: "UCRT64",
         artifact: $artifact
       },
       components: ($components | add)
     }' >"$pkg_manifest"

  cp -f "$pkg_manifest" "$dist_manifest"
  jq -e . "$dist_manifest" >/dev/null || die "Resolved manifest is not valid JSON: $dist_manifest"
  log_info "Resolved manifest: $dist_manifest"
}

create_zip() {
  log_section "Creating zip archive"
  require_file "$DIST_DIR/$ARTIFACT_NAME-manifest.json"
  run_logged "$LOG_DIR/60-zip.log" bash -c 'cd "$1" && rm -f "$2" && zip -q -9 -r "$2" "$3"' \
    _ "$DIST_DIR" "$ZIP_NAME" "$ARTIFACT_NAME"
  (
    cd "$DIST_DIR"
    sha256sum "$ZIP_NAME" "$ARTIFACT_NAME-manifest.json" >SHA256SUMS.txt
  )
  log_info "Archive: $DIST_DIR/$ZIP_NAME"
  log_info "Checksums:"
  sed 's/^/  /' "$DIST_DIR/SHA256SUMS.txt"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  cd "$ROOT_DIR"
  # Remove every generated output directory so stale logs cannot be mistaken
  # for diagnostics from the current run.
  rm -rf "$BUILD_DIR" "$DIST_DIR" "$LOG_DIR"
  mkdir -p "$BUILD_DIR" "$SRC_DIR" "$DOWNLOAD_DIR" "$STAGE_PREFIX" "$DIST_DIR" "$LOG_DIR"
  : >"$LOG_DIR/summary.log"

  log_section "Build mode: $BUILD_MODE (artifact $ARTIFACT_NAME)"
  check_environment
  load_manifest
  capture_environment
  export GIT_TERMINAL_PROMPT=0

  if [[ "$BUILD_MODE" == "nightly" ]]; then
    local var
    for var in OPUS_VERSION OPUS_SHA256 OPUSFILE_VERSION OPUSFILE_SHA256 \
               LIBOPUSENC_VERSION LIBOPUSENC_SHA256 OPUS_TOOLS_VERSION OPUS_TOOLS_SHA256; do
      if [[ -n "${!var:-}" ]]; then
        die "Version/checksum overrides are only valid in stable mode; $var is set while BUILD_MODE=nightly."
      fi
    done
    setup_nightly_sources
    local c
    for c in opusfile libopusenc opus-tools; do
      bootstrap_autotools_project "$c"
    done
  else
    setup_stable_sources
  fi

  # Make staged headers/libraries discoverable by the following builds.
  export PKG_CONFIG_PATH="$STAGE_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
  export PATH="$STAGE_PREFIX/bin:$PATH"

  # Required build order: opus -> opusfile -> libopusenc -> opus-tools.
  build_opus
  build_opusfile
  build_libopusenc
  build_opus_tools

  validate_staging
  package_files
  resolve_runtime_dlls
  write_package_docs
  write_resolved_manifest
  smoke_test
  create_zip

  log_section "Done"
  log_info "Distributable: $DIST_DIR/$ZIP_NAME"
  log_info "Resolved manifest: $DIST_DIR/$ARTIFACT_NAME-manifest.json"
  log_info "Logs: $LOG_DIR"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
