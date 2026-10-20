# dongle: Holyiot nRF52840 USB dongle updater

`update-dongle.sh` = 1200-baud touch -> USB DFU (nrfutil) -> wait for the radio. Self-contained: needs this folder,
a serial helper (`rcp-update` binary next to the script, or `python3` + `rcp_spinel.py`), `nrfutil` (new, with
`nrfutil install nrf5sdk-tools`), `curl` for `--release`, and systemd/otbr-agent.

```bash
sudo ./update-dongle.sh --dry-run --port /dev/serial/by-id/usb-...-if00 --release <tag>
sudo ./update-dongle.sh           --port /dev/serial/by-id/usb-...-if00 --release <tag>
```

Only the `rcp-holyiot-nrf52840-dongle-usb-dfutouch-dfu.zip` package contains the touch module. Not verified on
hardware. Full documentation, udev rules, troubleshooting and safety notes: `../README.md` (update-tools).
