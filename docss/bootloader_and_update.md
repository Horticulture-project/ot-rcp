# Bootloader and firmware update options

How to update the RCP firmware without an SWD probe. The RCP is the Thread radio of an OpenThread Border Router, so
its firmware can only be updated over the host link (USB CDC or UART) and never over the Thread mesh.

> Written from knowledge of NCS and Zephyr plus the web research summarised under "Research findings"; nothing here has
> been verified on hardware or against NCS v3.4.1 builds. Items marked **(verify)** must be checked before relying on them.

## Targets

| Module | SoC | Board target | Host link | Bootloader today |
| :--- | :--- | :--- | :--- | :--- |
| Holyiot dongle | nRF52840 | `nrf52840dongle/nrf52840` | USB CDC ACM | Pre-flashed, most likely Nordic's USB DFU bootloader (see findings) |
| Ebyte E73 | nRF52840 | `nrf52840dk/nrf52840` | UART (P1.11/P1.10, RTS P1.08, CTS P1.07) | None |
| Ezurio (generic nRF54L15) | nRF54L15 | `nrf54l15dk/nrf54l15/cpuapp` | UART20 (P2.02/P2.00, RTS P2.01, CTS P2.03) | None |

## Option 1: 1200-baud touch (dongle only)

- Firmware detects the host opening and closing the CDC port at 1200 baud (line-coding / baud-rate callback on the CDC ACM
  instance).
- On a match it sets the bootloader's magic value (Nordic open bootloader: `GPREGRET = 0xB1`) and calls `sys_reboot()`.
- Stock Zephyr CDC ACM does not do this, so it needs a small patch kept in this repository.
- The Holyiot bootloader is most likely Nordic's USB DFU bootloader, where `GPREGRET = 0xB1` (or `0xB0` on some variants)
  is the community-documented entry value. Confirm on the actual unit **(verify)**; see the findings section.
- Host side: the trick already documented in the README.

## Option 2: Reset to bootloader over Spinel (dongle only, recommended for the dongle)

- The sample's `boards/nrf52840dongle_nrf52840.conf` already sets `CONFIG_OPENTHREAD_PLATFORM_BOOTLOADER_MODE_GPIO=y`, so
  the RCP already implements `otPlatResetToBootloader`.
- The host sends the Spinel reset-to-bootloader command over the existing serial link. `otbr-agent` may not expose this
  **(verify)**, so a small host tool (for example based on `spinel-cli` or a Python Spinel client) is likely needed.
- Check that the pin driven in GPIO mode really triggers the Holyiot bootloader. The pin-reset trigger is only wired by
  default on Nordic's own dongle, so on the Holyiot it may do nothing. Fall back to the GPREGRET write from option 1
  (retention mode is the closest NCS-native equivalent **(verify)**).
- Then flash with `nrfutil` using `dfu_application.zip` as documented in the README.

## Option 3: MCUboot with serial recovery (E73 and nRF54L15, optionally the dongle)

The real "update over the existing cable" option for bare modules.

- Sysbuild config: `SB_CONFIG_BOOTLOADER_MCUBOOT=y`, signing key, `CONFIG_MCUBOOT_SERIAL` for UART recovery.
- Entering recovery: a pin held at boot, or a retained-memory flag set by the app after a Spinel "bootloader" reset.
- One-time SWD flash is required to install MCUboot.
- Partition and slot layout per SoC (nRF54L15 uses RRAM, so sizes differ).
- Host tool: `mcumgr` or an equivalent SMP client uploads the signed `app_update.bin`. `otbr-agent` must be stopped during
  the update.
- CI must publish the signed update image (not only the raw `.hex`) and keep the signing key in a GitHub secret.
- Not recommended for the dongle: it would replace the Holyiot bootloader and shrink the application's flash.

## Option 4: Thread OTA

Not applicable to an RCP (see above).

## Recommendation

- Dongle: option 2, with the entry mechanism decided by the bootloader experiment (GPREGRET is the leading candidate);
  option 1 as fallback.
