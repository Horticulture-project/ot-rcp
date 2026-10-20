# shellcheck shell=bash
# shellcheck disable=SC2034  # constants and option variables are used by the sourcing scripts
# rcp-common.sh - shared helpers for the RCP update scripts. SOURCE this file, do not run it.
# An identical copy lives in every tool folder (dongle/, uart-modules/) on purpose: each folder
# must be copyable on its own. Keep the copies byte-identical (CI checks this).
#
# NOT verified on hardware. See README.md.

# Exit codes (documented in README.md)
EX_OK=0
EX_USAGE=2    # bad arguments, wrong image/variant for this flow
EX_ENTRY=3    # bootloader entry failed
EX_FLASH=4    # upload / flash failed
EX_VERIFY=5   # radio did not come back / version check failed
EX_DEPS=6     # missing tool, or download / checksum of a prerequisite failed

DRY_RUN=0
OTBR_SERVICE=otbr-agent
MANAGE_SERVICE=1
OTBR_STOPPED=0
WORKDIR=""
SUDO=()

# Pinned third-party tool: mcumgr-client v0.1.0 (https://github.com/vouch-opensource/mcumgr-client)
# sha256 of the release zips, taken from the published *.sha256sum files and re-computed on 2026-10-21.
MCUMGR_VERSION="v0.1.0"
MCUMGR_BASE_URL="https://github.com/vouch-opensource/mcumgr-client/releases/download/${MCUMGR_VERSION}"
MCUMGR_SHA256_AARCH64="7d1fd5d57415d78028c0bde6162372f449c608643a8881f31e7093e5d44a0722"
MCUMGR_SHA256_X86_64="3ac8c37343f29f3dc7aed1674440c26e9e0d977a331d03ba88dea619b9cde650"

# ---------------------------------------------------------------- logging
info() { printf '[rcp-update] %s\n' "$*" >&2; }
warn() { printf '[rcp-update] WARNING: %s\n' "$*" >&2; }
err() { printf '[rcp-update] ERROR: %s\n' "$*" >&2; }
die() {
    local code="$1"
    shift
    err "$*"
    exit "$code"
}

# Print a command the way a shell would need it typed.
quote_cmd() {
    local out="" a
    for a in "$@"; do out+="$(printf '%q' "$a") "; done
    printf '%s' "${out% }"
}

# run CMD...: print it, execute it unless --dry-run.
run() {
    info "+ $(quote_cmd "$@")"
    if [ "$DRY_RUN" = 1 ]; then
        return 0
    fi
    "$@"
}

# capture VAR CMD...: like run, but store stdout in VAR (empty string in dry-run).
# Status of the command is returned; stderr passes through.
capture() {
    local __var="$1" __out
    shift
    info "+ $(quote_cmd "$@")"
    if [ "$DRY_RUN" = 1 ]; then
        printf -v "$__var" '%s' ""
        return 0
    fi
    local rc=0
    __out="$("$@")" || rc=$?
    printf -v "$__var" '%s' "$__out"
    return "$rc"
}

# need_cmd NAME HINT: dependency check. Dry-run only warns.
need_cmd() {
    if command -v "$1" >/dev/null 2>&1; then
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        warn "(dry-run) '$1' not found: $2"
        return 0
    fi
    die "$EX_DEPS" "'$1' not found: $2"
}

setup_sudo() {
    SUDO=()
    if [ "$(id -u)" != 0 ] && command -v sudo >/dev/null 2>&1; then
        SUDO=(sudo)
    fi
}

# ---------------------------------------------------------------- temp dir and cleanup
make_workdir() {
    if [ "$DRY_RUN" = 1 ]; then
        WORKDIR="${TMPDIR:-/tmp}/rcp-update.DRYRUN"
        return 0
    fi
    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/rcp-update.XXXXXX")"
    chmod 700 "$WORKDIR"
}

# install_traps: ALWAYS restart the service on any exit path (only if we stopped it).
install_traps() {
    trap '_on_exit' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
}

