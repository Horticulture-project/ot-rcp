#!/usr/bin/env bash
# update-uart-module.sh - update the RCP firmware of a UART-connected module (Ebyte E73 or
# Ezurio nRF54L15) from a Raspberry Pi: Spinel reset-to-bootloader -> MCUboot serial recovery
# (mcumgr-client: echo, list, upload --slot 2, test, reset) -> wait for the radio.
#
# NOT verified on hardware. Needs the "-mcuboot" firmware variant (MCUboot + app flashed once via
# SWD from the merged hex). Plain builds cannot be updated this way.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rcp-common.sh
. "$SCRIPT_DIR/rcp-common.sh"

DEFAULT_REPO="Horticulture-project/ot-rcp"

BOARD=""
PORT=""
FILE=""
RELEASE=""
REPO="$DEFAULT_REPO"
VARIANT="mcuboot"
BAUD=115200
FLOW=0
RECOVERY_BAUD=115200
ALLOW_DEVKEY=0
ALLOW_SAME=0
SKIP_RESET=0
DEEP_VERIFY=0
ROLLBACK=0
INSTALL_TOOLS=0
INSTALL_ONLY=0
MCUMGR_OPT=""
PROBE_WAIT=20
UPLOAD_TIMEOUT=180
VERIFY_WAIT=40
LIST0="" LIST1="" LIST2="" LIST3=""

usage() {
    cat <<'EOF'
Usage: update-uart-module.sh --board e73|nrf54l15 --port PORT --baud N [--flow]
                             (--file image | --release TAG | --rollback) [options]

Required
  --board B           e73 (Ebyte E73, nRF52840) or nrf54l15 (Ezurio, nRF54L15)
  --port PATH         serial port wired to the module, e.g. /dev/ttyAMA0. Nothing else is touched.
  --file IMAGE        signed update image, e.g. rcp-ebyte-e73-nrf52840-115200baud-noflow-mcuboot-update.bin
  --release TAG       download it from the GitHub release TAG (a .sha256 asset is verified)
  --rollback          upload the previous known good image kept by this script

Application serial settings (used to reach the RCP for the Spinel reset; they also select the
release asset: rcp-<module>-<baud>baud-<flow|noflow>-mcuboot-update.bin)
  --baud N            application baud (default 115200; 460800 for the flow-control variants)
  --flow              application uses RTS/CTS

Options
  --repo OWNER/REPO   repository for --release (default Horticulture-project/ot-rcp)
  --variant V         mcuboot (default) or plain. plain is refused: plain images cannot be
                      uploaded through MCUboot recovery (flash them over SWD)
  --allow-devkey      accept images signed with MCUboot's PUBLIC development key (-DEVKEY names).
                      Never ship modules built that way.
  --allow-same-version  do not fail if the RCP version string is unchanged after the update
  --skip-reset        the module is already in MCUboot recovery, do not send the Spinel frame
  --deep-verify       after the update re-enter recovery and check that slot 0 holds the uploaded
                      hash (one extra reboot cycle)
  --recovery-baud N   MCUboot recovery baud (default 115200 = fixed by the firmware build)
  --mcumgr PATH       mcumgr-client binary (default: ./tools/mcumgr-client, then PATH)
  --install-tools     download and sha256-verify the pinned mcumgr-client if it is missing
  --install-tools-only  do that and exit
  --rcp-update PATH   Rust helper binary (default: ./rcp-update, then PATH); python3 + rcp_spinel.py otherwise
  --spinel-tool T     auto (default) | rust | python
  --service NAME      systemd unit to stop/start (default otbr-agent)
  --no-service        do not manage any service
  --dry-run           print every command, touch nothing
  -h, --help

Exit codes: 0 ok, 2 usage, 3 bootloader entry failed, 4 upload failed, 5 verification failed,
6 missing dependency / download / checksum problem.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --board) BOARD="${2:?--board needs a value}"; shift 2 ;;
        --port) PORT="${2:?--port needs a value}"; shift 2 ;;
        --file) FILE="${2:?--file needs a value}"; shift 2 ;;
        --release) RELEASE="${2:?--release needs a value}"; shift 2 ;;
        --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
        --variant) VARIANT="${2:?--variant needs a value}"; shift 2 ;;
        --baud) BAUD="${2:?--baud needs a value}"; shift 2 ;;
        --flow) FLOW=1; shift ;;
        --recovery-baud) RECOVERY_BAUD="${2:?--recovery-baud needs a value}"; shift 2 ;;
        --allow-devkey) ALLOW_DEVKEY=1; shift ;;
        --allow-same-version) ALLOW_SAME=1; shift ;;
        --skip-reset) SKIP_RESET=1; shift ;;
        --deep-verify) DEEP_VERIFY=1; shift ;;
        --rollback) ROLLBACK=1; shift ;;
        --mcumgr) MCUMGR_OPT="${2:?--mcumgr needs a value}"; shift 2 ;;
        --install-tools) INSTALL_TOOLS=1; shift ;;
        --install-tools-only) INSTALL_TOOLS=1; INSTALL_ONLY=1; shift ;;
        --rcp-update) RCP_UPDATE_OPT="${2:?--rcp-update needs a value}"; shift 2 ;;
        --spinel-tool) SPINEL_PREF="${2:?--spinel-tool needs a value}"; shift 2 ;;
        --service) OTBR_SERVICE="${2:?--service needs a value}"; shift 2 ;;
        --no-service) MANAGE_SERVICE=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "$EX_USAGE" "unknown argument: $1" ;;
    esac
