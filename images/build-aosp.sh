#!/usr/bin/env bash
# Phase 0: build one AOSP emulator system image (Android 14 / API 34, x86_64, no GMS) on a Linux host.
#
#   ./build-aosp.sh --check               only check the machine against the requirements (README.md)
#   ./build-aosp.sh                       sync + build in Docker (Ubuntu 22.04), result in images/out/
#   ./build-aosp.sh --no-docker           same, directly on an Ubuntu 22.04 host with the packages from docker/Dockerfile
#
# Options (defaults in brackets):
#   --src DIR       source tree, on ext4/xfs, not NTFS or /mnt/c  [/srv/aosp/<tag>]
#   --tag TAG       AOSP manifest tag                              [android-14.0.0_r75]
#   --release CFG   release config for lunch ("" for tags without build/release)  [ap2a]
#   --target T      lunch product                                  [sdk_phone64_x86_64]
#   --variant V     user | userdebug | eng                         [userdebug]
#   --jobs N        build parallelism                              [min(cores, RAM_GB/2)]
#   --sync-jobs N   repo sync parallelism                          [8]
#   --force         run even if the requirement check fails
#
# Output: images/out/mulka-aosp-<api>-x86_64-<tag>.zip (+ .sha256, build log, build.prop) and
# images/manifests/<tag>.pinned.xml (commit this one: it records the exact commits of the build).
set -Eeo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG=android-14.0.0_r75
RELEASE=ap2a
TARGET=sdk_phone64_x86_64
PRODUCT_DEVICE=emu64x
VARIANT=userdebug
API=34
SRC=
JOBS=
SYNC_JOBS=8
MODE=docker
CHECK_ONLY=0
FORCE=0
INSIDE=0

# Requirements for ONE image (README.md). The phase 1 CI server (7 images, ccache) is sized separately.
MIN_CORES=8;   REC_CORES=16
MIN_MEM_GB=32; REC_MEM_GB=64     # RAM + swap counted together for the minimum
MIN_DISK_GB=300; REC_DISK_GB=400

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src) SRC="$2"; shift 2 ;;
        --tag) TAG="$2"; shift 2 ;;
        --release) RELEASE="$2"; shift 2 ;;
        --target) TARGET="$2"; shift 2 ;;
        --variant) VARIANT="$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --sync-jobs) SYNC_JOBS="$2"; shift 2 ;;
        --no-docker) MODE=host; shift ;;
        --check) CHECK_ONLY=1; shift ;;
        --force) FORCE=1; shift ;;
        --inside) INSIDE=1; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
SRC="${SRC:-/srv/aosp/$TAG}"
LUNCH="$TARGET${RELEASE:+-$RELEASE}-$VARIANT"

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILS=$((FAILS + 1)); }