- UART modules: option 3 if field updates are needed, otherwise SWD as in the README.
- Host SMP tool: `mcumgr-client` (Rust, aarch64 release binary), Go `mcumgr` as fallback.
- Open items before implementation: identify the dongle bootloader (see experiment), test serial recovery with the chosen
  SMP client, check static or cross-built binaries for armv7 and aarch64.

## Rust alternatives to mcumgr

`mcumgr` is Go. Rust implementations of the same SMP protocol exist (maturity checked in the findings section below):

| Crate | Notes |
| :--- | :--- |
| `mcumgr-client` (GitHub, vouch-opensource) | Best fit, see the quality check below |
| `mcumgr-toolkit` (library) and `mcumgrctl` (CLI) | Active, library plus CLI |
| `mcumgr-smp` | Protocol library only |

Porting from scratch is realistic: SMP is a small protocol (CBOR payloads in an 8-byte header, serial framing with
base64 and CRC16). The minimum for this project is image list, image upload (chunked) with hash check, image confirm or
test, and reset. Expect a few days for a robust tool, mostly spent on serial framing, timeouts, retries and large
uploads. A Rust tool would also simplify shipping one static binary to the Raspberry Pi (including aarch64 builds in CI).
Python `smpmgr` is a quicker alternative if Rust is not a requirement.

## Research findings (2026-10-20)

### Holyiot dongle bootloader

- No official Holyiot page or schematic with bootloader details was found (the vendor manual page returned HTTP 403). The
  Holyiot-21017 third-party manual describes updating via nRF Connect for Desktop (Programmer) over USB DFU, which is the
  Nordic DFU flow, not UF2 or a drive-style bootloader.
- The README/CI flow already assumes this (`nrfutil` serial DFU, MBR at 0x0, app at 0x1000), and a Nordic-style
  bootloader is the only plausible fit for "Programmer app + HEX". Treat it as **likely, not confirmed**.
- On Nordic's own PCA10059 dongle: factory USB DFU bootloader (nRF5 SDK open bootloader family), entered by the reset
  button; SW1 is P1.06 in the MCUboot config discussed on DevZone. A software entry is described two ways, both from
  community replies and not official documentation:
  1. Write `0xB1` to `GPREGRET` (`nrf_power_gpregret_set(NRF_POWER, 0, 0xB1)`) then warm reset; `0xB0` is mentioned for
     some variants.
  2. Nordic's DFU trigger library (nRF5 SDK 17.0.2): the app pulls a pin wired to reset, and the bootloader treats a pin
     reset as "enter DFU". This is only wired by default on PCA10059.
- Caveats: the bootloader can only be replaced over SWD, and a mismatched signing key can brick DFU entry. One report says
  the open bootloader jumped straight to the app instead of waiting in DFU, so behaviour varies by build.
- Implication for option 1 and 2: the GPREGRET route is the best candidate, but it must be tested on the actual Holyiot
  unit. Do not assume the GPIO mode from the NCS sample matches this board's wiring.
