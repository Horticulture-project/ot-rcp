#!/usr/bin/env bash
# update-dongle.sh - update the RCP firmware of the Holyiot nRF52840 USB dongle from a
# Raspberry Pi: 1200-baud touch -> USB DFU bootloader -> nrfutil -> wait for the radio.
#
# NOT verified on hardware. Works only with the "-dfutouch" firmware variant (it contains the
# 1200-baud touch module); a plain build needs the reset button (use --skip-touch).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rcp-common.sh
. "$SCRIPT_DIR/rcp-common.sh"

DEFAULT_REPO="Horticulture-project/ot-rcp"
ASSET_BASE="rcp-holyiot-nrf52840-dongle-usb"

PORT=""
FILE=""
RELEASE=""
REPO="$DEFAULT_REPO"
VARIANT="dfutouch"
BAUD=460800
FLOW=0
APP_VIDPID="1915:0000"
DFU_VIDPID="1915:521f"
DFU_PORT=""
SKIP_TOUCH=0
NRFUTIL="nrfutil"
ROLLBACK=0
VERIFY=1
TOUCH_WAIT=10
APP_WAIT=20

usage() {
    cat <<'EOF'
Usage: update-dongle.sh --port PORT (--file dfu.zip | --release TAG | --rollback) [options]

Required
  --port PATH         CDC ACM port of the dongle in application mode (the Spinel port that
                      otbr-agent uses), e.g. /dev/serial/by-id/usb-...-if00. Nothing else is touched.
  --file ZIP          DFU package, e.g. rcp-holyiot-nrf52840-dongle-usb-dfutouch-dfu.zip
  --release TAG       download the package from the GitHub release TAG
                      (e.g. ncs-v3.4.1_thread-1.4_ot-0fe68ff)
  --rollback          flash the previous known good package kept by this script

Options
  --repo OWNER/REPO   GitHub repository for --release (default Horticulture-project/ot-rcp)
  --variant V         dfutouch (default; supports the 1200-baud touch) or plain
                      (plain builds cannot be touched: needs --skip-touch)
  --baud N            baud used to talk Spinel to the app (default 460800; CDC ignores it, must not be 1200)
  --flow              accepted for symmetry with the UART script; no effect on USB
  --skip-touch        the dongle is already in DFU mode (reset button), skip the 1200-baud touch
  --dfu-port PATH     use this tty for DFU instead of searching for the bootloader's VID:PID
  --app-vid-pid V:P   application USB id (default 1915:0000)
  --dfu-vid-pid V:P   bootloader USB id (default 1915:521f, assumed from Nordic's dongle: verify)
  --nrfutil PATH      nrfutil binary (default: nrfutil from PATH)
  --rcp-update PATH   Rust helper binary (default: ./rcp-update, then PATH); python3 + rcp_spinel.py otherwise
  --spinel-tool T     auto (default) | rust | python
  --service NAME      systemd unit to stop/start (default otbr-agent)
  --no-service        do not manage any service
  --no-verify         skip the post-flash Spinel check
  --dry-run           print every command, touch nothing
  -h, --help

Exit codes: 0 ok, 2 usage, 3 bootloader entry failed, 4 flash failed, 5 verification failed,
6 missing dependency / download / checksum problem.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --port) PORT="${2:?--port needs a value}"; shift 2 ;;
        --file) FILE="${2:?--file needs a value}"; shift 2 ;;
        --release) RELEASE="${2:?--release needs a value}"; shift 2 ;;
        --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
        --variant) VARIANT="${2:?--variant needs a value}"; shift 2 ;;
        --baud) BAUD="${2:?--baud needs a value}"; shift 2 ;;
        --flow) FLOW=1; shift ;;
        --skip-touch) SKIP_TOUCH=1; shift ;;
        --dfu-port) DFU_PORT="${2:?--dfu-port needs a value}"; shift 2 ;;
        --app-vid-pid) APP_VIDPID="${2:?}"; shift 2 ;;
        --dfu-vid-pid) DFU_VIDPID="${2:?}"; shift 2 ;;
        --nrfutil) NRFUTIL="${2:?--nrfutil needs a value}"; shift 2 ;;
        --rcp-update) RCP_UPDATE_OPT="${2:?--rcp-update needs a value}"; shift 2 ;;
        --spinel-tool) SPINEL_PREF="${2:?--spinel-tool needs a value}"; shift 2 ;;
        --service) OTBR_SERVICE="${2:?--service needs a value}"; shift 2 ;;
        --no-service) MANAGE_SERVICE=0; shift ;;
        --rollback) ROLLBACK=1; shift ;;
        --no-verify) VERIFY=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; die "$EX_USAGE" "unknown argument: $1" ;;
    esac