done

setup_sudo
make_workdir
install_traps
if [ "$INSTALL_ONLY" = 1 ]; then
    find_mcumgr "$SCRIPT_DIR" "$MCUMGR_OPT" 1
    info "mcumgr-client ready: $MCUMGR"
    exit "$EX_OK"
fi

# ------------------------------------------------------------------ argument validation
case "$BOARD" in
    e73) NAME="ebyte-e73-nrf52840"; MAX_IMAGE=$((472 * 1024)) ;;
    nrf54l15) NAME="ezurio-nrf54l15"; MAX_IMAGE=$((712 * 1024)) ;;
    "") usage >&2; die "$EX_USAGE" "--board is required (e73 or nrf54l15)" ;;
    *) die "$EX_USAGE" "unknown board '$BOARD' (e73 or nrf54l15; the dongle has its own script)" ;;
esac
[ -n "$PORT" ] || { usage >&2; die "$EX_USAGE" "--port is required (explicit device selection only)"; }
n=0
[ -n "$FILE" ] && n=$((n + 1))
[ -n "$RELEASE" ] && n=$((n + 1))
[ "$ROLLBACK" = 1 ] && n=$((n + 1))
[ "$n" = 1 ] || { usage >&2; die "$EX_USAGE" "give exactly one of --file, --release, --rollback"; }
is_uint "$BAUD" || die "$EX_USAGE" "--baud must be a number"
is_uint "$RECOVERY_BAUD" || die "$EX_USAGE" "--recovery-baud must be a number"
case "$VARIANT" in
    mcuboot) ;;
    plain) die "$EX_USAGE" "plain images (rcp-$NAME-<baud>baud-<flow>.hex/.bin) cannot be uploaded through MCUboot serial recovery. Flash them over SWD, or use the -mcuboot variant (flash its merged .hex over SWD once, then update with the -mcuboot-update.bin)." ;;
    *) die "$EX_USAGE" "--variant must be mcuboot or plain" ;;