- Fast experiment to settle it (needs only the dongle and a PC): enter DFU with the reset button, then run
  `nrfutil device list` / read the USB descriptor and the flash at 0xE0000 (bootloader start on Nordic's dongle) with an
  SWD probe if available. Record the result here.

Sources: [Nordic DevZone: automating bootloader entry on the nRF52840 dongle](https://devzone.nordicsemi.com/f/nordic-q-a/124541/how-to-automate-the-entrance-in-bootloader-mode-on-nrf52840-usb-dongle/551051),
[Nordic DevZone: cannot enter bootloader mode](https://devzone.nordicsemi.com/f/nordic-q-a/91312/cannot-enter-bootloader-mode-on-nrf52840-dongle-anymore/384362),
[Nordic Developer Academy: flash instructions for the nRF52840 Dongle](https://academy.nordicsemi.com/flash-instructions-for-nrf52840-dongle/),
[Holyiot-21017 manual (manuals.plus)](https://manuals.plus/ae/3256804486864252).

### Rust SMP tools: quality check

| Tool | Version / activity | Commands and transports | Binaries | Verdict |
| :--- | :--- | :--- | :--- | :--- |
| [`mcumgr-client`](https://github.com/vouch-opensource/mcumgr-client) (not on crates.io) | v0.1.0 (2026-09-21), pushed 2026-10-10, 73 stars, Apache-2.0 | `list`, `upload`, `test` (with confirm), `erase`, `reset`, plus echo, shell, fs, stats, settings, custom groups. Serial (default), UDP, BLE | Release zips for linux x86-64 and **aarch64** (with sha256), macOS, Windows | **Best fit.** Covers exactly what we need, ships a Pi-ready binary. Needs a Zephyr CDC ACM patch note for some MCUboot builds. Static linking not documented |
| [`mcumgr-toolkit` / `mcumgrctl`](https://github.com/Finomnis/mcumgr-toolkit) | v0.20.0 (2026-10-18), very active, 14 stars, MIT/Apache-2.0 | Library + CLI + Python bindings. `firmware update` (detect MCUboot, upload, activate, reboot), os info, echo. Serial, USB serial, BLE (feature) | Release binaries for Linux, macOS, Windows (architecture unverified, probably x86-64 only); otherwise `cargo install` | Clean API and fast-moving, but author says it was written mainly for personal use. Serial-recovery use not documented |
| [`mcumgr-smp`](https://github.com/Gessler-GmbH/smp-rs) | v0.8.0, last push 2026-03, 16 stars | Protocol library only, no CLI | none | Building block, not a tool |
| Go `mcumgr` (reference) | Apache Mynewt, 84 stars, pushed 2026-05 | Full, but Go | Go builds easily to static aarch64 | Fallback |

Static binary notes (unverified):
- The Linux serial crates normally pull in `libudev` through `serialport`. A fully static musl build needs the udev
  feature disabled (the port is then opened by path, which is fine for `/dev/ttyAMA0` and `/dev/ttyACM0`) and BLE disabled
  (D-Bus). Cross-build for aarch64 and armv7 in CI with `cross` or `cargo zigbuild`.
- Neither tool documents serial *recovery* mode (MCUboot's `CONFIG_MCUBOOT_SERIAL` uses the same SMP framing, so it should
  work, but test it before committing). Both tools are young, so pin an exact version and verify the sha256.

Recommendation: start with `mcumgr-client` (aarch64 binary available now), keep Go `mcumgr` as the documented fallback,
and only write our own tool if serial recovery or static builds prove a problem.

---

# Agent prompts

Copy each prompt into a separate agent session. Each assumes the agent has this repository checked out.

## Prompt A: Embedded developer, option 2 (dongle)

```text
You are a senior embedded firmware engineer with deep Zephyr RTOS, nRF Connect SDK (NCS v3.4.1), OpenThread and Nordic
bootloader experience. Work in the repository at the current directory (the OpenThread RCP firmware project).

GOAL
Make the Holyiot nRF52840 USB dongle (board target `nrf52840dongle/nrf52840`) update-able without touching the
hardware: the Raspberry Pi host sends a Spinel "reset to bootloader" command over the existing USB CDC ACM link, the
dongle reboots into its pre-flashed USB DFU bootloader, and the host flashes `dfu_application.zip`.

CONTEXT YOU MUST READ FIRST
- .github/workflows/build-rcp.yml (CI builds the NCS sample `nrf/samples/openthread/coprocessor` with sysbuild; the
  dongle uses the sample's `boards/nrf52840dongle_nrf52840.conf`, which already sets
  CONFIG_OPENTHREAD_PLATFORM_BOOTLOADER_MODE_GPIO=y and USB_DEVICE_STACK_NEXT).
- README.md and bootloader_and_update.md (options and open questions).
- The NCS sources for v3.4.1: how otPlatResetToBootloader is implemented for GPIO, retention and DFU modes.

TASKS
1. Identify which bootloader the Holyiot dongle ships with and how it is entered (magic value in GPREGRET, a GPIO, a
   button). Prior research (see "Research findings" in bootloader_and_update.md) says it is most likely Nordic's USB DFU
   bootloader, entered by reset button, by `GPREGRET = 0xB1` (`0xB0` on some variants) plus warm reset, or by a pin reset
   that is only wired by default on Nordic's own dongle. Treat that as a hypothesis: confirm or refute it with evidence
   (bootloader start at 0xE0000, USB descriptors, `nrfutil` behaviour). If it cannot be determined from sources, say so
   and list the exact experiment to run on the hardware.
2. Determine which bootloader-mode option (GPIO, retention, or a custom GPREGRET write; GPREGRET is the leading
   candidate, and the GPIO mode already enabled by the NCS sample may not match this board) actually enters that bootloader,
   and implement it with the smallest possible change. Keep the NCS sample unmodified; add overrides in this repo
   (Kconfig fragments, devicetree overlays, or a small out-of-tree source added via the build, as appropriate).
3. Make the workflow apply the change for the dongle only, without affecting the E73 and nRF54L15 builds.
4. Provide the host-side trigger: a minimal documented way to send the Spinel reset-to-bootloader command (check whether
   otbr-agent or ot-ctl already supports it; otherwise a small Python or Rust tool). Do not write the update shell
   scripts; another agent owns those. Specify the CLI contract (arguments, exit codes) that the scripts can call.
5. Keep the DFU zip generation in CI working and confirm the flash layout (MBR at 0x0, application at 0x1000) matches
   the bootloader.

CONSTRAINTS
- Do not break existing CI. Do not change the other boards' configuration.
- Do not invent Kconfig symbols or APIs: verify each against the NCS v3.4.1 source and cite file paths.
- You cannot test on hardware. For every behaviour you cannot verify, state it plainly and list the manual test steps
  (commands and expected outcome) in the README.

DELIVERABLES
- The code and CI changes, a short update to README.md and bootloader_and_update.md, and a final summary containing:
  what changed, what was verified (and how), and what remains unverified.
```

## Prompt B: Embedded developer, option 3 (E73 and nRF54L15)

```text
You are a senior embedded firmware engineer with deep Zephyr RTOS, nRF Connect SDK (NCS v3.4.1) sysbuild, MCUboot
and MCUmgr/SMP experience. Work in the repository at the current directory (the OpenThread RCP firmware project).

GOAL
Add MCUboot with UART serial recovery to the two UART-connected boards so firmware can be updated from the Raspberry
Pi over the same serial cable used for Spinel:
- Ebyte E73: `nrf52840dk/nrf52840`, UART0 on P1.11 (TX), P1.10 (RX), P1.08 (RTS), P1.07 (CTS)
- Ezurio (generic nRF54L15): `nrf54l15dk/nrf54l15/cpuapp`, UART20 on P2.02 (TX), P2.00 (RX), P2.01 (RTS), P2.03 (CTS)
Do not change the dongle's build (it is handled separately).

CONTEXT YOU MUST READ FIRST
- .github/workflows/build-rcp.yml, boards/*.overlay, README.md, bootloader_and_update.md.
- NCS v3.4.1 sysbuild MCUboot documentation and sources for these SoCs (nRF54L15 uses RRAM; check partition manager vs
  devicetree partitions, and how MCUboot signing works with sysbuild on each SoC).

TASKS
1. Enable MCUboot through sysbuild for these two boards only, with serial recovery over the same UART pins and the same
   baud rate and flow-control settings as the application (the CI already generates a per-variant devicetree overlay
   for baud and flow control; the bootloader image needs the equivalent).
2. Define how recovery mode is entered. Preferred: the application receives a Spinel reset-to-bootloader (OpenThread
   bootloader mode, retention variant) and reboots into MCUboot recovery; a boot-time pin is acceptable as a fallback.
   Verify that the RCP application and MCUboot share the retained-memory region correctly.
3. Choose and justify the slot layout and sizes for each SoC; confirm the application still fits with image swap or
   direct-xip as appropriate.
4. Signing: CI must sign images with a key stored in a GitHub secret (never in the repo). Provide a documented
   key-generation procedure and a clearly-marked insecure development key mode for local builds.
5. Update the workflow to build these variants and publish: the full merged hex for first-time SWD flashing, and the
   signed update image for MCUmgr, with predictable file names. Keep the release job and the existing artifact naming
   convention working.
6. Define the host interface contract that the script agent will call: the exact commands for the chosen SMP client
   (serial parameters, image upload, test, confirm, reset) and how to enter recovery. The default client is
   `mcumgr-client` (https://github.com/vouch-opensource/mcumgr-client, Rust, aarch64 release binary, v0.1.0 at time of
   research), with Go `mcumgr` as fallback. Neither documents MCUboot serial recovery, so verify it against MCUboot's
   SMP serial implementation and note the Zephyr CDC ACM patch caveat for USB-based recovery. Specify the MCUboot
   buffer-size settings the client needs.

CONSTRAINTS
- Do not invent Kconfig symbols, devicetree properties or commands: verify against NCS v3.4.1 sources and cite paths.
- Keep changes in this repo (Kconfig fragments, sysbuild config, overlays); do not modify the NCS sample itself.
- You cannot test on hardware. State what is unverified and give manual test steps with expected output.
- Do not write the update shell scripts; another agent owns those.

DELIVERABLES
- The code and CI changes, README.md and bootloader_and_update.md updates, and a final summary with: what changed,
  what was verified and how, what remains unverified, and the host interface contract from task 6.
```

## Prompt C: Agent for the update scripts

```text
You are a senior Linux and embedded tooling engineer. Work in the repository at the current directory (the OpenThread
RCP firmware project). Write robust, readable POSIX/bash scripts for updating the RCP firmware from a Raspberry Pi
(Raspberry Pi OS, systemd, otbr-agent service).

INPUTS (read these first; if the interface contracts below are not yet documented there, stop and list what is missing)
- bootloader_and_update.md, README.md, .github/workflows/build-rcp.yml.
- The host interface contracts written by the two firmware agents:
  A) dongle: how to send the Spinel reset-to-bootloader command, then flash `dfu_application.zip` with nrfutil.
  B) E73 and nRF54L15: how to enter MCUboot serial recovery, then upload, test, confirm and reset with the SMP client.
  The default client is `mcumgr-client` (Rust, https://github.com/vouch-opensource/mcumgr-client); use its Linux
  aarch64 or x86-64 release zip and verify the published sha256 before use. Go `mcumgr` is the fallback.

GOAL
One entry script, `scripts/update-rcp.sh`, plus small helpers, that:
1. Takes `--board {dongle|e73|nrf54l15}`, `--port /dev/ttyXXX`, `--baud N`, `--flow`, `--file <image>`, and optional
   `--release <tag>` to download the matching asset from the GitHub release (asset names follow `rcp-<module>-...`).
2. Stops `otbr-agent` safely and always restarts it on exit, including on failure or Ctrl-C (use trap).
3. Enters the bootloader using the board-specific method, uploads the image, verifies it (hash or version) and resets.
4. Waits for the radio to answer again (for example a Spinel version query) before declaring success, and rolls back or
   reports clearly if it does not.
5. Supports `--dry-run`, prints every command it runs, and never touches a device that was not selected explicitly.

REQUIREMENTS
- `set -euo pipefail`, quoted variables, ShellCheck-clean, no dependency beyond what the contracts name
  (nrfutil, the SMP client binary, curl, python3 if the Spinel trigger needs it). The script should download and
  sha256-verify a pinned `mcumgr-client` release for the host architecture (aarch64 or x86-64; armv7 needs a
  cross-build, so report clearly if unsupported).
- Exit codes: 0 success, 2 usage error, 3 bootloader entry failed, 4 upload failed, 5 verification failed.
- Add a `scripts/README.md` with installation of the tools on Raspberry Pi OS (arm64 and armv7), udev rules for stable
  device names, and a troubleshooting section.
- Add a CI job that runs ShellCheck and `--dry-run` for every board.

CONSTRAINTS
- Do not guess tool flags: check each against the installed tool's `--help` or its documentation and quote the version.
- You cannot test on hardware; mark everything unverified and give manual test steps with expected output.

DELIVERABLE
Scripts, docs and CI job, plus a short summary of what was tested, what was not, and any contract gaps found.
```