done

# ------------------------------------------------------------------ argument validation
[ -n "$PORT" ] || { usage >&2; die "$EX_USAGE" "--port is required (explicit device selection only)"; }
n=0
[ -n "$FILE" ] && n=$((n + 1))
[ -n "$RELEASE" ] && n=$((n + 1))
[ "$ROLLBACK" = 1 ] && n=$((n + 1))
[ "$n" = 1 ] || { usage >&2; die "$EX_USAGE" "give exactly one of --file, --release, --rollback"; }
is_uint "$BAUD" || die "$EX_USAGE" "--baud must be a number"
[ "$BAUD" != 1200 ] || die "$EX_USAGE" "--baud 1200 would reboot the dongle into DFU; use another rate"
case "$VARIANT" in dfutouch | plain) ;; *) die "$EX_USAGE" "--variant must be dfutouch or plain" ;; esac
case "$SPINEL_PREF" in auto | rust | python) ;; *) die "$EX_USAGE" "--spinel-tool must be auto, rust or python" ;; esac
case "$REPO" in */*) ;; *) die "$EX_USAGE" "--repo must look like OWNER/REPO" ;; esac
if [ "$VARIANT" = plain ] && [ "$SKIP_TOUCH" != 1 ] && [ "$ROLLBACK" != 1 ]; then
    die "$EX_USAGE" "the plain dongle build has no 1200-baud touch: put the dongle into DFU mode with its reset button and use --skip-touch, or use the -dfutouch variant"
fi
if [ -n "$FILE" ]; then
    case "$(basename "$FILE")" in
        *dfutouch*) ;;
        rcp-*-usb-dfu.zip)
            [ "$SKIP_TOUCH" = 1 ] ||
                die "$EX_USAGE" "$(basename "$FILE") is the PLAIN dongle build (no 1200-baud touch). Use the *-dfutouch-dfu.zip package, or enter DFU mode with the reset button and pass --skip-touch."
            ;;
        *) warn "cannot tell from the file name whether this package contains the touch module (expected *-dfutouch-dfu.zip)" ;;
    esac
fi
if [ -n "$FILE" ] && [ "$DRY_RUN" != 1 ] && [ ! -f "$FILE" ]; then
    die "$EX_USAGE" "file not found: $FILE"
fi

setup_sudo
make_workdir
install_traps
[ "$DRY_RUN" = 1 ] && info "DRY RUN: nothing below is executed"

# ------------------------------------------------------------------ dependencies
find_spinel_tool "$SCRIPT_DIR"
NRFUTIL_FLAVOUR=""
# Flavour detection (see README, "nrfutil"): the new Rust nrfutil with the nrf5sdk-tools command
# (wraps pc-nrfutil 6.1.7) or the legacy Python nrfutil 6.1.x.
if [ "$DRY_RUN" = 1 ]; then
    NRFUTIL_FLAVOUR=new
    info "(dry-run) assuming new nrfutil with the nrf5sdk-tools command"
    if ! command -v "$NRFUTIL" >/dev/null 2>&1; then warn "(dry-run) '$NRFUTIL' not found"; fi
elif command -v "$NRFUTIL" >/dev/null 2>&1; then
    if "$NRFUTIL" nrf5sdk-tools dfu usb-serial --help >/dev/null 2>&1; then
        NRFUTIL_FLAVOUR=new
    elif "$NRFUTIL" dfu usb-serial --help >/dev/null 2>&1; then
        NRFUTIL_FLAVOUR=legacy
    fi
fi
if [ -z "$NRFUTIL_FLAVOUR" ]; then
    die "$EX_DEPS" "no usable nrfutil. Install the new nrfutil and run 'nrfutil install nrf5sdk-tools' (see README); the legacy 'pip install nrfutil' does not install on Python >= 3.11"
fi
info "nrfutil flavour: $NRFUTIL_FLAVOUR"
if [ -n "$RELEASE" ]; then need_cmd curl "apt install curl"; fi

# ------------------------------------------------------------------ get the image
IMAGE=""
SIDECAR=""
if [ "$ROLLBACK" = 1 ]; then
    IMAGE="$(previous_image dongle || true)"
    if [ -z "$IMAGE" ]; then
        if [ "$DRY_RUN" = 1 ]; then
            IMAGE="$(state_dir)/dongle/previous/<package>.zip"
            info "(dry-run) no stored previous package; real run would stop here"
        else
            die "$EX_USAGE" "no previous known good package stored in $(state_dir)/dongle/previous"
        fi
    fi
    info "rollback package: $IMAGE"
elif [ -n "$RELEASE" ]; then
    if [ "$VARIANT" = dfutouch ]; then ASSET="$ASSET_BASE-dfutouch-dfu.zip"; else ASSET="$ASSET_BASE-dfu.zip"; fi
    URL="https://github.com/$REPO/releases/download/$RELEASE/$ASSET"
    run mkdir -p "$WORKDIR/image"
    http_get "$URL" "$WORKDIR/image/$ASSET" || die "$EX_DEPS" "download failed: $URL"
    IMAGE="$WORKDIR/image/$ASSET"
    # CI currently publishes no checksum for the dongle zip; a .sha256 is used if one exists.
    if [ "$DRY_RUN" = 1 ]; then
        info "(dry-run) would try $URL.sha256 and verify it if present"
    elif http_exists "$URL.sha256"; then
        http_get "$URL.sha256" "$WORKDIR/image/$ASSET.sha256" || die "$EX_DEPS" "download failed: $URL.sha256"
        SIDECAR="$WORKDIR/image/$ASSET.sha256"
    fi
else
    IMAGE="$FILE"
    [ -f "$FILE.sha256" ] && SIDECAR="$FILE.sha256"
fi
if [ "$DRY_RUN" != 1 ]; then
    [ -s "$IMAGE" ] || die "$EX_DEPS" "package missing or empty: $IMAGE"
    verify_with_sidecar "$IMAGE" "$SIDECAR"
fi

# ------------------------------------------------------------------ device checks
if [ "$DRY_RUN" != 1 ] && [ "$SKIP_TOUCH" != 1 ]; then
    [ -c "$PORT" ] || die "$EX_USAGE" "$PORT is not a character device"
fi
if [ "$DRY_RUN" != 1 ]; then
    # Another device already sitting in DFU mode would be mistaken for ours.
    pre=""
    pre="$(spinel_quiet list || true)"
    dfu_lc="$(printf '%s' "$DFU_VIDPID" | tr 'A-F' 'a-f')"
    if [ "$SKIP_TOUCH" != 1 ] && printf '%s\n' "$pre" | grep -qi " $dfu_lc\$"; then
        die "$EX_USAGE" "a device with the bootloader id $DFU_VIDPID is already attached; unplug it first so the right one is flashed"
    fi
fi

# ------------------------------------------------------------------ step 1: record version, stop the agent
PRE_OTCTL="$(otctl_version)"
[ -z "$PRE_OTCTL" ] || info "ot-ctl rcp version (before): $PRE_OTCTL"
otbr_stop
PRE_VERSION=""
if [ "$SKIP_TOUCH" != 1 ]; then
    wait_version PRE_VERSION "$PORT" "$BAUD" "$FLOW" 6 || warn "dongle did not answer a Spinel version query before the update (continuing)"
    [ -z "$PRE_VERSION" ] || info "Spinel version (before): $PRE_VERSION"
fi

# ------------------------------------------------------------------ step 2: bootloader entry
FLASH_TTY="$DFU_PORT"
if [ "$SKIP_TOUCH" != 1 ]; then
    spinel_run touch --port "$PORT" --baud 1200 --hold-ms 150 || die "$EX_ENTRY" "1200-baud touch failed on $PORT"
fi
if [ -z "$FLASH_TTY" ]; then
    spinel FLASH_TTY find-tty --vid-pid "$DFU_VIDPID" --timeout "$TOUCH_WAIT" ||
        die "$EX_ENTRY" "no USB DFU device $DFU_VIDPID within ${TOUCH_WAIT}s. The firmware may lack the touch module, or the bootloader ignores magic 0xB1. Press the dongle's reset button (red LED pulsing) and re-run with --skip-touch."
    [ "$DRY_RUN" = 1 ] && FLASH_TTY="/dev/ttyACM<dfu>"
fi
info "bootloader serial port: $FLASH_TTY"

# ------------------------------------------------------------------ step 3: flash
if [ "$NRFUTIL_FLAVOUR" = new ]; then
    FLASH_CMD=("$NRFUTIL" nrf5sdk-tools dfu usb-serial -pkg "$IMAGE" -p "$FLASH_TTY" -b 115200)
else
    FLASH_CMD=("$NRFUTIL" dfu usb-serial -pkg "$IMAGE" -p "$FLASH_TTY" -b 115200)
fi
if ! run "${FLASH_CMD[@]}"; then
    err "nrfutil failed. The dongle stays in the bootloader (red LED pulsing): re-run with --skip-touch --dfu-port $FLASH_TTY to retry."
    exit "$EX_FLASH"
fi

# ------------------------------------------------------------------ step 4: verify
if [ "$VERIFY" != 1 ]; then
    warn "verification skipped (--no-verify)"
else
    APP_TTY="$PORT"
    if [ "$DRY_RUN" != 1 ]; then
        # Give the dongle time to leave the bootloader, then find the application port again.
        # The original path is preferred; if it vanished (ttyACM number changed) look it up by VID:PID.
        sleep 2
        end=$((SECONDS + APP_WAIT))
        while [ ! -c "$APP_TTY" ] && [ "$SECONDS" -lt "$end" ]; do sleep 1; done
        if [ ! -c "$APP_TTY" ]; then
            cnt="$(spinel_quiet list | grep -ci " $(printf '%s' "$APP_VIDPID" | tr 'A-F' 'a-f')\$" || true)"
            if [ "$cnt" = 1 ]; then
                APP_TTY="$(spinel_quiet find-tty --vid-pid "$APP_VIDPID" --timeout 5)" || APP_TTY=""
                warn "$PORT is gone, using $APP_TTY (the only $APP_VIDPID device). Use a /dev/serial/by-id path to avoid this."
            else
                APP_TTY=""
            fi
        fi
        [ -n "$APP_TTY" ] || die "$EX_VERIFY" "dongle did not come back as $PORT (or ambiguous: $cnt devices with $APP_VIDPID). Check lsusb; the flash itself reported success."
    fi
    POST_VERSION=""
    if ! wait_version POST_VERSION "$APP_TTY" "$BAUD" "$FLOW" "$APP_WAIT"; then
        die "$EX_VERIFY" "no Spinel answer from $APP_TTY after the update. nrfutil reported success, so the new image may be broken: use --rollback, or the reset button + --skip-touch with a known good package."
    fi
    info "Spinel version (after): $POST_VERSION"
    if [ "$DRY_RUN" = 1 ]; then
        info "(dry-run) would compare the version before and after"
    elif [ -n "$PRE_VERSION" ] && [ "$PRE_VERSION" = "$POST_VERSION" ]; then
        warn "version string unchanged ($PRE_VERSION). nrfutil succeeded, so this can be the same build or a build whose version string embeds no new timestamp."
    elif [ -n "$PRE_VERSION" ]; then
        info "version changed: OK"
    fi
fi

# ------------------------------------------------------------------ done
if [ "$ROLLBACK" != 1 ]; then remember_good dongle "$IMAGE" "$SIDECAR"; fi
otbr_start || true
if [ "$DRY_RUN" != 1 ]; then
    sleep 5
    POST_OTCTL="$(otctl_version)"
    [ -z "$POST_OTCTL" ] || info "ot-ctl rcp version (after): $POST_OTCTL"
fi
info "dongle update finished"
exit "$EX_OK"
