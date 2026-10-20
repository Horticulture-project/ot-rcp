# update-tools: RCP firmware update from a Raspberry Pi

Host-side tooling that updates the OpenThread RCP firmware of three boards over the cable that already
connects them to the Raspberry Pi (Raspberry Pi OS, systemd, `otbr-agent`):

| Board | Folder | Route |
| :--- | :--- | :--- |
| Holyiot nRF52840 dongle (USB) | [`dongle/`](dongle) | 1200-baud touch, then USB DFU with `nrfutil` |
| Ebyte E73 (nRF52840, UART) | [`uart-modules/`](uart-modules) `--board e73` | Spinel reset-to-bootloader, then MCUboot serial recovery with `mcumgr-client` |
| Ezurio nRF54L15 (UART) | [`uart-modules/`](uart-modules) `--board nrf54l15` | same |

The firmware lives in another repository (`docss/bootloader_and_update.md` there has the design and the host
contracts). This directory is meant to be moved into its own repository. Each tool folder is self-contained:
copy `dongle/` or `uart-modules/` alone and it works (the two copies of `rcp-common.sh` and `rcp_spinel.py` are
identical on purpose, CI checks that).

> **STATUS: nothing here has been run against hardware.** The Rust code is unit tested, the shell scripts are
> ShellCheck clean and dry-run / mock tested, but no dongle, E73 or Ezurio was available. Every procedure below is
> marked with what is expected; treat the first run on a board as a bench test with a recovery path (SWD probe, or the
> dongle's reset button) at hand.

## Contents of each folder

```text
dongle/                          uart-modules/
  update-dongle.sh                 update-uart-module.sh
  rcp-common.sh                    rcp-common.sh        (identical copy)
  rcp_spinel.py                    rcp_spinel.py        (identical copy)
  [rcp-update]  optional binary    [rcp-update]  optional binary
                                   [tools/mcumgr-client]  downloaded by --install-tools
rcp-update/                      Rust source of the serial helper (build once per platform)
.github/workflows/ci.yml         CI (kept here so it moves with the directory)
```

The scripts need a serial helper for the protocol parts that are painful in shell (1200-baud touch, the Spinel HDLC
frame, the Spinel version query). Either the static `rcp-update` binary (put it next to the script, or
`--rcp-update PATH`, or in `PATH`) **or** `python3` with the bundled `rcp_spinel.py` (standard library only, Linux).
`--spinel-tool rust|python|auto` forces one; both produce byte-identical frames (CI compares them).

## Install on Raspberry Pi OS

```bash
sudo apt update
sudo apt install -y curl unzip python3 libdbus-1-3       # libdbus-1-3: mcumgr-client links it (BLE support)
sudo usermod -aG dialout "$USER"                          # serial ports without root (log out and in again)
```

The scripts call `systemctl stop/start otbr-agent` (through `sudo` when not root). Running the script as root
(`sudo ./update-dongle.sh ...`) is the simplest way.

**64-bit (arm64, Pi 3/4/5/Zero 2 W running 64-bit Raspberry Pi OS)**: everything below is available.
**32-bit / armv7 / armv6**: `mcumgr-client` v0.1.0 ships only linux x86-64 and aarch64 binaries, the new `nrfutil`
ships only aarch64 and x86-64 Linux builds (checked 2026-10-21: the armv7 download URL returns 404), so the UART and
dongle routes are not available out of the box. The scripts stop with exit 6 and say so. Options: install 64-bit
Raspberry Pi OS (a 32-bit userland on a 64-bit kernel also reports `aarch64` in `uname -m`; the script checks
`getconf LONG_BIT`), build `mcumgr-client` from source (`cargo install --git
https://github.com/vouch-opensource/mcumgr-client --tag v0.1.0`, then `--mcumgr PATH`), or run the update from another
64-bit machine that has the cable. The `rcp-update` helper itself can be built for `armv7-unknown-linux-musleabihf`
(`cross build --release --target armv7-unknown-linux-musleabihf`, untested), and the python fallback works anywhere.

### rcp-update (serial helper)

Download `rcp-update-linux-aarch64` (or `-x86_64`) and its `.sha256` from the CI artifacts / release of this repository
(`sha256sum -c`), `chmod +x`, rename to `rcp-update` and place it next to the script. Or build it (`cargo` needed):

```bash
cd rcp-update && cargo build --release          # target/release/rcp-update
# fully static: rustup target add aarch64-unknown-linux-musl && cross build --release --target aarch64-unknown-linux-musl
```

`serialport` is used with `default-features = false`, so there is **no libudev dependency**; USB ports are found by
this tool itself through `/sys/class/tty`. No udev development packages are needed for a musl build.

### mcumgr-client (UART modules)

Pinned to **v0.1.0**. `./update-uart-module.sh --install-tools-only` downloads
`mcumgr-client-linux-aarch64.zip` or `mcumgr-client-linux-x86.zip` (the upstream name for the x86-64 build) from the
GitHub release into `uart-modules/tools/`, checks it against the sha256 **pinned inside the script** and against the
published `.sha256sum`, and unpacks it. Pinned values (recomputed 2026-10-21):

```text
7d1fd5d57415d78028c0bde6162372f449c608643a8881f31e7093e5d44a0722  mcumgr-client-linux-aarch64.zip
3ac8c37343f29f3dc7aed1674440c26e9e0d977a331d03ba88dea619b9cde650  mcumgr-client-linux-x86.zip
```

The binary is dynamically linked (glibc >= 2.34, `libdbus-1.so.3`; checked in the ELF), so Raspberry Pi OS Bookworm
(glibc 2.36) or newer is required.

### nrfutil (dongle)

Use the **new nrfutil with the `nrf5sdk-tools` command** (version 8.x, `nrf5sdk-tools` 1.1.0). It bundles the legacy
`pc-nrfutil` 6.1.7 engine, so it accepts the same options and the same zip files. Install:

```bash
# aarch64 (Pi, 64-bit OS):
curl -fL -o nrfutil https://files.nordicsemi.com/artifactory/swtools/external/nrfutil/executables/aarch64-unknown-linux-gnu/nrfutil
# x86-64: .../x86_64-unknown-linux-gnu/nrfutil
chmod +x nrfutil && sudo mv nrfutil /usr/local/bin/
nrfutil install nrf5sdk-tools
nrfutil nrf5sdk-tools dfu usb-serial --help     # must print the usb-serial options
```

Nordic publishes no checksum next to that URL, so the script does not auto-install nrfutil (unlike mcumgr-client).
The scripts also accept the **legacy** Python `nrfutil` 6.1.x (`nrfutil dfu usb-serial ...`) if it is installed, but
the README's `pip install nrfutil` no longer works on current Raspberry Pi OS: PyPI has only the 6.1.7 source
distribution, which declares `requires-python >=3.7,<3.11`, while Bookworm ships Python 3.11 and Trixie 3.13 (and
pip refuses system-wide installs there, PEP 668).

## Which release asset is which

Release tag: `ncs-<NCS version>_thread-<version>_ot-<sha>`, e.g. `ncs-v3.4.1_thread-1.4_ot-0fe68ff`. Every board has a
**plain** build (SWD only) and an **update-capable** variant. Only the update-capable files work with these scripts.

| Board | Plain (not usable here) | Update-capable (what the scripts use) |
| :--- | :--- | :--- |
| Dongle | `rcp-holyiot-nrf52840-dongle-usb[.hex/.bin/-dfu.zip]` | `rcp-holyiot-nrf52840-dongle-usb-dfutouch-dfu.zip` (contains the 1200-baud touch module) |
| E73 | `rcp-ebyte-e73-nrf52840-<baud>baud-<flow\|noflow>.hex/.bin` | `rcp-ebyte-e73-nrf52840-<baud>baud-<flow\|noflow>-mcuboot-update.bin` + `.sha256` (the `...-mcuboot.hex` merged hex is for the **one-time SWD flash**) |
| Ezurio | `rcp-ezurio-nrf54l15-<baud>baud-<flow\|noflow>.hex/.bin` | `rcp-ezurio-nrf54l15-<baud>baud-<flow\|noflow>-mcuboot-update.bin` + `.sha256` |

While no signing secret exists, MCUboot builds use MCUboot's **public development key** and their file names contain
`-DEVKEY`, e.g. `rcp-ebyte-e73-nrf52840-115200baud-noflow-mcuboot-DEVKEY-update.bin`. The scripts refuse those unless
`--allow-devkey` is given (see "Safety"). `--release TAG` looks for the production name first and then for the DEVKEY
name.

What the scripts refuse, with exit code 2, before touching anything: a plain `.hex`/`.bin` for a UART module, a file
without the MCUboot image header (`3D B8 F3 96`, magic `0x96f3b83d`), an image larger than the slot, `--variant plain`,
a plain dongle zip for the touch route (it has no touch module; enter DFU with the reset button and use `--skip-touch`).

## Finding the port and stable names

```bash
./rcp-update list                      # USB ttys with VID:PID, read from /sys/class/tty
ls -l /dev/serial/by-id/               # stable names that include the USB serial number
ps -o args= -C otbr-agent              # the URL shows the port and uart-baudrate/uart-flow-control the agent uses
```

* **Dongle**: application mode is `1915:0000` ("Thread Co-Processor"), bootloader mode is assumed to be `1915:521f`
  (Nordic's open DFU bootloader; **verify on the Holyiot unit** with `lsusb` after pressing its reset button). The tty
  number changes between the two modes, so give `--port` as a `/dev/serial/by-id/...` or a udev symlink.
* **E73 / Ezurio** wired to the Pi header: `/dev/ttyAMA0` (alias `/dev/serial0`). Enable the UART, disable the
  console on it, and for the 460800 variants enable RTS/CTS (`dtoverlay=uart0,ctsrts`, see the firmware README).

udev rules for stable names (`/etc/udev/rules.d/99-rcp.rules`, then `sudo udevadm control --reload && sudo udevadm trigger`):

```text
# Holyiot dongle in application mode; replace the serial with yours (udevadm info -a /dev/ttyACM0 | grep serial)
SUBSYSTEM=="tty", ATTRS{idVendor}=="1915", ATTRS{idProduct}=="0000", ATTRS{serial}=="XXXXXXXXXXXX", SYMLINK+="rcp-dongle", GROUP="dialout", MODE="0660", ENV{ID_MM_DEVICE_IGNORE}="1"
# The same dongle in bootloader mode (only needed if you want a name for it)
SUBSYSTEM=="tty", ATTRS{idVendor}=="1915", ATTRS{idProduct}=="521f", GROUP="dialout", MODE="0660", ENV{ID_MM_DEVICE_IGNORE}="1"
# Pi header UART as a fixed name
KERNEL=="ttyAMA0", SYMLINK+="rcp-uart"
```

`ID_MM_DEVICE_IGNORE` keeps ModemManager (present on desktop images) from probing the port. Use `--port /dev/rcp-dongle`.

## Update, step by step

All commands accept `--dry-run`: it prints every command and touches nothing (no download, no service stop, no
device access). Run it first. Examples use the release `ncs-v3.4.1_thread-1.4_ot-0fe68ff`; use `--file` instead of
`--release` for a local file.

### Dongle (1200-baud touch + USB DFU)

Prerequisite: the dongle already runs the `-dfutouch` firmware (first install with the reset button, `nrfutil` and the
`-dfutouch-dfu.zip`, or nRF Connect Programmer).

```bash
cd dongle
sudo ./update-dongle.sh --dry-run --port /dev/rcp-dongle --release ncs-v3.4.1_thread-1.4_ot-0fe68ff
sudo ./update-dongle.sh          --port /dev/rcp-dongle --release ncs-v3.4.1_thread-1.4_ot-0fe68ff
```

What happens: record `ot-ctl rcp version` and stop `otbr-agent` (only if active) -> Spinel version query (before) ->
open the port at exactly 1200 baud 8N1, hold 150 ms, drop DTR, close -> wait up to 10 s for `1915:521f` ->
`nrfutil nrf5sdk-tools dfu usb-serial -pkg <zip> -p <tty> -b 115200` -> wait for the app port and a Spinel answer ->
compare versions -> restart `otbr-agent` (always, via `trap`, only if the script stopped it).

Expected (unverified): `touch done on ...`, `bootloader serial port: /dev/ttyACMn`, the nrfutil progress bar and
`Device programmed.`, `Spinel version (after): OPENTHREAD/...`, `version changed: OK`, exit 0. Manual check of the
first step on the bench, before the script: `python3 -c "import serial; serial.Serial('/dev/ttyACM0',1200).close()"`,
then `lsusb` should show `1915:521f` within about a second (LED pulsing red).

Dongle options: `--skip-touch [--dfu-port /dev/ttyACMn]` (dongle already in DFU via the reset button, also the retry path
after a failed flash: the bootloader stays up), `--dfu-vid-pid`, `--app-vid-pid`.

### Ebyte E73 and Ezurio nRF54L15 (Spinel reset + MCUboot serial recovery)

Prerequisite: the module was flashed **once over SWD** with the merged `...-mcuboot.hex` (full chip erase; firmware
README). `--baud/--flow` must match the variant the module runs (they pick the asset and are used to reach the app).

```bash
cd uart-modules
sudo ./update-uart-module.sh --install-tools-only           # once: downloads and verifies mcumgr-client v0.1.0
sudo ./update-uart-module.sh --dry-run --board e73 --port /dev/ttyAMA0 --baud 115200 --release ncs-v3.4.1_thread-1.4_ot-0fe68ff
sudo ./update-uart-module.sh --board e73      --port /dev/ttyAMA0 --baud 115200            --release ncs-v3.4.1_thread-1.4_ot-0fe68ff
sudo ./update-uart-module.sh --board nrf54l15 --port /dev/ttyAMA0 --baud 460800 --flow     --release ncs-v3.4.1_thread-1.4_ot-0fe68ff
```

Sequence (all commands are printed): version before -> stop `otbr-agent` -> if MCUboot already answers, skip the reset,
else send `7E 81 01 03 BF BB 7E` at `--baud/--flow` -> `mcumgr-client -s -d PORT -b 115200 -t 2 echo ping` once per
second up to 20 s -> `list` -> `upload <image> --slot 2` (`-t 10 -u 500 --nb-retry 8`) -> `list` (parse slot 1 hash) ->
`test <hash>` -> `list` (slot 1 must be `"pending": true`) -> `reset` -> wait for Spinel -> compare versions -> restart
`otbr-agent`. The recovery link is **always 115200 8N1, no flow control**, whatever the application uses.

Expected (unverified): `Echo response: ping`; a `list` with a slot 0 entry, then also slot 1 after the upload;
upload progress bar to 100 % in roughly 20-40 s; `Spinel version (after): ...`, `version changed: OK`, exit 0.
Extra options: `--skip-reset` (module already in recovery), `--deep-verify` (re-enter recovery and check that slot 0
holds the uploaded hash; one more reboot), `--allow-same-version`, `--allow-devkey`, `--recovery-baud`.

### Rollback

There is **no automatic revert and no confirm step**: the RCP has no SMP server, MCUboot runs in overwrite-only mode,
so a new image that boots but misbehaves stays. Rollback means uploading the previous signed `-update.bin` again:

```bash
sudo ./update-uart-module.sh --board e73 --port /dev/ttyAMA0 --baud 115200 --file old/rcp-...-mcuboot-update.bin
sudo ./update-uart-module.sh --board e73 --port /dev/ttyAMA0 --baud 115200 --rollback    # the copy the script kept
```

After every *verified* update the script stores the image in `~/.local/state/rcp-update/<board>/current` (previous one
moves to `previous/`; override with `RCP_STATE_DIR`). `--rollback` flashes `previous`. For the dongle `--rollback` flashes
the previous DFU zip the same way. If the application no longer answers Spinel, the reset frame cannot reach it: that
case needs a recovery entry that is not built (see the firmware gap analysis) and SWD.

## Exit codes

| Code | Meaning |
| :--- | :--- |
| 0 | success (radio answered after the update) |
| 2 | usage error, or a refused image/variant (plain build, DEVKEY without `--allow-devkey`, no MCUboot header, too large) |
| 3 | bootloader entry failed (no DFU device after the touch / no SMP answer after the Spinel reset / could not stop the agent) |
| 4 | upload or flash failed (running image untouched for UART modules; dongle stays in the bootloader) |
| 5 | verification failed (no Spinel answer, version unchanged, deep-verify mismatch) |
| 6 | missing dependency, unsupported architecture, download or checksum failure |

## Troubleshooting

| Symptom | Likely cause | Action |
| :--- | :--- | :--- |
| `cannot open ... busy` | `otbr-agent`, `ot-ctl`, ModemManager or another tool holds the port (ports are opened exclusively) | `sudo systemctl stop otbr-agent`, `fuser -v /dev/ttyAMA0`, `--no-service` only if you stopped it yourself |
| `permission denied` | not in `dialout` | `sudo usermod -aG dialout $USER`, re-login, or use `sudo` |
| Dongle: no `1915:521f` after the touch (exit 3) | firmware is not the `-dfutouch` build, bootloader ignores magic `0xB1` (not Nordic's bootloader), a different VID:PID | reset button, `lsusb`, `--skip-touch`; adjust `--dfu-vid-pid` if the bootloader id differs |
| Dongle reboots into the app again after the touch | bootloader ignored the magic (no loop: baud returns to 115200) | as above |
| `nrfutil` fails mid-way | cable/hub, bootloader timeout | dongle stays in DFU: `--skip-touch --dfu-port /dev/ttyACMn` |
| UART: reset frame written but no `Echo response` (exit 3) | app has no bootloader mode (not the `-mcuboot` build), wrong `--baud/--flow`, retention flag lost, port held by another process | check variant and `ot-ctl diag rcpcaps spinel`; `--skip-reset` after a manual entry; SWD as last resort |
| Echo OK, upload `wrong offset` / `wrong checksum` / timeouts | dropped bytes, `-u` too small | retry the whole script (restart at offset 0 is supported); long cables |
| Upload fails at once with an SMP `rc` | wrong `--slot`, image larger than slot, no direct upload build | the script always passes `--slot 2`; check `list` |
| After the reset the old version still runs / module answers SMP | MCUboot rejected the image (wrong key, dev-key image on a production module, unsigned) | the script says so; rebuild with the matching key |
| After the reset nothing answers on Spinel (exit 5) | broken image, wrong UART variant, MCUboot waiting without a valid image | the script probes SMP; if MCUboot answers, upload a known good image (`--rollback`) |
| Version unchanged (exit 5) | update not applied, or a build whose version string embeds no new timestamp | `--deep-verify` checks the hash; `--allow-same-version` to accept |
| Exit 6 `unsupported architecture` | armv6/armv7 or 32-bit userland | see "Install" |

Note on the version check: the RCP version string is `otGetVersionString()` (OpenThread version, platform, compile
date/time of that file, `ncp_base.cpp`: `NCP_VERSION` returns it). It does not contain the MCUboot image version
(`1.0.0+<run>`). If CI ever reuses a prebuilt OpenThread library the string can stay identical between builds; then
use `--deep-verify` (compares image hashes).

## Safety notes

* **1200 baud on the dongle's port reboots it into the bootloader.** Never open that port at 1200 from any other
  program, and never configure `otbr-agent` with `uart-baudrate=1200`. The scripts refuse `--baud 1200`.
* **UART modules recover at a fixed 115200 8N1, no flow control**, independent of the application (the firmware
  build fixes it; `--recovery-baud` exists only for custom builds).
* **Development-key builds (`-DEVKEY`, CI artifacts named `devkey-rcp-*`) must not be shipped.** MCUboot's public
  development key is in every NCS tree, anyone can sign an image for such a module. Use them on the bench only; the
  scripts require `--allow-devkey` and warn.
* No device is ever selected automatically: `--port` is mandatory, the DFU device is matched by VID:PID and the script
  refuses to continue if another device with the bootloader id is already attached.
* `otbr-agent` is restarted on every exit path (also on failure, Ctrl-C, SIGTERM) but only if the script stopped it.
* Downloads go to a private temporary directory, are sha256 checked (`.sha256` assets; pinned hashes for
  mcumgr-client) and the directory is removed on exit. The dongle zip has no published checksum yet (warning).
* Upload goes to the secondary slot, the running image stays intact until MCUboot has validated the new one.

## Verified vs. unverified

Verified here (2026-10-21, Windows host, no hardware): `cargo test` (19 tests: FCS table equality with OpenThread's
`hdlc.cpp`, X-25 check value, escaping, Spinel frames, SMP echo against an independent Python reference), `cargo
clippy -D warnings`, `cargo clippy --target x86_64-/aarch64-unknown-linux-musl` (compiles for Linux, no libudev),
ShellCheck 0.11.0 on all scripts, `--dry-run` of every board and variant, refusal paths, a mock end-to-end run of the
UART script against fake `mcumgr-client`/helper binaries (success path, upload failure -> service restarted),
the real download + double sha256 check + unzip of mcumgr-client v0.1.0, `nrfutil nrf5sdk-tools` help text and
version (Windows build of nrfutil 8.2.1).

Not verified: anything that needs a device or Linux serial semantics. In particular: the 1200-baud touch on the real
dongle (and that its bootloader is `1915:521f` and honours `0xB1`), nrfutil flashing the real zip, the Spinel reset
frame being accepted by the RCP, MCUboot answering SMP echo/list/upload at 115200, the overwrite-only copy, the
`rcp-update` binary on Linux (only compiled, not run), the Python fallback on Linux (only the frame/decoder logic was
run), the CI workflow (never executed), and `ot-ctl rcp version` output handling.

## Manual test plan (per board)

1. `./rcp-update frame reset-bootloader` prints `7E 81 01 03 BF BB 7E`; `./rcp-update frame version` prints `7E 81 02 02 5E 80 7E`.
2. Stop the agent, `./rcp-update version --port PORT --baud B [--flow]`: prints `OPENTHREAD/...; ...`.
3. UART: `./rcp-update reset-bootloader --port PORT --baud B [--flow]`, then `./rcp-update probe --port PORT --wait 20`
   prints `Echo response: ping`; `tools/mcumgr-client -d PORT list` shows slot 0.
4. Dongle: touch (`./rcp-update touch --port PORT`), `./rcp-update find-tty --vid-pid 1915:521f` prints a tty.
5. Run the full script with `--dry-run`, then for real with a second CI build; check `version changed: OK`.
6. Negative tests: image signed with another key (old app must keep running, script exit 5 with the SMP hint), unplug during
   upload (module must still answer echo after re-entering recovery), truncated file, `kill` the script mid-run
   (`otbr-agent` must come back).