check_machine() {
    FAILS=0
    say "Machine check for $LUNCH ($TAG), source in $SRC"
    [[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] && ok "Linux x86_64" || bad "needs Linux x86_64 (got $(uname -s) $(uname -m))"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        warn "WSL2: works only if the source is on the Linux ext4 disk (not /mnt/c) and .wslconfig gives it the RAM below"
    fi

    local cores mem_gb swap_gb
    cores=$(nproc)
    mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
    swap_gb=$(awk '/SwapTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
    if   (( cores >= REC_CORES )); then ok "$cores CPU threads"
    elif (( cores >= MIN_CORES )); then warn "$cores CPU threads (works, $REC_CORES+ recommended; expect a slow first build)"
    else bad "$cores CPU threads (minimum $MIN_CORES)"; fi
    if   (( mem_gb >= REC_MEM_GB - 2 )); then ok "${mem_gb} GB RAM"
    elif (( mem_gb + swap_gb >= MIN_MEM_GB - 2 )); then warn "${mem_gb} GB RAM + ${swap_gb} GB swap (works with fewer jobs; $REC_MEM_GB GB recommended)"
    else bad "${mem_gb} GB RAM + ${swap_gb} GB swap (minimum $MIN_MEM_GB GB together)"; fi

    local probe="$SRC" free_gb fstype
    while [[ ! -d "$probe" ]]; do probe="$(dirname "$probe")"; done
    free_gb=$(df -BG --output=avail "$probe" | tail -1 | tr -dc 0-9)
    fstype=$(df --output=fstype "$probe" | tail -1 | tr -d ' ')
    local used_gb=0
    [[ -d "$SRC/.repo" ]] && used_gb=$(du -s -BG "$SRC" 2>/dev/null | cut -f1 | tr -dc 0-9)
    if   (( free_gb + used_gb >= REC_DISK_GB )); then ok "${free_gb} GB free on $probe (+${used_gb} GB already in the tree)"
    elif (( free_gb + used_gb >= MIN_DISK_GB )); then warn "${free_gb} GB free on $probe (+${used_gb} GB in the tree); $REC_DISK_GB GB recommended"
    else bad "${free_gb} GB free on $probe (+${used_gb} GB in the tree); minimum $MIN_DISK_GB GB"; fi
    case "$fstype" in
        ext4|xfs|btrfs) ok "filesystem $fstype" ;;
        *) bad "filesystem $fstype: needs a case-sensitive Linux filesystem (ext4/xfs)" ;;
    esac

    if [[ $MODE == docker ]]; then
        if command -v docker >/dev/null && docker info >/dev/null 2>&1; then ok "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
        else bad "docker not available to $(id -un) (install Docker Engine, add the user to the docker group) or use --no-docker"; fi
    else
        local missing=()
        for t in git curl python3 zip unzip flex bison rsync; do command -v "$t" >/dev/null || missing+=("$t"); done
        command -v repo >/dev/null || missing+=(repo)
        (( ${#missing[@]} == 0 )) && ok "host tools present" || bad "missing tools: ${missing[*]} (see docker/Dockerfile for the package list)"
    fi
    if curl -fsS -m 10 -o /dev/null https://android.googlesource.com/platform/manifest/+/refs/tags/$TAG; then ok "android.googlesource.com reachable, tag $TAG exists"
    else bad "cannot reach android.googlesource.com or tag $TAG does not exist"; fi

    if (( FAILS > 0 )); then say "$FAILS requirement(s) not met"; else say "Machine is fine for this build"; fi
    return $FAILS
}

default_jobs() {
    local cores mem_gb
    cores=$(nproc)
    mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
    # Soong/ninja peaks at roughly 2 GB per job at link time; stay under RAM.
    local by_mem=$(( mem_gb / 2 )); (( by_mem < 1 )) && by_mem=1
    echo $(( cores < by_mem ? cores : by_mem ))
}

build_inside() {
    # Runs in /aosp (the container) or in $SRC (host mode).
    local log="$OUTDIR/build-$TAG-$(date +%Y%m%d-%H%M%S).log"
    exec > >(tee -a "$log") 2>&1
    say "Log: $log"
    local t0=$SECONDS

    if [[ ! -d .repo ]]; then
        say "repo init $TAG (shallow)"
        repo init -u https://android.googlesource.com/platform/manifest -b "$TAG" --depth=1
    fi
    say "repo sync -j$SYNC_JOBS"
    repo sync -c -j"$SYNC_JOBS" --no-tags --no-clone-bundle --optimized-fetch
    mkdir -p "$MANIFESTS"
    repo manifest -r -o "$MANIFESTS/$TAG.pinned.xml"
    say "sync done in $(( (SECONDS - t0) / 60 )) min; pinned manifest: $MANIFESTS/$TAG.pinned.xml"

    if [[ -n "$RELEASE" && ! -f "build/release/build_config/$RELEASE.scl" ]]; then
        echo "release config '$RELEASE' not found in build/release/build_config:" >&2
        ls build/release/build_config 2>/dev/null >&2 || echo "  (no build/release: pass --release \"\")" >&2
        exit 1
    fi

    local t1=$SECONDS
    # envsetup.sh and lunch are not written for errexit: check their results explicitly instead.
    set +e
    # shellcheck disable=SC1091
    source build/envsetup.sh || exit 1
    lunch "$LUNCH" || { echo "lunch $LUNCH failed" >&2; exit 1; }
    say "m -j$JOBS  ($LUNCH)"
    m -j"$JOBS" || { echo "build failed, see the log" >&2; exit 1; }
    say "m -j$JOBS emu_img_zip"
    m -j"$JOBS" emu_img_zip || { echo "emu_img_zip failed, see the log" >&2; exit 1; }
    set -e
    say "build done in $(( (SECONDS - t1) / 60 )) min"

    local product="out/target/product/$PRODUCT_DEVICE"
    local zip="$product/sdk-repo-linux-system-images.zip"
    [[ -f "$zip" ]] || { echo "no $zip" >&2; exit 1; }
    local name="mulka-aosp-$API-x86_64-$TAG"
    cp "$zip" "$OUTDIR/$name.zip"
    cp "$product/system/build.prop" "$OUTDIR/$name.build.prop"
    (cd "$OUTDIR" && sha256sum "$name.zip" > "$name.zip.sha256")
    say "Image: $OUTDIR/$name.zip ($(du -h "$OUTDIR/$name.zip" | cut -f1))"
    grep -E '^ro\.(system\.)?build\.(fingerprint|version\.security_patch)=' "$OUTDIR/$name.build.prop" || true
    say "Total $(( (SECONDS - t0) / 60 )) min. Copy the .zip and .sha256 to Windows and run images\\install-image.ps1"
}

if (( INSIDE )); then
    OUTDIR=/mulka-images/out; MANIFESTS=/mulka-images/manifests
    cd /aosp
    build_inside
    exit 0
fi

check_machine || { (( CHECK_ONLY )) && exit 1; (( FORCE )) || { echo "Use --force to build anyway." >&2; exit 1; }; }
(( CHECK_ONLY )) && exit 0

JOBS="${JOBS:-$(default_jobs)}"
mkdir -p "$SRC" "$HERE/out" "$HERE/manifests"
say "Building $LUNCH from $TAG with -j$JOBS"

if [[ $MODE == host ]]; then
    OUTDIR="$HERE/out"; MANIFESTS="$HERE/manifests"
    cd "$SRC"
    build_inside
else
    IMAGE=mulka-aosp-builder:ubuntu22.04
    docker build -t "$IMAGE" --build-arg UID="$(id -u)" --build-arg GID="$(id -g)" "$HERE/docker"
    docker run --rm -t --init \
        -v "$SRC":/aosp -v "$HERE":/mulka-images \
        "$IMAGE" bash /mulka-images/build-aosp.sh --inside \
        --tag "$TAG" --release "$RELEASE" --target "$TARGET" --variant "$VARIANT" \
        --jobs "$JOBS" --sync-jobs "$SYNC_JOBS"
fi
