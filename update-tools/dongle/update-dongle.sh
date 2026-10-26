#!/usr/bin/env bash
# update-dongle.sh - update the RCP firmware of the Holyiot nRF52840 USB dongle from a
# Raspberry Pi: Spinel reset-to-bootloader -> Nordic USB DFU bootloader -> nrfutil -> wait for the radio.
#
# Verified on hardware (2026-10-26, manually, step by step): rcp_spinel.py reset-bootloader puts the
# dongle into the bootloader (1915:521f), and 'nrfutil device program --traits nordicDfu' flashes the
# -legacyusb DFU zip. The script as a whole has not been run end to end on hardware yet.
# Bootloader entry: --entry reset (default, any current build), --entry touch (only builds with the
# 1200-baud touch module, i.e. -dfutouch), or --skip-entry when the dongle is already in the bootloader.
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
VARIANT="legacyusb"
ENTRY="reset"
DFU_SERIAL=""
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
  --file ZIP          DFU package, e.g. rcp-holyiot-nrf52840-dongle-usb-legacyusb-dfu.zip
  --release TAG       download the package from the GitHub release TAG
                      (e.g. ncs-v3.4.1_thread-1.4_ot-0fe68ff)
  --rollback          flash the previous known good package kept by this script

Options
  --repo OWNER/REPO   GitHub repository for --release (default Horticulture-project/ot-rcp)
  --variant V         asset for --release: legacyusb (default; the build CI publishes), dfutouch or plain
  --entry E           how to enter the bootloader: reset (default; Spinel reset-to-bootloader, works
                      with every current build) or touch (1200-baud touch, only -dfutouch builds)
  --baud N            baud used to talk Spinel to the app (default 460800; USB CDC ignores the value, but it
                      must not be 1200)
  --flow              accepted for symmetry with the UART script; no effect on USB
  --skip-entry        the dongle is already in the bootloader (Spinel reset or reset button); alias --skip-touch
  --dfu-port PATH     use this tty for DFU instead of searching for the bootloader's VID:PID
  --app-vid-pid V:P   application USB id (default 1915:0000)
  --dfu-vid-pid V:P   bootloader USB id (default 1915:521f, assumed from Nordic's dongle: verify)
  --nrfutil PATH      nrfutil binary (default: nrfutil from PATH). Uses, in this order:
                      'nrfutil nrf5sdk-tools dfu usb-serial' (x86-64 only), 'nrfutil device program'
                      (64-bit ARM: install with 'nrfutil install device'), legacy 'nrfutil dfu usb-serial'
  --dfu-serial SN     serial number of the dongle in the bootloader, for 'nrfutil device' (default: the
                      only 'Open DFU Bootloader' in 'nrfutil device list')
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
        --skip-touch | --skip-entry) SKIP_TOUCH=1; shift ;;
        --entry) ENTRY="${2:?--entry needs a value}"; shift 2 ;;
        --dfu-serial) DFU_SERIAL="${2:?--dfu-serial needs a value}"; shift 2 ;;
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
case "$VARIANT" in legacyusb | dfutouch | plain) ;; *) die "$EX_USAGE" "--variant must be legacyusb, dfutouch or plain" ;; esac
case "$ENTRY" in reset | touch) ;; *) die "$EX_USAGE" "--entry must be reset or touch" ;; esac
case "$SPINEL_PREF" in auto | rust | python) ;; *) die "$EX_USAGE" "--spinel-tool must be auto, rust or python" ;; esac
case "$REPO" in */*) ;; *) die "$EX_USAGE" "--repo must look like OWNER/REPO" ;; esac
# The 1200-baud touch only works if the firmware RUNNING now contains the touch module.
if [ "$ENTRY" = touch ] && [ "$SKIP_TOUCH" != 1 ]; then
    warn "--entry touch needs the touch module in the firmware running now (-dfutouch builds); the default --entry reset works with every current build"
fi
if [ -n "$FILE" ]; then
    case "$(basename "$FILE")" in
        *-dfu.zip) ;;
        *) warn "$(basename "$FILE") does not look like a dongle DFU package (*-dfu.zip)" ;;
    esac
fi
if [ -n "$FILE" ] && [ "$DRY_RUN" != 1 ] && [ ! -f "$FILE" ]; then
    die "$EX_USAGE" "file not found: $FILE"
fi

setup_sudo
make_workdir
install_traps
[ "$DRY_RUN" = 1 ] && info "DRY RUN: nothing below is executed"

# Print the serial number of the only "Open DFU Bootloader" in 'nrfutil device list' output.
# Expected blocks (nrfutil device, 2026-10): "F8BE95E3118D" / "Product  Open DFU Bootloader" / "Ports ..." / "Traits ...".
dfu_serial_from_list() {
    printf '%s\n' "$1" | awk '
        /^[0-9A-Fa-f]+[[:space:]]*$/ { sn = $1; next }
        /^Product[[:space:]].*Open DFU Bootloader/ { if (sn != "") { print sn; n++ } }
        END { exit (n == 1 ? 0 : 1) }'
}

# ------------------------------------------------------------------ dependencies
find_spinel_tool "$SCRIPT_DIR"
NRFUTIL_FLAVOUR=""
# Flavour detection (see README, "nrfutil"):
#   new    - Rust nrfutil + 'nrf5sdk-tools' (wraps pc-nrfutil 6.1.7); NOT published for aarch64 Linux
#   device - Rust nrfutil + 'device' ('nrfutil device program --traits nordicDfu'); verified on a 64-bit Pi
#   legacy - Python nrfutil 6.1.x
if command -v "$NRFUTIL" >/dev/null 2>&1; then
    if "$NRFUTIL" nrf5sdk-tools dfu usb-serial --help >/dev/null 2>&1; then
        NRFUTIL_FLAVOUR=new
    elif "$NRFUTIL" device program --help >/dev/null 2>&1; then
        NRFUTIL_FLAVOUR=device
    elif "$NRFUTIL" dfu usb-serial --help >/dev/null 2>&1; then
        NRFUTIL_FLAVOUR=legacy
    fi
fi
if [ -z "$NRFUTIL_FLAVOUR" ] && [ "$DRY_RUN" = 1 ]; then
    NRFUTIL_FLAVOUR=device
    warn "(dry-run) no usable '$NRFUTIL' found, assuming 'nrfutil device'"
fi
if [ -z "$NRFUTIL_FLAVOUR" ]; then
    die "$EX_DEPS" "no usable nrfutil. Install nRF Util and run 'nrfutil install device' (64-bit ARM and x86-64) or 'nrfutil install nrf5sdk-tools' (x86-64 only); see README"
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
    case "$VARIANT" in
        legacyusb) ASSET="$ASSET_BASE-legacyusb-dfu.zip" ;;
        dfutouch) ASSET="$ASSET_BASE-dfutouch-dfu.zip" ;;
        *) ASSET="$ASSET_BASE-dfu.zip" ;;
    esac
    URL="https://github.com/$REPO/releases/download/$RELEASE/$ASSET"
    run mkdir -p "$WORKDIR/image"
    http_get "$URL" "$WORKDIR/image/$ASSET" || die "$EX_DEPS" "download failed: $URL"
    IMAGE="$WORKDIR/image/$ASSET"
    # CI publishes rcp-...-dfu.zip.sha256 next to the zip; it is verified when present.
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
    if [ "$ENTRY" = reset ]; then
        # Spinel CMD_RESET / SPINEL_RESET_BOOTLOADER: the firmware pulls the reset pin (P0.19) via
        # OPENTHREAD_PLATFORM_BOOTLOADER_MODE_GPIO. Verified on the Holyiot dongle (USB CDC ignores --baud).
        fl=()
        [ "$FLOW" = 1 ] && fl=(--flow)
        spinel_run reset-bootloader --port "$PORT" --baud "$BAUD" "${fl[@]}" ||
            die "$EX_ENTRY" "Spinel reset-to-bootloader failed on $PORT"
    else
        spinel_run touch --port "$PORT" --baud 1200 --hold-ms 150 || die "$EX_ENTRY" "1200-baud touch failed on $PORT"
    fi
fi
if [ -z "$FLASH_TTY" ]; then
    spinel FLASH_TTY find-tty --vid-pid "$DFU_VIDPID" --timeout "$TOUCH_WAIT" ||
        die "$EX_ENTRY" "no USB DFU device $DFU_VIDPID within ${TOUCH_WAIT}s. Press the dongle's reset button (red LED pulsing) and re-run with --skip-entry."
    [ "$DRY_RUN" = 1 ] && FLASH_TTY="/dev/ttyACM<dfu>"
fi
info "bootloader serial port: $FLASH_TTY"

# ------------------------------------------------------------------ step 3: flash
if [ "$NRFUTIL_FLAVOUR" = device ]; then
    if [ -z "$DFU_SERIAL" ] && [ "$DRY_RUN" != 1 ]; then
        DFU_SERIAL="$(dfu_serial_from_list "$("$NRFUTIL" device list 2>/dev/null)")" ||
            die "$EX_ENTRY" "could not pick exactly one 'Open DFU Bootloader' in 'nrfutil device list'; pass --dfu-serial"
    fi
    [ -n "$DFU_SERIAL" ] || DFU_SERIAL="<serial>"
    info "bootloader serial number: $DFU_SERIAL"
    FLASH_CMD=("$NRFUTIL" device program --serial-number "$DFU_SERIAL" --firmware "$IMAGE" --traits nordicDfu)
elif [ "$NRFUTIL_FLAVOUR" = new ]; then
    FLASH_CMD=("$NRFUTIL" nrf5sdk-tools dfu usb-serial -pkg "$IMAGE" -p "$FLASH_TTY" -b 115200)
else
    FLASH_CMD=("$NRFUTIL" dfu usb-serial -pkg "$IMAGE" -p "$FLASH_TTY" -b 115200)
fi
if ! run "${FLASH_CMD[@]}"; then
    err "nrfutil failed. The dongle stays in the bootloader (red LED pulsing): re-run with --skip-entry to retry."
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
        die "$EX_VERIFY" "no Spinel answer from $APP_TTY after the update. nrfutil reported success, so the new image may be broken: use --rollback, or the reset button + --skip-entry with a known good package."
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
