# uart-modules: Ebyte E73 and Ezurio nRF54L15 updater

`update-uart-module.sh --board e73|nrf54l15` = Spinel reset-to-bootloader -> MCUboot serial recovery with
`mcumgr-client` v0.1.0 (echo, list, upload --slot 2, test, reset) -> wait for the radio. Self-contained: this folder,
a serial helper (`rcp-update` binary or `python3` + `rcp_spinel.py`), `curl`, `unzip` (or python3), systemd/otbr-agent.

```bash
sudo ./update-uart-module.sh --install-tools-only      # downloads + sha256-verifies mcumgr-client into ./tools
sudo ./update-uart-module.sh --dry-run --board e73 --port /dev/ttyAMA0 --baud 115200 --release <tag>
sudo ./update-uart-module.sh           --board e73 --port /dev/ttyAMA0 --baud 115200 --release <tag>
```

Only `-mcuboot-update.bin` images work (plain builds are refused). Not verified on hardware. Full documentation, udev rules,
failure table, rollback and safety notes: `../README.md` (update-tools).