esac
case "$SPINEL_PREF" in auto | rust | python) ;; *) die "$EX_USAGE" "--spinel-tool must be auto, rust or python" ;; esac
case "$REPO" in */*) ;; *) die "$EX_USAGE" "--repo must look like OWNER/REPO" ;; esac
if [ "$FLOW" = 1 ]; then FLOWNAME=flow; else FLOWNAME=noflow; fi
KEY="$NAME-${BAUD}baud-$FLOWNAME"
if [ -n "$FILE" ]; then
    base="$(basename "$FILE")"
    case "$base" in
        *DEVKEY* | *devkey*)
            [ "$ALLOW_DEVKEY" = 1 ] ||
                die "$EX_USAGE" "$base is signed with MCUboot's PUBLIC development key (INSECURE). Pass --allow-devkey to use it anyway, and do not ship such modules."
            ;;
    esac
    case "$base" in
        *-mcuboot-*update.bin) ;;
        *.hex) die "$EX_USAGE" "$base is a .hex image. MCUboot recovery needs the signed *-update.bin" ;;
        *) warn "$base does not look like rcp-<module>-...-mcuboot-update.bin; the header check below decides" ;;
    esac
    if [ "$DRY_RUN" != 1 ] && [ ! -f "$FILE" ]; then die "$EX_USAGE" "file not found: $FILE"; fi
fi

[ "$DRY_RUN" = 1 ] && info "DRY RUN: nothing below is executed"
if [ -n "$RELEASE" ]; then need_cmd curl "apt install curl"; fi
need_cmd awk "install awk"
find_spinel_tool "$SCRIPT_DIR"
find_mcumgr "$SCRIPT_DIR" "$MCUMGR_OPT" "$INSTALL_TOOLS"
if [ "$DRY_RUN" != 1 ]; then [ -c "$PORT" ] || die "$EX_USAGE" "$PORT is not a character device"; fi

# ------------------------------------------------------------------ get the image
IMAGE=""
SIDECAR=""
if [ "$ROLLBACK" = 1 ]; then
    IMAGE="$(previous_image "$KEY" || true)"
    if [ -z "$IMAGE" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            IMAGE="$(state_dir)/$KEY/previous/<image>-update.bin"
            info "(dry-run) no stored previous image; real run would stop here"
        else
            die "$EX_USAGE" "no previous known good image stored in $(state_dir)/$KEY/previous"
        fi
    elif [ -f "$IMAGE.sha256" ]; then
        SIDECAR="$IMAGE.sha256"
    fi
    info "rollback image: $IMAGE"
elif [ -n "$RELEASE" ]; then
    ASSET="rcp-$NAME-${BAUD}baud-$FLOWNAME-mcuboot-update.bin"
    ASSET_DEV="rcp-$NAME-${BAUD}baud-$FLOWNAME-mcuboot-DEVKEY-update.bin"
    BASE_URL="https://github.com/$REPO/releases/download/$RELEASE"
    run mkdir -p "$WORKDIR/image"
    CHOSEN="$ASSET"
    if [ "$DRY_RUN" = 1 ]; then
        info "(dry-run) would look for $BASE_URL/$ASSET, then (needs --allow-devkey) $BASE_URL/$ASSET_DEV"
    elif http_exists "$BASE_URL/$ASSET"; then
        CHOSEN="$ASSET"
    elif http_exists "$BASE_URL/$ASSET_DEV"; then
        [ "$ALLOW_DEVKEY" = 1 ] ||
            die "$EX_USAGE" "release $RELEASE only has the DEVKEY build ($ASSET_DEV), signed with MCUboot's PUBLIC development key (INSECURE). Pass --allow-devkey to use it; do not ship modules built that way."
        warn "using the DEVKEY image $ASSET_DEV (public development key, INSECURE)"
        CHOSEN="$ASSET_DEV"
    else
        die "$EX_DEPS" "neither $ASSET nor $ASSET_DEV exists in release $RELEASE of $REPO (check --baud/--flow/--board and the tag; plain images are not usable here)"
    fi
    http_get "$BASE_URL/$CHOSEN" "$WORKDIR/image/$CHOSEN" || die "$EX_DEPS" "download failed: $BASE_URL/$CHOSEN"
    if [ "$DRY_RUN" = 1 ] || http_exists "$BASE_URL/$CHOSEN.sha256"; then
        http_get "$BASE_URL/$CHOSEN.sha256" "$WORKDIR/image/$CHOSEN.sha256" || die "$EX_DEPS" "download failed: $BASE_URL/$CHOSEN.sha256"
        SIDECAR="$WORKDIR/image/$CHOSEN.sha256"
    fi
    IMAGE="$WORKDIR/image/$CHOSEN"
else
    IMAGE="$FILE"
    [ -f "$FILE.sha256" ] && SIDECAR="$FILE.sha256"
fi
if [ "$DRY_RUN" != 1 ]; then
    [ -s "$IMAGE" ] || die "$EX_DEPS" "image missing or empty: $IMAGE"
    verify_with_sidecar "$IMAGE" "$SIDECAR"
    image_magic_ok "$IMAGE" || die "$EX_USAGE" "$(basename "$IMAGE") has no MCUboot image header (magic 0x96f3b83d): it is not a signed *-update.bin (a raw zephyr.bin cannot be used)"
    size="$(file_size "$IMAGE")"
    [ "$size" -le "$MAX_IMAGE" ] || die "$EX_USAGE" "image is $size bytes, larger than the $BOARD slot ($MAX_IMAGE bytes)"
    info "image: $IMAGE ($size bytes)"
fi

# mcumgr-client calls. -s silences the banner (only for the echo probe: errors then show only as exit code 1).
mcu_probe() { "$MCUMGR" -s -d "$PORT" -b "$RECOVERY_BAUD" -t 2 echo ping >/dev/null 2>&1; }

# probe_loop SECONDS: echo once per second until MCUboot answers
probe_loop() {
    local end
    if [ "$DRY_RUN" = 1 ]; then
        info "+ $(quote_cmd "$MCUMGR" -s -d "$PORT" -b "$RECOVERY_BAUD" -t 2 echo ping)   (repeated once per second, up to $1 s)"
        return 0
    fi
    end=$((SECONDS + $1))
    while :; do
        if mcu_probe; then return 0; fi
        [ "$SECONDS" -lt "$end" ] || return 1
        sleep 1
    done
}

# list_parse FILE_TEXT SLOT KEY: pull a field of one slot out of `mcumgr-client list` (pretty JSON,
# field order image, slot, version, hash, bootable, pending, ... as in nmp_hdr.rs ImageStateEntry)
list_field() {
    printf '%s\n' "$1" | awk -v slot="$2" -v key="$3" '
        /"slot":/ { s = $0; gsub(/[^0-9]/, "", s); cur = s; next }
        cur == slot && $0 ~ "\"" key "\":" {
            v = $0; sub(/^[^:]*:[ ]*/, "", v); gsub(/[",]/, "", v); print v; exit }'
}

# ------------------------------------------------------------------ step 0/1: version, stop agent, enter recovery
PRE_OTCTL="$(otctl_version)"
[ -z "$PRE_OTCTL" ] || info "ot-ctl rcp version (before): $PRE_OTCTL"
otbr_stop
PRE_VERSION=""
wait_version PRE_VERSION "$PORT" "$BAUD" "$FLOW" 5 || warn "module did not answer a Spinel version query before the update (continuing)"
[ -z "$PRE_VERSION" ] || info "Spinel version (before): $PRE_VERSION"

enter_recovery() {
    local -a fl=()
    [ "$FLOW" = 1 ] && fl=(--flow)
    spinel_run reset-bootloader --port "$PORT" --baud "$BAUD" "${fl[@]}" || return 1
    sleep 1
    probe_loop "$PROBE_WAIT"
}

if [ "$SKIP_RESET" = 1 ]; then
    info "--skip-reset: assuming MCUboot recovery is already active"
    probe_loop 5 || die "$EX_ENTRY" "no SMP echo answer from $PORT at $RECOVERY_BAUD baud"
else
    if [ "$DRY_RUN" != 1 ] && mcu_probe; then
        info "MCUboot already answers on $PORT: skipping the Spinel reset"
    else
        enter_recovery || die "$EX_ENTRY" "no MCUboot answer within ${PROBE_WAIT}s after the Spinel reset frame. Possible causes: firmware without bootloader mode (not the -mcuboot build), wrong --baud/--flow, port still held by another process. See README, failure table."
    fi
fi
info "MCUboot serial recovery is active"

# ------------------------------------------------------------------ step 2: inspect, upload
capture LIST0 "$MCUMGR" -d "$PORT" -b "$RECOVERY_BAUD" -t 5 list || die "$EX_ENTRY" "mcumgr-client list failed"
[ -z "$LIST0" ] || printf '%s\n' "$LIST0" >&2
HASH0="$(list_field "$LIST0" 0 hash)"

if [ "$DRY_RUN" != 1 ] && command -v timeout >/dev/null 2>&1; then
    UP_PREFIX=(timeout "$UPLOAD_TIMEOUT")
else
    UP_PREFIX=()
fi
# --slot 2 selects slot1_partition (secondary) with CONFIG_MCUBOOT_SERIAL_DIRECT_IMAGE_UPLOAD; the
# client default of 1 would overwrite the primary slot. Do not put "slot1"/"slot3" in the file name.
case "$(basename "$IMAGE")" in
    *slot1* | *slot3* | *SLOT1* | *SLOT3*) die "$EX_USAGE" "image file name contains 'slot1'/'slot3': mcumgr-client would override --slot. Rename the file." ;;
