# dongle: Holyiot nRF52840 USB dongle updater

`update-dongle.sh` = Spinel reset-to-bootloader -> Nordic USB DFU bootloader (`1915:521f`) -> nrfutil -> wait for
the radio. Self-contained: needs this folder, a serial helper (`rcp-update` binary next to the script, or `python3` +
`rcp_spinel.py`), nRF Util with the `device` command (`nrfutil install device`; on x86-64 `nrf5sdk-tools` also works),
`curl` for `--release`, and systemd/otbr-agent.

```bash
sudo ./update-dongle.sh --dry-run --port /dev/serial/by-id/usb-...-if00 --release <tag>
sudo ./update-dongle.sh           --port /dev/serial/by-id/usb-...-if00 --release <tag>
```

`--release` fetches `rcp-holyiot-nrf52840-dongle-usb-legacyusb-dfu.zip` (+ `.sha256`). Use `--skip-entry` if the
dongle is already in the bootloader (e.g. after a failed flash, or the reset button). Verified on hardware step by
step (Spinel reset, `nrfutil device program`); the script has not been run end to end on hardware yet. Full
documentation, udev rules, troubleshooting and safety notes: `../README.md` (update-tools).
