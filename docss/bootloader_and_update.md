# Bootloader and firmware update options

How to update the RCP firmware without an SWD probe. The RCP is the Thread radio of an OpenThread Border Router, so
its firmware can only be updated over the host link (USB CDC or UART) and never over the Thread mesh.

> Written from knowledge of NCS and Zephyr plus the web research summarised under "Research findings"; nothing here has
> been verified on hardware or against NCS v3.4.1 builds. Items marked **(verify)** must be checked before relying on them.
>
> Option 3 for the E73 and the nRF54L15 is now implemented in configuration (not built, not tested on hardware): see
> "Implementation: MCUboot serial recovery for E73 and Ezurio" below, including the host contract and the gap analysis.

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
- Status: implemented for E73 and Ezurio, see "Implementation: MCUboot serial recovery for E73 and Ezurio".

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

### Holyiot dongle: front-end (PA/LNA) configuration (2026-10-21)

The vendor's working NCS 3.1.0 build adds a `generic-fem-two-ctrl-pins` node (`nrf_radio_fem`, CTX P0.24, CRX P0.22, TX gain 22 dB, RX gain 12 dB, settle 1 us), `&radio { fem = <&nrf_radio_fem>; }` and `CONFIG_MPSL_FEM`/`CONFIG_MPSL_FEM_SIMPLE_GPIO`. Our earlier dongle builds lacked it and crashed Raspberry Pi 3 hosts once `otbr-agent` made the radio active (suspected PA left enabled). Now in `boards/nrf52840dongle_nrf52840-fem.{overlay,conf}` and applied to every dongle variant. Found by CI on 2026-10-21: NCS 3.4.1 renamed the compatible to `radio-fem-two-ctrl-pins` (3.1.0: `generic-fem-two-ctrl-pins`). With the old name the FEM was silently not applied (build passed, `MPSL_FEM_SIMPLE_GPIO` unset), so the build now has a CI check for it and the NCS 3.1.0 variant uses its own overlay. Unverified on the Pi.

### Dongle crash bisect (2026-10-22)

Result so far: with the same front-end config, the NCS 3.1.0 build runs fine on the Pi 3 and the NCS 3.4.1 build hangs it
as soon as `otbr-agent` starts the radio. Differences found in the NCS sources: (1) the sample's dongle config uses the
legacy USB stack up to NCS 3.2.x and `USB_DEVICE_STACK_NEXT` from 3.3.0; (2) the OpenThread revision is identical in
3.1.0-3.3.4 (`ncs-thread-reference-20250402`) and changes in 3.4.0 (`0fe68ff`); (3) the front-end compatible was renamed in
3.3.0. CI builds `-ncs3.2.2` (legacy USB, same OT) and `-ncs3.3.4` (new USB, same OT). Reading: 3.2.2 ok + 3.3.4 hangs => new
USB stack; 3.3.4 ok => the 3.4 OpenThread/other changes. A third experiment, NCS 3.4.1 with the legacy USB stack
(`CONFIG_USB_DEVICE_STACK`), first did not link on 3.4.1 (both stacks defined the CDC ACM device).

**Resolution (2026-10-26, verified on the Pi):** NCS 3.4.1 with the legacy USB stack is the dongle build.
`boards/nrf52840dongle_nrf52840-legacyusb.conf` explicitly disables `USB_DEVICE_STACK_NEXT` (fixes the link error) and
sets `USB_DEVICE_INITIALIZE_AT_BOOT=y`. That option has no default and nothing else in the sample or the OpenThread
platform calls `usb_enable()`, so without it the dongle never enumerates (first legacy build: no USB device at all).
With both, the dongle enumerates and the Pi reports `RCP-firmware 0fe68ff; Zephyr; Oct 26 2026 08:41:29`. CI checks the
option in the final `.config`. The other dongle variants (plain, `-dfutouch`, `-ncs3.x`) are no longer built.

### Holyiot dongle: weak RX traced to uart0 owning the FEM pins (2026-10-26)

Symptom on the NCS 3.4.1 legacy-USB build: a SmartThings hub 1 m away was heard at about -100 dBm and `ot-ctl scan energy`
returned a flat -92 dBm on all channels; the pre-project vendor firmware received normally on the same dongle. Cause: the
stock dongle board enables `uart0` with RX on P0.24 and CTS on P0.22 (pull-ups), the same pins as the FEM CTX/CRX, so the
UART owns them and the FEM driver cannot switch the PA/LNA. The vendor's config comments out `uart0` for this reason (their
email: "I have to disable UART"). Fix: `&uart0 { status = "disabled"; };` in the FEM overlays, with a CI check on the final
devicetree. Unverified on hardware until re-tested.

TX power with the FEM (NCS radio driver): the requested power is power on air; the driver subtracts `tx-gain-db` (22) and
rounds the nRF52840 level down to the nearest supported step (+8..+2, 0, -4, -8, -12, -16, -20, -40 dBm). So the default
`CONFIG_OPENTHREAD_DEFAULT_TX_POWER=0` gives about -18 dBm on air; `txpower 16` gives about 14 dBm. `ot-ctl txpower`
shows the requested value, not the achieved one.

### Holyiot dongle bootloader