esac
if ! run "${UP_PREFIX[@]}" "$MCUMGR" -d "$PORT" -b "$RECOVERY_BAUD" -t 10 -u 500 --nb-retry 8 upload "$IMAGE" --slot 2; then
    err "upload failed. The running image is untouched (it went to the secondary slot); retry the whole script."
    exit "$EX_FLASH"
fi

capture LIST1 "$MCUMGR" -d "$PORT" -b "$RECOVERY_BAUD" -t 5 list || die "$EX_FLASH" "mcumgr-client list failed after the upload"
[ -z "$LIST1" ] || printf '%s\n' "$LIST1" >&2
if [ "$DRY_RUN" = 1 ]; then
    HASH1="<hash of slot 1>"
else
    HASH1="$(list_field "$LIST1" 1 hash)"
    case "$HASH1" in
        "" | *[!0-9a-fA-F]*) die "$EX_FLASH" "slot 1 has no image hash in the list output after the upload" ;;
    esac
    if [ -n "$HASH0" ] && [ "$HASH0" = "$HASH1" ]; then
        warn "slot 1 holds the same image as slot 0 (hash $HASH1): the module already runs this firmware"
    fi
fi

# ------------------------------------------------------------------ step 3: test, reset
run "$MCUMGR" -d "$PORT" -b "$RECOVERY_BAUD" -t 5 test "$HASH1" || die "$EX_FLASH" "mcumgr-client test failed"
capture LIST2 "$MCUMGR" -d "$PORT" -b "$RECOVERY_BAUD" -t 5 list || die "$EX_FLASH" "mcumgr-client list failed after test"
if [ "$DRY_RUN" != 1 ]; then
    [ "$(list_field "$LIST2" 1 pending)" = true ] || die "$EX_FLASH" "slot 1 is not pending after 'test' (list output above); not resetting"