_on_exit() {
    local rc=$?
    trap - EXIT INT TERM HUP
    otbr_start || warn "could not restart $OTBR_SERVICE, start it manually"
    if [ "$DRY_RUN" != 1 ] && [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
    fi
    if [ "$rc" -ne 0 ]; then
        info "finished with exit code $rc"
    fi
    exit "$rc"
}

# ---------------------------------------------------------------- otbr-agent
# otbr_stop: stop the service if it is active. The flag is set BEFORE the stop so that a
# half-failed stop is still followed by a start.
otbr_stop() {
    if [ "$MANAGE_SERVICE" != 1 ]; then
        info "service management disabled (--no-service): make sure nothing else uses the serial port"
        return 0
    fi
    if [ "$DRY_RUN" = 1 ]; then
        info "(dry-run) would stop $OTBR_SERVICE if it is active, and restart it on exit"
        OTBR_STOPPED=1
        return 0
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        die "$EX_DEPS" "systemctl not found; use --no-service if otbr-agent is not managed by systemd"
    fi
    if systemctl is-active --quiet "$OTBR_SERVICE"; then
        OTBR_STOPPED=1
        run "${SUDO[@]}" systemctl stop "$OTBR_SERVICE" || die "$EX_ENTRY" "could not stop $OTBR_SERVICE"
    else
        info "$OTBR_SERVICE is not active, it will not be started afterwards"
    fi
}

otbr_start() {
    if [ "$OTBR_STOPPED" != 1 ]; then
        return 0
    fi
    OTBR_STOPPED=0
    run "${SUDO[@]}" systemctl start "$OTBR_SERVICE"
}

# otctl_version: best-effort `ot-ctl rcp version` (first line), empty if unavailable.
otctl_version() {
    local v=""
    if [ "$DRY_RUN" = 1 ]; then
        info "+ ot-ctl rcp version   (best effort, while the agent still runs)"
        return 0
    fi
    if command -v ot-ctl >/dev/null 2>&1 && { [ "$MANAGE_SERVICE" != 1 ] || systemctl is-active --quiet "$OTBR_SERVICE" 2>/dev/null; }; then
        v="$(timeout 5 "${SUDO[@]}" ot-ctl rcp version 2>/dev/null | head -n 1 | tr -d '\r')" || v=""
        case "$v" in Done | Error* | "") v="" ;; esac
    fi
    printf '%s' "$v"
}

# ---------------------------------------------------------------- Spinel helper (Rust binary or python3)
SPINEL_KIND=""
SPINEL_BIN=""
SPINEL_PREF="auto"   # auto | rust | python
RCP_UPDATE_OPT=""

# find_spinel_tool SCRIPT_DIR
find_spinel_tool() {
    local dir="$1" cand=""
    SPINEL_KIND=""
    if [ "$SPINEL_PREF" != python ]; then
        for cand in "$RCP_UPDATE_OPT" "${RCP_UPDATE:-}" "$dir/rcp-update" "$(command -v rcp-update 2>/dev/null || true)"; do
            if [ -n "$cand" ] && [ -x "$cand" ]; then
                SPINEL_KIND=rust
                SPINEL_BIN="$cand"
                break
            fi
        done
    fi
    if [ -z "$SPINEL_KIND" ] && [ "$SPINEL_PREF" != rust ] && [ -f "$dir/rcp_spinel.py" ] && command -v python3 >/dev/null 2>&1; then
        SPINEL_KIND=python
        SPINEL_BIN="$dir/rcp_spinel.py"
    fi
    if [ -z "$SPINEL_KIND" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            warn "(dry-run) neither the rcp-update binary nor python3 + rcp_spinel.py found; commands shown as 'rcp-update'"
            SPINEL_KIND=rust
            SPINEL_BIN=rcp-update
        else
            die "$EX_DEPS" "need the rcp-update binary (put it next to this script, or --rcp-update PATH) or python3 with rcp_spinel.py"
        fi
    fi
    info "serial helper: $SPINEL_KIND ($SPINEL_BIN)"
}

# spinel_cmd ARGS...: command words for the helper (use with run / capture)
spinel_cmd() {
    if [ "$SPINEL_KIND" = python ]; then
        printf '%s\0' python3 -I "$SPINEL_BIN" "$@"
    else
        printf '%s\0' "$SPINEL_BIN" "$@"
    fi
}

# spinel VAR ARGS...: run the helper, stdout into VAR
spinel() {
    local __var="$1"
    shift
    local -a words=()
    while IFS= read -r -d '' w; do words+=("$w"); done < <(spinel_cmd "$@")
    capture "$__var" "${words[@]}"
}

# spinel_run ARGS...: run the helper, ignoring stdout
spinel_run() {
    local -a words=()
    while IFS= read -r -d '' w; do words+=("$w"); done < <(spinel_cmd "$@")
    run "${words[@]}"
}

# wait_version VAR PORT BAUD FLOW(0|1) TOTAL_SECONDS: poll the Spinel version until it answers.
# The port may not exist yet (re-enumeration) or may not answer yet (boot), so errors are retried.
wait_version() {
    local __var="$1" port="$2" baud="$3" flow="$4" total="$5" v="" end rc
    local -a fl=()
    [ "$flow" = 1 ] && fl=(--flow)
    if [ "$DRY_RUN" = 1 ]; then
        spinel "$__var" version --port "$port" --baud "$baud" "${fl[@]}" --timeout 5
        printf -v "$__var" '%s' "<dry-run>"
        return 0
    fi
    end=$((SECONDS + total))
    while :; do
        rc=0
        v="$(spinel_quiet version --port "$port" --baud "$baud" "${fl[@]}" --timeout 4)" || rc=$?
        if [ "$rc" = 0 ] && [ -n "$v" ]; then
            printf -v "$__var" '%s' "$v"
            return 0
        fi
        if [ "$SECONDS" -ge "$end" ]; then
            printf -v "$__var" '%s' ""
            return 1
        fi
        sleep 1
    done
}

# spinel_quiet ARGS...: like spinel but without echoing the command each time (used in poll loops)
spinel_quiet() {
    local -a words=()
    while IFS= read -r -d '' w; do words+=("$w"); done < <(spinel_cmd "$@")
    "${words[@]}" 2>/dev/null
}

# ---------------------------------------------------------------- downloads and checksums
http_get() { # URL OUT
    run curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 15 --output "$2" "$1"
}

http_exists() { # URL
    curl --fail --location --silent --head --proto '=https' --tlsv1.2 --connect-timeout 15 \
        --output /dev/null "$1" 2>/dev/null
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        die "$EX_DEPS" "sha256sum (coreutils) not found"
    fi
}

# verify_sha256 FILE EXPECTED_HEX LABEL
verify_sha256() {
    local actual
    case "$2" in
        *[!0-9a-fA-F]* | "") die "$EX_DEPS" "$3: checksum '$2' is not a hex string" ;;
    esac
    if [ "${#2}" != 64 ]; then
        die "$EX_DEPS" "$3: checksum has ${#2} digits, expected 64"
    fi
    actual="$(sha256_of "$1")"
    if [ "$(printf '%s' "$actual" | tr 'A-F' 'a-f')" != "$(printf '%s' "$2" | tr 'A-F' 'a-f')" ]; then
        die "$EX_DEPS" "$3: sha256 mismatch (expected $2, got $actual)"
    fi
    info "$3: sha256 OK ($actual)"
}