**Field evidence (2026-10-21, from the project owner):** an older RCP firmware was flashed to a Holyiot dongle through the
pre-flashed Nordic bootloader, with no SWD/SWC programmer involved. So the dongle ships with a working USB DFU bootloader,
Nordic's open bootloader. **Verified on hardware (2026-10-26):** a Spinel `reset-bootloader` (`rcp_spinel.py`, i.e. the
firmware's `OPENTHREAD_PLATFORM_BOOTLOADER_MODE_GPIO` reset pin P0.19) from the Pi puts the dongle into the bootloader,
and `lsusb` shows `1915:521f Nordic Semiconductor ASA Open DFU Bootloader`; re-flashing from the bootloader gives a
working RCP again. Still unconfirmed: whether it honours the `GPREGRET = 0xB1` entry used by the touch module (not
part of the CI dongle build any more). That older firmware reports
`thread-reference-20250612-1400-g22b2ec2a8; NRF52840; Aug 15 2026 01:11:15` (upstream OpenThread commit from 2026-08-08,
platform tag typical of OpenThread's own nRF platform rather than Zephyr), i.e. it is not an NCS release build.

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

## Implementation: MCUboot serial recovery for E73 and Ezurio (Prompt B)

**Status: configuration written, NOT built and NOT tested on hardware.** No NCS toolchain was available when this was
written, so the first real build is the CI run. Everything below is checked against sources at these tags
(raw files, paths relative to each repository): `nrfconnect/sdk-nrf` `v3.4.1`, `nrfconnect/sdk-zephyr` `ncs-v3.4.1`,
`nrfconnect/sdk-mcuboot` `ncs-v3.4.1`, `nrfconnect/sdk-openthread` `0fe68ff` and `vouch-opensource/mcumgr-client`
`v0.1.0`. Statements that are inference or need hardware are marked **(unverified)**.

Scope: Ebyte E73 (`nrf52840dk/nrf52840`) and Ezurio (`nrf54l15dk/nrf54l15/cpuapp`) only. The dongle build is unchanged.

### Files added or changed

| File | Purpose |
| :--- | :--- |
| `mcuboot/sysbuild.conf` | Sysbuild options: MCUboot, overwrite-only mode, one updateable image, merged hex |
| `mcuboot/sysbuild-ecdsa-p256.conf`, `mcuboot/sysbuild-ed25519.conf` | Signature type per SoC (E73 ECDSA P-256, Ezurio Ed25519) |
| `mcuboot/mcuboot.conf` | MCUboot Kconfig: UART serial recovery, retention boot-mode entry, direct upload to slot 1 |
| `mcuboot/app.conf` | RCP application Kconfig: retention boot mode and OpenThread bootloader-mode (retention) |
| `mcuboot/mcuboot-recovery-wait.conf` | OPTIONAL extra MCUboot fragment (wait for SMP after every reset), not used by CI |
| `.github/workflows/build-rcp.yml` | Matrix fields `mcuboot` and `mcuboot_sig` on the four UART entries, a prepare step, one changed west argument, extra artifact handling |
| `.gitignore` | Ignores `*.pem`, `*.key` and `mcuboot-keys/` so a signing key is never committed |

The NCS sample is not modified. Everything is passed with `-D` arguments (see "CI changes").

### Design decisions

**1. Update mode: overwrite-only, upload to the secondary slot, `test`, `reset`.**
The RCP application has no MCUmgr server, so nothing in the running image can confirm a swap. That rules out the
swap modes (`SB_CONFIG_MCUBOOT_MODE_SWAP_*`): after a `test` swap MCUboot would revert on the following boot because no
one calls `boot_write_img_confirmed()`. Direct-XIP needs an image linked per slot (the variant image generation is
`EXPERIMENTAL` in `share/sysbuild/images/bootloader/Kconfig`) and the revert variant also needs a confirm. Overwrite-only
(`SB_CONFIG_MCUBOOT_MODE_OVERWRITE_ONLY`, text in `share/sysbuild/images/bootloader/Kconfig`: "not possible to revert
back to previous version") has no confirm step. Properties:
- Serial recovery uploads to the **primary** slot by default (`docs/serial_recovery.md`: "Uploading an image is targeted
  to the primary slot by default"). A cable pull or a corrupt upload would then destroy the running firmware.
  With `CONFIG_MCUBOOT_SERIAL_DIRECT_IMAGE_UPLOAD=y` the SMP `image` field selects the slot
  (`boot/zephyr/flash_map_extended.c`: 0 and 1 map to `slot0_partition`, 2 to `slot1_partition`), so the update goes to
  slot 1 and the old image stays intact until MCUboot has validated the new one.
- At boot MCUboot validates the secondary image's signature, then copies it over the primary slot and erases the
  secondary header (`boot/bootutil/src/loader.c`, `boot_copy_image()`, overwrite-only branch). An invalid secondary image
  is not copied. An interrupted copy is expected to restart at the next boot because the pending marker in the secondary
  trailer is only erased after the copy **(unverified on hardware)**.
- `image test <hash>` is what makes the secondary pending (`boot/boot_serial/src/boot_serial.c`, `bs_set()` calls
  `boot_set_pending_multi()`); it needs `CONFIG_BOOT_SERIAL_IMG_GRP_IMAGE_STATE=y`. In overwrite-only mode a test and a
  permanent request both end in a copy (`loader.c` handles `BOOT_SWAP_TYPE_TEST` and `_PERM` in the same branch).
- Rollback is therefore NOT automatic. "Roll back" means uploading the previous signed `-update.bin` again. The host
  script must keep the last known-good image. A new image that boots but breaks Spinel is only recoverable through
  another recovery entry (see the gap analysis).
- Optional later extension for automatic rollback: swap mode plus a tiny extra Zephyr module (added through
  `ZEPHYR_EXTRA_MODULES`) that calls `boot_write_img_confirmed()` after N seconds of healthy uptime. Not implemented.

**2. Entering recovery: retained boot mode, triggered by Spinel.**
- `modules/openthread/platform/misc.c` (sdk-zephyr): with `CONFIG_OPENTHREAD_PLATFORM_BOOTLOADER_MODE_RETENTION` the RCP's
  `otPlatResetToBootloader()` calls `bootmode_set(BOOT_MODE_TYPE_BOOTLOADER)` and `sys_reboot(SYS_REBOOT_WARM)`.
  `modules/openthread/Kconfig.features`: that option `depends on RETENTION_BOOT_MODE && REBOOT`.
- MCUboot with `CONFIG_BOOT_SERIAL_BOOT_MODE` checks `bootmode_check(BOOT_MODE_TYPE_BOOTLOADER)`, clears it and enters
  serial recovery (`boot/zephyr/io.c`, `io_detect_boot_mode()`, called from `boot/zephyr/main.c` **after** `boot_go()`,
  so a pending copy is performed first).
- Both boards already define the retention node and select it as `zephyr,boot-mode`: `boards/nordic/nrf52840dk/
  nrf52840dk_nrf52840.dts` and `boards/nordic/nrf54l15dk/nrf54l_05_10_15_cpuapp_common.dtsi` (`&gpregret1 { boot_mode0:
  boot_mode@0 { compatible = "zephyr,retention"; reg = <0x0 0x1>; }; }`). The retained byte is a GPREGRET register, not
  RAM, and both images are built from the same board devicetree, so they address the same byte. No overlay is needed.
- `RETAINED_MEM` and `RETENTION` are menuconfigs without defaults (`drivers/retained_mem/Kconfig`,
  `subsys/retention/Kconfig`), so `app.conf` and `mcuboot.conf` set `RETAINED_MEM`, `RETENTION` and
  `RETENTION_BOOT_MODE` explicitly.
- The Spinel side: `CMD_RESET` (value 1) with a one-byte reset type `SPINEL_RESET_BOOTLOADER = 3`
  (`src/lib/spinel/spinel.h`) is handled in `NcpBase::CommandHandler_RESET()` (`src/ncp/ncp_base.cpp`) and calls
  `otInstanceResetToBootloader()` when `OPENTHREAD_CONFIG_PLATFORM_BOOTLOADER_MODE_ENABLE` is set. The NCS CMake maps
  `CONFIG_OPENTHREAD_PLATFORM_BOOTLOADER_MODE` to that OT option (`modules/openthread/CMakeLists.txt` in sdk-nrf).
  The RCP then advertises `SPINEL_CAP_RCP_RESET_TO_BOOTLOADER`.
- The NCS sample README says the host OpenThread apps need `-DOT_PLATFORM_BOOTLOADER_MODE=ON` for the dongle's reboot
  flow; the same applies if you trigger it through `ot-ctl` (see the host contract). The retention variant is not
  documented by Nordic for the coprocessor sample, only the GPIO variant for the dongle, so the retention path is
  source-verified but **unverified on hardware**.

**3. UART for recovery: same pins, fixed 115200 8N1, no hardware flow control, for every variant.**
This deviates from "same baud and flow as the application" on purpose:
- `mcumgr-client` v0.1.0 opens the port with the `serialport` crate defaults (`src/transfer.rs`, `open_port()`) and has
  no flow-control option, so a flow-control-enabled recovery UART could stall on CTS **(unverified)**.
- MCUboot is flashed once and never updated over SMP. If its baud followed the application variant, uploading the wrong
  variant (115200 image onto a 460800 module) would leave a module whose application and recovery speeds differ and
  that cannot be recovered without guessing. A fixed recovery rate removes that failure and makes the host contract
  independent of the variant. The application image is about 110 KiB (release assets: 114,308 bytes on E73, 111,228
  bytes on Ezurio), so 115200 baud costs roughly 15 to 25 s per update.
- The overlay is generated in CI (`overlay-mcuboot-uart.overlay`) with only `current-speed`. Neither board devicetree
  sets `hw-flow-control` for these UARTs (the sample's own overlays do, but those apply to the application only).
  Override with a matrix field `mcuboot_baud` if you want a different recovery rate.

**4. Slot layout: board devicetree partitions, unchanged.**
The sample's `Kconfig.sysbuild` sets `config PARTITION_MANAGER default n`, so layout comes from devicetree partitions
(`prj.conf`'s `CONFIG_PM_PARTITION_SIZE_SETTINGS_STORAGE` has no effect here).

| | E73 (nRF52840, flash) | Ezurio (nRF54L15, RRAM) |
| :--- | :--- | :--- |
| Source | `dts/vendor/nordic/nrf52840_partition.dtsi` | `dts/vendor/nordic/nrf54l15_cpuapp_partition.dtsi` |
| MCUboot (`boot_partition`) | 0x00000, 48 KiB | 0x00000, 62 KiB |
| slot0 (primary, app runs here) | 0x0C000, 472 KiB | 0x10000, 712 KiB |
| slot1 (secondary, upload target) | 0x82000, 472 KiB | 0xC2000, 712 KiB |
| storage | 0xF8000, 32 KiB | 0x174000, 36 KiB |
| Current app size (without header) | 114,308 B | 111,228 B |

Both slots hold the app several times over, so overwrite-only fits with a large margin and no partition changes are
needed. If `WITH_FLPR_PARTITIONS` were defined the nRF54L15 slots would shrink to 664 KiB; it is not defined by the
board or by this build. Whether MCUboot itself fits in 48 KiB on the nRF52840 with ECDSA P-256 plus serial recovery is
decided by the CI build (the same configuration `sample.bootloader.mcuboot.serial_recovery` in `boot/zephyr/sample.yaml`
is built for `nrf52840dk/nrf52840` in MCUboot's CI, so it is plausible **(unverified here)**).

**5. Signing.**
- E73: ECDSA P-256, Ezurio: Ed25519 with SHA-512 image hash (NCS default for nRF54L, `sysbuild/Kconfig.mcuboot`).
- nRF54L15 KMU (`SB_CONFIG_MCUBOOT_SIGNATURE_USING_KMU`) is left off: the public key is embedded in the MCUboot image,
  so there is no key provisioning step after the SWD flash. Consequence: the key cannot be rotated without reflashing
  MCUboot over SWD. KMU-based keys would need a provisioning step and are not part of this change.
- The image hash shown by `list` is 32 bytes (SHA-256) on E73 and 64 bytes (SHA-512) on Ezurio
  (`IMAGE_HASH_SIZE` in `boot_serial.c`); `test` requires a hash of exactly that size.

### Signing keys

Never commit a private key. `.gitignore` blocks `*.pem`, but treat that as a safety net only.

Generate (once, offline) with imgtool, which ships in the MCUboot repository and on PyPI:

```bash
pip install imgtool        # or: python3 <ncs>/bootloader/mcuboot/scripts/imgtool.py
imgtool keygen -k mcuboot-ecdsa-p256.pem -t ecdsa-p256   # E73
imgtool keygen -k mcuboot-ed25519.pem   -t ed25519       # Ezurio
```

(`imgtool keygen` types are listed in `docs/imgtool.md`: rsa-2048, rsa-3072, ecdsa-p256, ed25519.)

Store them as GitHub Actions secrets (the whole PEM text, including the BEGIN and END lines):

```bash
gh secret set MCUBOOT_SIGN_KEY_ECDSA_P256 < mcuboot-ecdsa-p256.pem
gh secret set MCUBOOT_SIGN_KEY_ED25519   < mcuboot-ed25519.pem
```

Keep an offline backup. The public half is baked into every MCUboot that was flashed, so losing the private key means
re-flashing MCUboot over SWD with a new key on every device.

**Insecure development key mode.** If the secret is not set, the workflow builds with MCUboot's public development keys
(`bootloader/mcuboot/root-ec-p256.pem` and `root-ed25519.pem` in the NCS workspace; this is simply the default of
`SB_CONFIG_BOOT_SIGNATURE_KEY_FILE`). Anyone can sign images for such a module. The workflow emits a `::warning::`,
names the files `rcp-<base>-DEVKEY...`. Decision (2026-10-21): dev-key builds are still published, including in
releases, until the real key is stored as a GitHub secret after testing; the `-DEVKEY` marker in the file name is what
identifies them. Never ship modules flashed with a dev-key image.

For a local build, add `-DSB_CONFIG_BOOT_SIGNATURE_KEY_FILE=...` through a conf fragment containing
`SB_CONFIG_BOOT_SIGNATURE_KEY_FILE="/abs/path/key.pem"` (quote the value inside the file, not on the command line).

### CI changes and outputs

Matrix: `mcuboot: true` and `mcuboot_sig: ecdsa-p256 | ed25519` on the four UART entries; the dongle entry is untouched
(an undefined matrix field is falsy, so its steps are skipped). New step "Prepare MCUboot variant" writes the key from the
secret into `$RUNNER_TEMP` (mode 077 umask), generates the MCUboot UART overlay and an image version fragment
(`CONFIG_MCUBOOT_IMGTOOL_SIGN_VERSION="1.0.0+<run number>"`) and exports `MCUBOOT_ARGS`. The build step only gained
`$MCUBOOT_ARGS` on its `west build` line. A final step removes the key file (the runner is ephemeral anyway).

The resulting west arguments (all absolute paths):

```text
-DSB_EXTRA_CONF_FILE=mcuboot/sysbuild.conf;mcuboot/sysbuild-<sig>.conf;<generated sign fragment>
-DEXTRA_CONF_FILE=mcuboot/app.conf;<generated version fragment>
-Dmcuboot_EXTRA_CONF_FILE=mcuboot/mcuboot.conf
-Dmcuboot_EXTRA_DTC_OVERLAY_FILE=boards/<board>.overlay;<generated overlay-mcuboot-uart.overlay>
```

`EXTRA_CONF_FILE` without prefix goes to the main application only and `<image>_`-prefixed variables to that image
(`cmake/modules/configuration_files.cmake`: `zephyr_get(EXTRA_CONF_FILE SYSBUILD LOCAL ...)`).

Artifacts per MCUboot variant (`<base>` is the existing `<module>-<baud>baud-<flow|noflow>`):

| File | Content | Use |
| :--- | :--- | :--- |
| `rcp-<base>.hex` | Merged hex: MCUboot + signed application (`build/merged_<board>.hex`, from `SB_CONFIG_MERGED_HEX_FILES`; fallback merge with `mergehex.py` if absent) | One-time SWD flash |
| `rcp-<base>-update.bin` | `coprocessor/zephyr/zephyr.signed.bin` | MCUboot serial recovery upload |
| `rcp-<base>-update.bin.sha256` | `sha256sum` of the update image | Integrity check before upload |

Variants and naming (2026-10-21): every board keeps its original **plain** build with unchanged file names, and gets an
update-capable variant whose `<base>` carries a suffix:

| Board | Plain (unchanged) | Update-capable |
| :--- | :--- | :--- |
| Dongle | `rcp-holyiot-nrf52840-dongle-usb[.hex/.bin/-dfu.zip]` | `...-usb-dfutouch[...]` (1200-baud touch module) |
| E73, Ezurio | `rcp-<module>-<baud>baud-<flow\|noflow>.hex/.bin` (SWD flash only) | `...-<flow\|noflow>-mcuboot[-DEVKEY].hex` (merged), `...-mcuboot[-DEVKEY]-update.bin` (+ `.sha256`) |

So in the sections above and below, `<base>` for an MCUboot variant includes `-mcuboot`. A plain image cannot be
uploaded through MCUboot recovery, and an MCUboot image needs the one-time SWD flash first. The artifact name is
`rcp-<base>`, so the release job (`pattern: rcp-*`) publishes everything, dev-key builds included.

### One-time SWD flash

Modules in the field today run the bare application at 0x0 and have no MCUboot; they cannot be converted over the
cable. Flash `rcp-<base>.hex` (merged) once, with a full erase (same command as in the README):

```text
nrfutil device program --firmware rcp-<base>.hex --options chip_erase_mode=ERASE_ALL,verify=VERIFY_READ --traits jlink
nrfutil device reset
```

After that the application lives in slot0 (E73 0xC000, Ezurio 0x10000). The E73 flow with OpenOCD from the README also
works with this hex (`program rcp-<base>.hex verify reset exit`).

### HOST CONTRACT (for the update script)

This is the interface the script agent may rely on. All commands are unverified on hardware.

**Inputs.** Serial port (for example `/dev/ttyAMA0`), application serial settings of the variant (baud 115200 or 460800,
8N1, RTS/CTS only for the 460800 variants), signed image `rcp-<base>-update.bin` plus its `.sha256`, and the variant
must match the module's wiring (baud only matters for step 1 now; recovery is always 115200).

**Tools.** `mcumgr-client` v0.1.0 (`mcumgr-client-linux-aarch64.zip` plus `.sha256sum` from the release page, verified
against its README and `src/*.rs`); Go `mcumgr` as fallback (`mcumgr --conntype serial --connstring
"dev=/dev/ttyAMA0,baud=115200" ...`, not checked against its source). Python `pyserial` or plain `stty` for step 1.

**Step 0, prepare.** `sha256sum -c rcp-<base>-update.bin.sha256`; `systemctl stop otbr-agent`; make sure no other process
holds the port (otbr-agent, `ot-ctl` keep it busy). Record `ot-ctl rcp version` before stopping if you want to compare
afterwards.

**Step 1, enter recovery (Spinel reset to bootloader).** Preferred, with no dependency on how otbr-agent was built: write
this HDLC-lite frame to the port at the application's serial settings (including RTS/CTS for flow variants):

```text
7E 81 01 03 BF BB 7E
```

Meaning: flag, Spinel header `0x81` (header flag `0x80`, interface 0, TID 1; `SPINEL_HEADER_FLAG` in `spinel.h`),
`CMD_RESET` `0x01`, reset type `SPINEL_RESET_BOOTLOADER` `0x03`, FCS-16 `BF BB` (CRC-16 init 0xFFFF, reflected polynomial
0x8408, final complement, low byte first, as in `src/lib/hdlc/hdlc.cpp`; none of the bytes needs escaping), flag. Example:
`python3 -c "import serial;s=serial.Serial('/dev/ttyAMA0',460800,rtscts=True);s.write(bytes.fromhex('7e810103bfbb7e'));s.flush()"`.
The CRC was computed offline from the algorithm in the source; verify the frame against a capture of a real
`otbr-agent` reset if possible. Expected: no reply, the module reboots (if the RCP cannot reset into the bootloader,
`CommandHandler_RESET()` returns an error instead of rebooting). Alternative with the agent still running: `ot-ctl reset bootloader` (`src/cli/cli.cpp`), which only
works if the **host** OpenThread/otbr-agent was built with `OT_PLATFORM_BOOTLOADER_MODE=ON` (otherwise the command does
not exist) **(unverified)**; afterwards stop the agent. `ot-ctl diag rcpcaps spinel` should list the reset-to-bootloader
capability of the RCP when the agent has `OPENTHREAD_POSIX_CONFIG_RCP_CAPS_DIAG_ENABLE`.

**Step 2, wait for MCUboot.** Close the port. MCUboot first validates the images (signature check, maybe 1 s, unmeasured)
and only then checks the boot mode, and it prints nothing, so probe with SMP: repeat once per second for up to 20 s

```text
mcumgr-client -s -d /dev/ttyAMA0 -b 115200 -t 2 echo ping       # success: exit 0, prints "Echo response: ping"
```

(`-b 115200` is also the client default; `-t` is the per-read timeout in seconds, default 60, so it must be lowered;
`-s` silences the banner, errors then show only through exit code 1). If the probe never succeeds the module did not
enter recovery: see failure modes.

**Step 3, inspect.**

```text
mcumgr-client -d /dev/ttyAMA0 -b 115200 -t 5 list
```

Expected: `response: { "images": [ { "image": 0, "slot": 0, "version": "1.0.0.<n>", "hash": "<64 or 128 hex digits>", "bootable": true, ... } ] }`
(slot 1 only appears when an image is present there). Field names are from `ImageStateEntry` in `src/nmp_hdr.rs`.

**Step 4, upload to the secondary slot.**

```text
mcumgr-client -d /dev/ttyAMA0 -b 115200 -t 10 -u 500 --nb-retry 8 upload rcp-<base>-update.bin --slot 2
```

`--slot` is sent as the SMP `image` field. With `CONFIG_MCUBOOT_SERIAL_DIRECT_IMAGE_UPLOAD` 2 means slot1 (`flash_area_id_from_direct_image()`);
the client's default of 1 would overwrite the primary slot, so always pass `--slot 2`. Do not put the text `slot1` or
`slot3` in the file name (the client then overrides `--slot`). `-u` is the per-packet timeout after the first packet in ms
(default 200, too tight for a 4 KiB page erase at 115200, so use 500); `-t` covers the first packet which triggers the first erase.
Defaults `-l 128` (line length) and `-m 512` (request size) match MCUboot's `CONFIG_BOOT_MAX_LINE_INPUT_LEN=128`,
`CONFIG_BOOT_LINE_BUFS=8` and `CONFIG_BOOT_SERIAL_MAX_RECEIVE_SIZE=1024`; do not raise `-m` above 1024 or `-l` above 128
without raising those Kconfig values in `mcuboot/mcuboot.conf` too (the MCUmgr netbuf size is not involved: MCUboot uses its own
`boot_serial` code, not the MCUmgr server). Expected: progress bar to 100 %, exit 0, about 20 to 40 s at 115200 **(estimate)**.

**Step 5, verify the upload and mark it for boot.**

```text
mcumgr-client -d /dev/ttyAMA0 -b 115200 -t 5 list          # now also "slot": 1 with the new version/hash
mcumgr-client -d /dev/ttyAMA0 -b 115200 -t 5 test <hash of slot 1 from list>
mcumgr-client -d /dev/ttyAMA0 -b 115200 -t 5 list          # slot 1 shows "pending": true
```

`test` without `--confirm` is enough; in overwrite-only mode a test and a permanent request behave the same.

**Step 6, reboot and apply.**

```text
mcumgr-client -d /dev/ttyAMA0 -b 115200 -t 5 reset
```

MCUboot validates slot 1, copies it to slot 0 (a few seconds for 110 KiB, unmeasured), erases slot 1's header and starts
the application. Wait 10 s (or poll as in step 7).

**Step 7, verify the new image runs.** MCUboot is gone and the RCP has no SMP, so verify through Spinel: start
`otbr-agent` (`systemctl start otbr-agent`), then `ot-ctl rcp version` must answer and differ from the value recorded in
step 0 (the string contains the build date and time, `otPlatRadioGetVersionString` in `src/cli/cli.cpp`), and the
agent log must not show `incompatible API versions`. For a deterministic check that does not depend on the host stack,
read the version of slot 0 in a second recovery session (repeat steps 1 to 3) and compare it with `1.0.0+<run number>`
and the hash with the one printed in step 3 (this reboots the RCP again).

**Timing summary (all unmeasured, for first script defaults).** Reset to responding MCUboot: up to 5 s; upload: up to
90 s; reset to application ready: up to 15 s; whole procedure timeout: 3 min. `otbr-agent` must stay stopped from step
0 to the end of step 6 and must be restarted in every exit path (including failure and Ctrl-C).

**Failure modes and actions.**

| Symptom | Likely cause | Action |
| :--- | :--- | :--- |
| Step 1 write works but step 2 never answers | App does not implement bootloader mode (wrong build, `app.conf` not applied), retention flag lost, otbr-agent still holding the port, module not wired at the assumed baud/flow | Check RCP caps, retry; use the recovery-entry fallbacks in the gap analysis; SWD as last resort |
| Echo OK but upload fails with `wrong offset`, `wrong checksum` or timeouts | Dropped bytes on the UART (long cable, no flow control at 115200 is normally fine), too small `-u` | Retry the whole upload (restarting at offset 0 is supported), raise `-u`, lower `-m`/`-l` |
| Upload fails immediately with an SMP error (`rc`) | Wrong `--slot` (image 1 on a build without direct upload addresses image index 1, which does not exist), image larger than the slot, MCUboot in single-slot config | Use `--slot 2`; check `list` |
| After reset the old version is still running | Signature or header of the new image was rejected by MCUboot (wrong key, unsigned, dev-key image on a prod module) | Rebuild with the matching key, repeat |
| After reset nothing answers on Spinel | Image is valid but broken, or has the wrong UART variant, or MCUboot sits in recovery because no valid image was found | Re-enter recovery (MCUboot answers `echo` if it is in recovery), upload the last known-good image |
| MCUboot never answers and the app is dead | No entry method left | Pin or power-cycle fallback if built in, otherwise SWD with `rcp-<base>.hex` |

### Gap analysis: what else is needed for this to work?

Items in order of how likely they are to block a working field update. "Done" means in this repository, not tested.

1. **Hardware validation of the whole chain (blocking, not done).** Nothing here has run. Minimum bench test per SoC:
   build in CI, SWD-flash the merged hex, confirm the RCP works with `otbr-agent`, then run the host contract once end to
   end including a deliberately wrong-key image (must be rejected, old app keeps running) and an unplugged-cable upload
   (module must stay recoverable). Record upload time, MCUboot boot time and whether the 460800/flow variant behaves.
2. **GitHub secrets (not done).** `MCUBOOT_SIGN_KEY_ECDSA_P256` and `MCUBOOT_SIGN_KEY_ED25519` must be created with
   the commands above before the release job can publish UART images. Decide who holds the offline key backup.
3. **How the app enters recovery (done in config, unverified).** Retention-based, not a boot pin: Spinel
   `RESET_BOOTLOADER` -> `bootmode_set()` -> warm reboot -> MCUboot `io_detect_boot_mode()`. The Kconfig and devicetree
   needed are exactly `mcuboot/app.conf` and `mcuboot/mcuboot.conf`; no devicetree changes (both boards already have
   `zephyr,boot-mode`). The OpenThread retention option exists in NCS v3.4.1 (`Kconfig.features`, `misc.c`) and builds on
   `RETENTION_BOOT_MODE && REBOOT`. A boot pin is not wired because the repo's overlays define none and the DK button
   pin may be used on the real module.
4. **The host must be able to send that command (host side, not done).** The reliable way needs no otbr-agent feature:
   send the 7-byte frame from the host contract with a few lines of Python. `ot-ctl reset bootloader` only works if the
   host build enabled `OT_PLATFORM_BOOTLOADER_MODE`. If neither is acceptable the alternatives are, in order:
   (a) `mcuboot/mcuboot-recovery-wait.conf` (MCUboot waits 500 ms after every reset for an SMP command; host resets the
   module by power-cycling it or toggling nRESET and spams `echo`; this also recovers a crash-looping app; costs boot
   latency and needs a reset path), (b) `CONFIG_BOOT_SERIAL_PIN_RESET=y` (a pin reset enters recovery; needs nRESET on a
   Pi GPIO), (c) `CONFIG_BOOT_SERIAL_ENTRANCE_GPIO=y` with a boot pin that is verified to be free and wired to a Pi GPIO,
   (d) SWD. None of (a) to (c) is enabled today.
5. **One UART shared by two protocols.** Spinel/HDLC (0x7E framing) and MCUboot SMP serial (lines starting `06 09` or
   `04 14`, base64, CRC-16, newline) never run at the same time: MCUboot is only active after the application has
   rebooted, and the host stops otbr-agent first. Requirements and status:
   - Console and logging off on the wire: MCUboot's `serial_adapter.c` has a build-time `#error` if `UART_CONSOLE` is on
     while the console and MCUmgr share a UART (`mcuboot.conf` sets `CONFIG_UART_CONSOLE=n`; MCUboot logging is the
     minimal printk backend and therefore silent). The application side is whatever the NCS RCP sample already does
     (it must not print on the Spinel UART, unchanged by this work).
   - Baud and flow: recovery is fixed at 115200, no flow control (see design decision 3). The application keeps its
     variant settings.
   - Buffers: `CONFIG_BOOT_MAX_LINE_INPUT_LEN` 128, `CONFIG_BOOT_LINE_BUFS` 8, `CONFIG_BOOT_SERIAL_MAX_RECEIVE_SIZE` 1024
     (Kconfig defaults, `boot/zephyr/Kconfig.serial_recovery`; the C macro `MCUBOOT_SERIAL_MAX_RECEIVE_SIZE` has a 512
     fallback in `boot_serial.c` but Zephyr always defines it from the Kconfig value). The client's defaults fit.
     Faster uploads need larger values on both sides (the client README measured 10x with 8192/4096, which costs
     RAM: `line_bufs[BOOT_LINE_BUFS]` of `BOOT_MAX_LINE_INPUT_LEN` bytes). MCUmgr netbuf options do not apply to MCUboot.
   - The MCUboot UART path is interrupt-driven (`MCUBOOT_SERIAL` selects `UART_INTERRUPT_DRIVEN`), fine at 115200.
   - MCUboot cleans up the UARTE before jumping to the application (`boot/zephyr/nrf_cleanup.c`), so the RCP's UART
     driver starts from a clean state **(unverified)**.
6. **Layout and size (done, build decides).** No partition changes, slots are about four to six times the application
   size, MCUboot has 48 KiB (E73) and 62 KiB (Ezurio). Open: the E73's 48 KiB with ECDSA P-256 plus serial recovery
   must fit; the CI link step is the check.
7. **nRF54L15 specifics (done, unverified).** RRAM write granularity and erase are handled by the Zephyr RRAM driver and
   MCUboot's `socs/nrf54l15_cpuapp.conf`; image slots live in `cpuapp_rram`. Ed25519 with SHA-512 is the NCS default;
   the build was configured explicitly. KMU is off (see decision 5). The default build target is the secure
   `nrf54l15dk/nrf54l15/cpuapp` (no TF-M), as before.
8. **Signing keys (done in CI, secrets missing).** See "Signing keys". Private keys come only from secrets or a local
   file outside the repo.
9. **First flash (documented).** Existing modules need the SWD flash of the merged hex once, with full erase.
10. **Confirmation and rollback (decided, documented).** Nobody confirms: overwrite-only has no revert, and the RCP has
    no SMP server. Safety comes from MCUboot's validate-before-copy and from keeping the previous `-update.bin` on the
    host. True A/B with automatic revert would require a confirm module in the application and swap mode. Not built.
11. **CI outputs and naming (done).** See the artifact table; the release job is untouched. Decision needed: until the
    secrets exist the UART variants are dev-key builds and are not released.
12. **otbr-agent stop/start (host, contract written).** Stop before step 1, restart on every exit path, and re-check that
    the RCP answers before declaring success. A fixed RCP reset time of 2 s (`kMaxWaitTime` in `spinel_driver.hpp`
    and `radio_spinel.hpp`) applies to platform resets after a host restart; MCUboot adds image validation time to every
    reboot of the module. Measure that on both boards.
13. **Version policy (partly done).** CI stamps `1.0.0+<run number>`. Downgrade prevention is not enabled, so the host
    script decides whether to allow older images.
14. **Dongle.** Not touched. It keeps its own bootloader and flow.

### Manual test plan (per board, bench, with an SWD probe attached)

1. Build in CI (dev key is fine). Flash `rcp-<base>.hex` with the SWD command above. Expect the RCP to work with the
   usual `otbr-agent` command line.
2. `ot-ctl rcp version` and `ot-ctl diag rcpcaps spinel`; note the version.
3. Stop the agent, send the frame, run the echo probe. Expected: `Echo response: ping` within a few seconds.
4. Run steps 3 to 6 with a second CI image (different run number). Expected: `list` shows the new `1.0.0.<n>` in slot
   1, `pending: true` after `test`, and after `reset` the RCP answers Spinel with a different `rcp version` string.
5. Negative tests: image signed with another key (must be ignored, old app keeps running); power-cycle during upload
   (module still answers echo after re-entering recovery or comes up with the old app); upload of a truncated file.
6. Repeat on the 460800/flow variant (application at 460800 with RTS/CTS, recovery still at 115200 without flow).

### Risks

- Everything above is unbuilt and untested on hardware. Config symbols were checked in source, but Kconfig dependency
  or choice conflicts only show up in the real build.
- MCUboot's retention flag handling, the overwrite-only copy resume after power loss, and `test` with a SHA-512 hash on
  Ezurio are source-reviewed, not exercised.
- The 7-byte Spinel frame was derived from the source (no capture). A wrong FCS would be dropped silently.
- A valid-but-broken application with no fallback entry needs SWD. This is the main field risk of this design.
- Public development keys are in the NCS tree; never ship a module built that way.

### Open questions

- Add one of the fallback entry methods (power-cycle plus `mcuboot-recovery-wait.conf`, or nRESET/boot pin wiring)?
  Needs a decision on what the Pi can control.
- Accept dev-key UART variants being absent from releases until the secrets exist, or fall back to a non-MCUboot build?
- Is a fixed 115200 recovery rate acceptable, or should it follow the application baud (matrix field `mcuboot_baud`)?
- Does the deployed otbr-agent have `OT_PLATFORM_BOOTLOADER_MODE`? If yes the Python frame can be dropped in favour of
  `ot-ctl reset bootloader`.

---

## Option 1 implementation: 1200-baud touch (dongle only)

Status: implemented, **unbuilt and untested on hardware** (no NCS toolchain was available; the GitHub CI run does the real
build). Sources checked: sdk-nrf `v3.4.1`, sdk-zephyr `ncs-v3.4.1`, sdk-hal_nordic at the revision pinned in NCS west.yml.

### How it works

- Code: `app-extensions/dongle-dfu/` (a Zephyr out-of-tree module: `zephyr/module.yml`, `CMakeLists.txt`, `Kconfig`,
  `src/dongle_dfu.c`). The NCS sample is untouched.
- CI adds it for the dongle matrix entry only, via `-Dcoprocessor_ZEPHYR_EXTRA_MODULES=<repo>/app-extensions/dongle-dfu`
  (sysbuild forwards `<image>_<var>` cache variables to the image; the image is named `coprocessor`, matching
  `build/coprocessor/` in the workflow).
- A 20 ms `k_timer` polls the Spinel CDC ACM device (`zephyr,ot-uart`, set by the sample's dongle overlay) with
  `uart_line_ctrl_get()` for `UART_LINE_CTRL_BAUD_RATE` and `UART_LINE_CTRL_DTR`. If the baud rate is 1200 and DTR is low for
  3 consecutive polls (60 ms), it writes `0xB1` to `GPREGRET[0]` (`nrf_power_gpregret_set(NRF_POWER, 0, 0xB1)`) and calls
  `sys_reboot(SYS_REBOOT_WARM)`. Kconfig: `DONGLE_DFU_TOUCH` (default y, module only present on the dongle),
  `DONGLE_DFU_TOUCH_BAUD` (1200), `DONGLE_DFU_GPREGRET_MAGIC` (0xB1).

### Evidence from the NCS v3.4.1 sources

- Stack: `boards/nrf52840dongle_nrf52840.conf` of the sample sets `CONFIG_USB_DEVICE_STACK_NEXT=y`, VID/PID `0x1915:0x0000`,
  `CONFIG_UART_LINE_CTRL=y`. The USB context is created by `subsys/usb/device_next/app/cdc_acm_serial.c`
  (`USBD_DEVICE_DEFINE(cdc_acm_serial, ...)`, `CDC_ACM_SERIAL_INITIALIZE_AT_BOOT`). It registers no message callback, but
  the context is a private `static` object, so our code cannot call `usbd_msg_register_cb()` on it (`usbd_msg_register_cb`
  also returns `-EALREADY` if a callback exists). The stack does publish `USBD_MSG_CDC_ACM_LINE_CODING` and
  `USBD_MSG_CDC_ACM_CONTROL_LINE_STATE` from `usbd_cdc_acm.c` (`usbd_cdc_acm_ctd`), but only to that callback.
- Polling instead: `usbd_cdc_acm.c` `cdc_acm_line_ctrl_get()` returns `uart_cfg.baudrate` (updated on `SET_LINE_CODING`) and
  `line_state_dtr` (updated on `SET_CONTROL_LINE_STATE`). The default line coding is 115200
  (`CDC_ACM_DEFAULT_LINECODING`). The host's baud stays latched after the port is closed, so a very fast open/close (the
  README's one-line pyserial snippet) is still seen, which an "armed on DTR high" design would miss at a 20 ms poll.
- otbr-agent collision: OpenThread `src/posix/platform/hdlc_interface.cpp` (main) defaults to **460800** baud, accepts only
  9600 and up (no 1200), and with flow control off it **deasserts DTR and RTS** right after open (`TIOCMBIC`). So DTR low is
  normal during operation and must not be a trigger on its own; the baud rate 1200 is the discriminator. Checked on
  OpenThread main, not on the exact OTBR build on the Pi **(verify: `ps` the otbr-agent URL, `uart-baudrate` must not be 1200)**.
- `CONFIG_OPENTHREAD_PLATFORM_BOOTLOADER_MODE_GPIO` (`modules/openthread/platform/misc.c`): `otPlatResetToBootloader()` drives
  `bootloader-gpios` (sample overlay: `&gpio0 19`, comment says P0.19 is wired to reset on Nordic's dongle) active and
  returns, relying on a pin reset to enter the bootloader. It is a Kconfig `choice` with `..._BOOTLOADER_MODE_RETENTION`.
  Retention mode would write `BOOT_MODE_TYPE_BOOTLOADER` = **0x01** via `bootmode_set()` (`subsys/retention/bootmode.c`,
  needs `zephyr,boot-mode` in devicetree, which the dongle board does not define), not 0xB1, so it cannot enter Nordic's
  bootloader. Our code uses neither: it writes GPREGRET directly and reboots, so there is **no conflict** with the GPIO mode
  (they remain independent; Spinel reset-to-bootloader keeps using the pin). Nothing in the GPIO path or
  `otPlatReset()` (`sys_reboot(SYS_REBOOT_WARM)`) touches GPREGRET.
- API: `nrf_power_gpregret_set(NRF_POWER_Type *, uint32_t reg_num, uint32_t val)` in
  `modules/hal/nordic/nrfx/hal/nrf_power.h` (verified present, guarded by `NRF_POWER_HAS_GPREGRET`).
- Flash layout agrees with a Nordic MBR plus bootloader dongle: `nrf52840dongle_nrf52840.dts` says "Flash partition table
  compatible with the onboard USB bootloader", app after the MBR at 0x1000 (`FLASH_LOAD_OFFSET`), bootloader at
  `0xe0000`.

### Which bootloader does the dongle have? Not settled

No public source found that states it for the Holyiot unit (vendor page 403, third-party manual only mentions nRF Connect
Programmer / USB DFU). Nordic's own dongle ships the nRF5 SDK open USB DFU bootloader, entered with `GPREGRET = 0xB1`
(`BOOTLOADER_DFU_START = BOOTLOADER_DFU_GPREGRET 0xB0 | start bit 0x01`, nRF5 SDK `nrf_bootloader_info.h`, per Nordic docs
and DevZone; I did not read the header itself). The Holyiot likely clones it, **unconfirmed**. A UF2 or Adafruit
bootloader (different magic values, e.g. 0x57 for UF2) would ignore 0xB1.

### Manual test procedure

1. Confirm the bootloader first, with the stock firmware: press the reset button, then `lsusb` (Linux) or Device Manager.
   Nordic open bootloader enumerates as `1915:521f` ("Open DFU Bootloader", CDC ACM) with a pulsing red LED, and
   `nrfutil` (below) can talk to it. A mass-storage drive (UF2) or a different VID:PID means this feature will not work.
2. Flash the CI `dfu_application.zip` (dongle) once via the reset button, confirm the RCP runs: `lsusb` shows `1915:0000`
   "Thread Co-Processor".
3. Stop otbr-agent, then touch: `python3 -c "import serial; serial.Serial('/dev/ttyACM0', 1200).close()"`.
4. Expected within ~1 s: `/dev/ttyACM0` disappears, `lsusb` shows `1915:521f`, LED pulses red.
5. `nrfutil dfu usb-serial -pkg dfu_application.zip -p /dev/ttyACM0` (nrfutil 6.x), expected output a progress bar and
   `Device programmed.`; the dongle then re-enumerates as `1915:0000`.
6. Negative test: start otbr-agent against the RCP for a few minutes (and stop/restart it): the dongle must not reboot.

### HOST CONTRACT (for the script agent)

- Trigger: with otbr-agent stopped and the port free, open the dongle's CDC ACM tty (the `1915:0000` device, the Spinel
  port, e.g. `/dev/ttyACM0`) at **exactly 1200 baud, 8N1**, hold it open for at least 100 ms (not required by the firmware,
  but avoids host-stack races), then close it so DTR drops. Python: `serial.Serial(port, 1200)`, `time.sleep(0.1)`,
  `.close()`. No special DTR/RTS toggling is needed beyond the normal open and close; the firmware reacts after the
  baud rate is 1200 and DTR has been low for 60 ms.
- Re-enumeration: the old device must disappear and a USB device **`1915:521f`** (Nordic Open DFU Bootloader; assumed from
  Nordic's dongle, **verify on the Holyiot**) appears, typically a new `/dev/ttyACM*` number. Poll for up to 10 s
  (suggested), for example by VID:PID via `/dev/serial/by-id` or udev; do not assume the same tty name. If the VID:PID
  does not change within the timeout, the touch failed (bootloader ignored the magic): exit "bootloader entry failed".
- Update 2026-10-21: the legacy Python nrfutil 6.1.x does not install on current Raspberry Pi OS; update-tools uses the new
  nrfutil with `nrf5sdk-tools` (`nrfutil nrf5sdk-tools dfu usb-serial ...`), and the release asset is
  `rcp-holyiot-nrf52840-dongle-usb-dfutouch-dfu.zip` (with `.sha256`). The text below is the original contract.
- Flash: nrfutil. README previously documented the legacy Python nrfutil 6.1.x (`pip install nrfutil`):
  `nrfutil dfu usb-serial -pkg dfu_application.zip -p <new tty> [-b 115200]`. CI creates the zip with the new
  Rust nrfutil (`nrfutil nrf5sdk-tools pkg generate`); the new tool's flashing syntax
  (`nrfutil nrf5sdk-tools dfu usb-serial ...` or `nrfutil device`) was **not verified** here, so the script should pin one
  and check its `--help`.
- Exit behaviour: nrfutil exits 0 on success and the dongle reboots into the new application and re-enumerates as
  `1915:0000` (wait up to ~10 s, then verify with a Spinel version query). Non-zero is a failed flash; the dongle stays in
  the bootloader (red pulsing), so a retry works without touching the button.

### Known risks

- If the shipped bootloader ignores `0xB1`, the dongle just reboots once into the application again (the baud rate is back
  at 115200 after the reboot, so there is no reboot loop) and the reset button is still required.
- Unverified on hardware: whether the nRF5 bootloader clears GPREGRET and which register it checks on this build
  (register 0 assumed); that the first timer expiry after boot does not misfire (baud defaults to 115200, so it should not).
- Unbuilt: `-Dcoprocessor_ZEPHYR_EXTRA_MODULES` forwarding through sysbuild is from NCS documentation/behaviour, not
  traced in the build; if the module is not picked up the symbol `DONGLE_DFU_TOUCH` is absent from `build/coprocessor/zephyr/.config`.
  Fallback: `-DZEPHYR_EXTRA_MODULES` via `west build` (without sysbuild prefix), or `SB_CONFIG` plumbing.
- A host that legitimately opens the port at 1200 baud will reboot the dongle. Do not use that baud for Spinel.
- Fallback if this fails: Option 2 (Spinel reset-to-bootloader). The sample's GPIO mode only works if P0.19 resets the
  Holyiot board.

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

*Status: done (config only, unbuilt). Results are in "Implementation: MCUboot serial recovery for E73 and Ezurio"; the deviations from this prompt (fixed 115200 recovery without flow control, overwrite-only mode) are explained there.*

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