fi
run "$MCUMGR" -d "$PORT" -b "$RECOVERY_BAUD" -t 5 reset || die "$EX_FLASH" "mcumgr-client reset failed"

# ------------------------------------------------------------------ step 4: verify
verify_fail() {
    # distinguish "stuck in MCUboot" from "app dead"
    if [ "$DRY_RUN" != 1 ] && mcu_probe; then
        err "the module answers SMP: it is in MCUboot recovery. MCUboot did not accept the new image (wrong signing key, or dev-key image on a production module). The old image is still in slot 0."
    fi
    die "$EX_VERIFY" "$1"
}

[ "$DRY_RUN" = 1 ] || sleep 3
POST_VERSION=""
wait_version POST_VERSION "$PORT" "$BAUD" "$FLOW" "$VERIFY_WAIT" ||
    verify_fail "no Spinel answer from $PORT within ${VERIFY_WAIT}s after the reset (app baud $BAUD, flow $FLOW). Use --rollback or upload a known good image."
info "Spinel version (after): $POST_VERSION"
if [ "$DRY_RUN" = 1 ]; then
    info "(dry-run) would compare the version before and after"
elif [ -n "$PRE_VERSION" ] && [ "$PRE_VERSION" = "$POST_VERSION" ]; then
    if [ "$ALLOW_SAME" = 1 ]; then
        warn "version string unchanged"
    else
        verify_fail "RCP version string is unchanged ($POST_VERSION): the update may not have been applied (or the build embeds no new timestamp: use --allow-same-version / --deep-verify)."
    fi
elif [ -n "$PRE_VERSION" ]; then
    info "version changed: OK"
fi

if [ "$DEEP_VERIFY" = 1 ]; then
    info "deep verify: re-entering recovery to read slot 0"
    enter_recovery || verify_fail "deep verify: no MCUboot answer"
    capture LIST3 "$MCUMGR" -d "$PORT" -b "$RECOVERY_BAUD" -t 5 list || verify_fail "deep verify: list failed"
    if [ "$DRY_RUN" != 1 ]; then
        [ "$(list_field "$LIST3" 0 hash)" = "$HASH1" ] || verify_fail "deep verify: slot 0 hash differs from the uploaded image"
    fi
    run "$MCUMGR" -d "$PORT" -b "$RECOVERY_BAUD" -t 5 reset || verify_fail "deep verify: reset failed"
    [ "$DRY_RUN" = 1 ] || sleep 3
    wait_version POST_VERSION "$PORT" "$BAUD" "$FLOW" "$VERIFY_WAIT" || verify_fail "deep verify: radio did not come back"
    info "deep verify OK: slot 0 hash matches the uploaded image"
fi

# ------------------------------------------------------------------ done
if [ "$ROLLBACK" != 1 ]; then remember_good "$KEY" "$IMAGE" "$SIDECAR"; fi
otbr_start || true
if [ "$DRY_RUN" != 1 ]; then
    sleep 5
    POST_OTCTL="$(otctl_version)"
    [ -z "$POST_OTCTL" ] || info "ot-ctl rcp version (after): $POST_OTCTL"
fi
info "update of $BOARD finished"
exit "$EX_OK"