# verify_with_sidecar FILE SIDECAR_OR_EMPTY: the .sha256 written by CI contains "<hash>  <name>".
# Only the hash column is compared, so renaming the image does not break verification.
verify_with_sidecar() {
    local file="$1" side="${2:-}" want
    if [ -z "$side" ] || [ ! -f "$side" ]; then
        warn "no .sha256 file for $(basename "$file"): integrity is only protected by HTTPS (if downloaded)"
        return 0
    fi
    want="$(awk 'NF {print $1; exit}' "$side")"
    verify_sha256 "$file" "$want" "$(basename "$file")"
}

# ---------------------------------------------------------------- mcumgr-client
MCUMGR=""

host_arch() { # prints aarch64 | x86_64, or dies with a clear message
    local m bits
    m="$(uname -m)"
    bits="$(getconf LONG_BIT 2>/dev/null || echo 64)"
    case "$m" in
        aarch64 | arm64 | x86_64 | amd64)
            if [ "$bits" != 64 ]; then
                die "$EX_DEPS" "32-bit userland on a $m kernel: the mcumgr-client release is a 64-bit binary. Use 64-bit Raspberry Pi OS, or build mcumgr-client from source (cargo install --git https://github.com/vouch-opensource/mcumgr-client --tag $MCUMGR_VERSION)."
            fi
            case "$m" in aarch64 | arm64) echo aarch64 ;; *) echo x86_64 ;; esac
            ;;
        *)
            die "$EX_DEPS" "unsupported architecture '$m' (armv6/armv7 included): mcumgr-client $MCUMGR_VERSION only ships linux x86-64 and aarch64 binaries. Build it from source: cargo install --git https://github.com/vouch-opensource/mcumgr-client --tag $MCUMGR_VERSION, then pass --mcumgr PATH."
            ;;
    esac
}

# install_mcumgr DEST_DIR: download the pinned release into a fresh temp dir, verify, extract.
install_mcumgr() {
    local dest="$1" arch asset want dl bin
    need_cmd curl "install curl (apt install curl)"
    arch="$(host_arch)"
    if [ "$arch" = aarch64 ]; then
        asset="mcumgr-client-linux-aarch64.zip"
        want="$MCUMGR_SHA256_AARCH64"
    else
        asset="mcumgr-client-linux-x86.zip" # the upstream name for the x86-64 build
        want="$MCUMGR_SHA256_X86_64"
    fi
    dl="$WORKDIR/mcumgr-dl"
    run mkdir -p "$dl" "$dest"
    http_get "$MCUMGR_BASE_URL/$asset" "$dl/$asset"
    http_get "$MCUMGR_BASE_URL/$asset.sha256sum" "$dl/$asset.sha256sum"
    if [ "$DRY_RUN" = 1 ]; then
        info "(dry-run) would verify $asset against pinned sha256 $want and the published .sha256sum"
        return 0
    fi
    verify_sha256 "$dl/$asset" "$want" "$asset (pinned)"
    verify_sha256 "$dl/$asset" "$(awk 'NF {print $1; exit}' "$dl/$asset.sha256sum")" "$asset (published .sha256sum)"
    if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$dl/$asset" -d "$dl/x"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -I -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$dl/$asset" "$dl/x"
    else
        die "$EX_DEPS" "need unzip (apt install unzip) or python3 to unpack $asset"
    fi
    bin="$(find "$dl/x" -type f -name mcumgr-client | head -n 1)"
    [ -n "$bin" ] || die "$EX_DEPS" "mcumgr-client binary not found inside $asset"
    install -m 0755 "$bin" "$dest/mcumgr-client"
    info "installed $dest/mcumgr-client"
}

# find_mcumgr SCRIPT_DIR OPT_PATH INSTALL(0|1)
find_mcumgr() {
    local dir="$1" opt="$2" install="$3" cand tools
    tools="${RCP_TOOLS_DIR:-$dir/tools}"
    MCUMGR=""
    for cand in "$opt" "${MCUMGR_CLIENT:-}" "$tools/mcumgr-client" "$(command -v mcumgr-client 2>/dev/null || true)"; do
        if [ -n "$cand" ] && [ -x "$cand" ]; then
            MCUMGR="$cand"
            break
        fi
    done
    if [ -z "$MCUMGR" ] && [ "$install" = 1 ]; then
        install_mcumgr "$tools"
        MCUMGR="$tools/mcumgr-client"
    fi
    if [ -z "$MCUMGR" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            warn "(dry-run) mcumgr-client not found; commands shown as 'mcumgr-client' (--install-tools would download $MCUMGR_VERSION)"
            MCUMGR=mcumgr-client
            return 0
        fi
        die "$EX_DEPS" "mcumgr-client not found. Re-run with --install-tools (downloads and sha256-verifies $MCUMGR_VERSION), or pass --mcumgr PATH."
    fi
    if [ "$DRY_RUN" != 1 ]; then
        local v
        v="$("$MCUMGR" --version 2>/dev/null | head -n 1 || true)"
        case "$v" in
            *" ${MCUMGR_VERSION#v}") info "mcumgr-client: $v" ;;
            *) warn "mcumgr-client reports '${v:-nothing}', flags in this script were checked against ${MCUMGR_VERSION#v} only" ;;
        esac
    fi
}

# ---------------------------------------------------------------- last known good image
state_dir() { printf '%s' "${RCP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/rcp-update}"; }

# remember_good KEY FILE [SIDECAR]: current -> previous, FILE -> current. Failures only warn.
remember_good() {
    local key="$1" file="$2" side="${3:-}" d
    d="$(state_dir)/$key"
    if [ "$DRY_RUN" = 1 ]; then
        info "(dry-run) would keep $(basename "$file") as last known good in $d/current (old one -> $d/previous)"
        return 0
    fi
    {
        rm -rf "$d/previous" &&
            { [ ! -d "$d/current" ] || mv "$d/current" "$d/previous"; } &&
            mkdir -p "$d/current" &&
            cp "$file" "$d/current/" &&
            { [ -z "$side" ] || [ ! -f "$side" ] || cp "$side" "$d/current/"; }
    } || warn "could not store the last known good image in $d"
}

# previous_image KEY: print the path of the stored previous image (empty if none)
previous_image() {
    local d f
    d="$(state_dir)/$1/previous"
    for f in "$d"/*; do
        case "$f" in *.sha256) continue ;; esac
        if [ -f "$f" ]; then
            printf '%s' "$f"
            return 0
        fi
    done
}

# ---------------------------------------------------------------- misc
is_uint() { case "$1" in "" | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

file_size() { wc -c <"$1" | tr -d ' '; }

# image_magic_ok FILE: MCUboot image header magic 0x96f3b83d (little endian on flash: 3d b8 f3 96)
image_magic_ok() {
    [ "$(od -An -tx1 -N4 "$1" | tr -d ' \n')" = "3db8f396" ]
}
