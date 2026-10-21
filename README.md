# OpenThread RCP Firmware Project

[![Build RCP](https://github.com/Horticulture-project/ot-ncp/actions/workflows/build-rcp.yml/badge.svg)](https://github.com/Horticulture-project/ot-ncp/actions/workflows/build-rcp.yml)

This project automates the compilation of **OpenThread 1.4 Radio Co-Processor (RCP)** firmware for multiple nRF-based wireless modules using GitHub Actions. It targets **nRF Connect SDK (NCS) v3.4.1 (LTS)** and provides optimized configurations for different deployment styles (USB CDC ACM vs. Physical UART).

---

## 💡 What is an OpenThread RCP?

In an **OpenThread Border Router (OTBR)** architecture, the responsibilities of the network stack are split into two parts:
1. **The Host (POSIX):** Runs the heavy network routing logic, IPv6 handling, and Matter application layers (typically on a Raspberry Pi or Linux gateway via `otbr-agent`).
2. **The RCP (Radio Co-Processor):** Runs only the time-critical IEEE 802.15.4 MAC and PHY layers directly on the wireless microchip (nRF SoC).

The Host and the RCP communicate over a serial link (UART or USB virtual COM port) using a standardized protocol called **Spinel**. This allows your Raspberry Pi to seamlessly talk to a low-power Thread mesh network through the connected hardware module.

---

## 🛠 Supported Hardware Matrix

| Hardware Module | SoC Family | Host Interface | Config Target |
| :--- | :--- | :--- | :--- |
| **Holyiot Dongle** | nRF52840 | USB (Virtual Serial / CDC ACM) | `nrf52840dongle/nrf52840` |
| **Ebyte E73** | nRF52840 | Physical UART (Pins Rx/Tx) | `nrf52840dk/nrf52840` |
| **Ezurio Module** | nRF54L15 | Physical UART (Pins Rx/Tx) | `nrf54l15dk/nrf54l15/cpuapp` (generic nRF54L15 + custom pin overlay) |

---

## 🚀 CI/CD Pipeline (GitHub Actions)

Every time you push to the `main` branch or trigger the workflow manually via **Workflow Dispatch**, GitHub Actions compiles the firmware using Nordic's official NCS v3.4.1 Docker environment.

### Releases
Pushes to `main` (or a manual run with **release** ticked) also publish a GitHub release tagged `ncs-<NCS version>_thread-<Thread version>_ot-<OpenThread SHA>`, for example `ncs-v3.4.1_thread-1.4_ot-0fe68ff`. The OpenThread SHA is read from the NCS workspace; the Thread version is set in the workflow's `THREAD_VERSION`. Re-running with the same versions updates the existing release's files.

### Holyiot dongle: external PA/LNA front-end
The Holyiot dongle has an external PA/LNA (RFX4201C-style, two control pins: CTX = P0.24, CRX = P0.22). All dongle builds therefore include [boards/nrf52840dongle_nrf52840-fem.overlay](boards/nrf52840dongle_nrf52840-fem.overlay) and [.conf](boards/nrf52840dongle_nrf52840-fem.conf), taken from the vendor's working NCS 3.1.0 configuration. Without it the radio does not drive the PA pins; an earlier build without it crashed Raspberry Pi 3 hosts once `otbr-agent` started the radio (suspected cause: PA left enabled, high current). These two pins are the stock dongle's UART RX and CTS, so a UART/NCP build on this dongle needs different pins.

### Output Artifacts
Each matrix entry uploads its own artifact (`rcp-<module>-<baud>baud-<flow|noflow>`, or `rcp-holyiot-nrf52840-dongle-usb`) with files named after it (`.hex`, `.bin`, and `-dfu.zip` for the dongle). Every board also has an update-capable variant with a suffix (`-dfutouch` for the dongle, `-mcuboot` for the UART modules); the plain builds keep their original names and behaviour:
* `zephyr.hex` / `zephyr.bin` – Raw binaries for hardware programmers (SWD).
* Ebyte E73 and Ezurio `-mcuboot` builds include MCUboot (serial recovery over the same UART pins): `rcp-<module>-<baud>baud-<flow|noflow>-mcuboot.hex` is the **merged hex (MCUboot + signed application)** for the one-time SWD flash, `...-mcuboot-update.bin` is the signed image for over-the-cable updates and `...-update.bin.sha256` its checksum. No raw `.bin` is published for these variants; the plain builds (no suffix) stay as before. Until a signing secret is configured these are signed with MCUboot's public development key; their file names contain `-DEVKEY` and they must not be shipped. Details: [docss/bootloader_and_update.md](docss/bootloader_and_update.md).
* `dfu_application.zip` – Holyiot dongle only: update package for the USB DFU bootloader (generated with `nrfutil pkg generate`).

Baud rate and hardware flow control are applied through a generated devicetree overlay (`current-speed` / `hw-flow-control`) on top of the pin overlays in [boards/](boards). RCP mode and the dongle's USB CDC ACM setup come from the NCS `coprocessor` sample itself.

---

## ⚡ Flashing Instructions

### 1. Holyiot nRF52840 USB Dongle (USB DFU Bootloader)

This device features a pre-flashed USB bootloader. You do **not** need a hardware programmer.

#### 🍏 Programmatic Reset (No magnet needed!)
Instead of using a physical magnet or button to force DFU mode, you can trigger a software restart into the bootloader by toggling the serial port at **1200 baud**.

> **Note:** the dongle build of this repo includes the 1200-baud touch ([app-extensions/dongle-dfu](app-extensions/dongle-dfu)): opening and closing the CDC port at exactly 1200 baud writes `0xB1` to GPREGRET and reboots into the bootloader (expect `1915:521f` in `lsusb`). This is untested on hardware and assumes the dongle's bootloader is Nordic's USB DFU bootloader; see [docss/bootloader_and_update.md](docss/bootloader_and_update.md). Stock firmware has no touch, and if the port does not reset, enter DFU mode with the dongle's reset button instead.

#### 🔸 From Raspberry Pi
1. Install [nRF Util](https://www.nordicsemi.com/Products/Development-tools/nrf-util) and its legacy DFU command: `nrfutil install nrf5sdk-tools` (the old `pip install nrfutil` package does not install on current Raspberry Pi OS). For a guided, verified update use the scripts in [update-tools/](update-tools/README.md).
2. Run the automated deployment sequence:
   ```bash
   # Stop the OTBR daemon to release the port
   sudo systemctl stop otbr-agent

   # Trigger DFU mode via 1200 baud trick
   python3 -c "import serial; serial.Serial('/dev/ttyACM0', 1200).close()"
   sleep 2

   # Flash the new zip package
   nrfutil nrf5sdk-tools dfu usb-serial -pkg rcp-holyiot-nrf52840-dongle-usb-dfutouch-dfu.zip -p /dev/ttyACM0 -b 115200

   # Restart the router agent
   sudo systemctl start otbr-agent
   ```

#### 🔸 From Windows
1. Download and install [nRF Connect for Desktop](https://nordicsemi.com).
2. Open the **Developer Device Manager** (or **Programmer**) app within the interface.
3. Plug in the dongle. If it does not appear in DFU mode, open an administrative PowerShell window and run:
   ```powershell
   $port = New-Object System.IO.Ports.SerialPort COM3, 1200
   $port.Open()
   $port.Close()
   ```
   *(Replace `COM3` with your actual device port number).*
4. Drag and drop the `dfu_application.zip` file into the Nordic Programmer GUI, select your target device, and click **Write**.

---

### 2. Ebyte E73 (nRF52840) & Ezurio (nRF54L15) via SWD

These bare modules do not expose a native USB interface for flashing and require direct **Serial Wire Debug (SWD)** connection lines.

> The first flash of a module must use the merged `rcp-<module>-...hex` (it contains MCUboot and puts the application at 0xC000 on the E73 and 0x10000 on the Ezurio). Use a full chip erase. Afterwards updates can go over the UART, see section 3.

#### 📌 Pin Mapping Diagram
Connect your programmer (or Raspberry Pi GPIO pins) to the modules as follows:

```text
 Raspberry Pi GPIO                 Target Module (Ebyte / Ezurio)
+-------------------+             +-------------------------------+
| Pin 1/17 (3.3V)   |------------>| VCC / VDD                     |
| Pin 6/9/14 (GND)  |------------>| GND                           |
| Pin 18 (GPIO 24)  |------------>| SWCLK                         |
| Pin 22 (GPIO 25)  |------------>| SWDIO                         |
+-------------------+             +-------------------------------+
```

#### 🔸 From Raspberry Pi (Using OpenOCD)
You can turn your Raspberry Pi's native GPIOs into a hardware debugger using **OpenOCD**.

1. Install OpenOCD: `sudo apt update && sudo apt install openocd -y`
   > Mainline OpenOCD has no nRF54L target. For the Ezurio (nRF54L15) use the Windows/`nrfutil` method below, or a Nordic-supported OpenOCD build.
2. Create a flash configuration file named `flash.cfg` (nRF52840 / Ebyte only):
   ```text
   # Pi 5 and newer kernels: use linuxgpiod (sysfsgpio is deprecated). Pi 5 gpiochip is 4, older Pis use 0.
   adapter driver linuxgpiod
   linuxgpiod_gpiochip 0
   linuxgpiod_swd_nums 24 25   # SWCLK=GPIO24, SWDIO=GPIO25 (verify option names for your OpenOCD version)
   transport select swd

   source [find target/nrf52.cfg]

   init
   halt
   program zephyr.hex verify reset exit
   ```
3. Execute the flash command:
   ```bash
   openocd -f flash.cfg
   ```

#### 🔸 From Windows (Using a Hardware Debugger)
To flash these boards from a Windows environment, you need an external hardware tool like a **J-Link**, an **Atmel-ICE**, or an **nRF52/nRF53/nRF54 Development Kit (DK)** used as a debug probe (via the *Debug OUT* header).

1. Install [nRF Util](https://www.nordicsemi.com/Products/Development-tools/nrf-util) with the `device` command (`nrfjprog` is legacy and does not fully support nRF54L).
2. Connect your debug probe to the target module's SWD pins and plug the probe into your computer via USB.
3. Open a Command Prompt or PowerShell terminal and flash the raw `.hex` file:
   ```cmd
   # Works for both nRF52840 (Ebyte E73) and nRF54L15 (Ezurio)
   nrfutil device program --firmware zephyr.hex --options chip_erase_mode=ERASE_ALL,verify=VERIFY_READ --traits jlink
   nrfutil device reset
   ```

### 3. Ebyte E73 & Ezurio: updating over the UART (MCUboot serial recovery)

**Not built or tested on hardware yet.** Outline (full procedure, exact commands, timeouts and failure modes in [docss/bootloader_and_update.md](docss/bootloader_and_update.md), section "HOST CONTRACT"):

1. `sudo systemctl stop otbr-agent`
2. Send the Spinel reset-to-bootloader frame `7E 81 01 03 BF BB 7E` at the application's baud rate (or `ot-ctl reset bootloader` if your otbr-agent was built with `OT_PLATFORM_BOOTLOADER_MODE=ON`). The module reboots into MCUboot.
3. MCUboot speaks MCUmgr/SMP at **115200 8N1, no flow control**, regardless of the application's baud rate. Probe with `mcumgr-client -s -d /dev/ttyAMA0 -b 115200 -t 2 echo ping`.
4. `mcumgr-client -d /dev/ttyAMA0 -t 10 -u 500 --nb-retry 8 upload rcp-<module>-...-update.bin --slot 2`, then `list`, `test <hash>` and `reset`.
5. `sudo systemctl start otbr-agent` and check `ot-ctl rcp version`.

There is no automatic rollback (the RCP has no MCUmgr server to confirm an image); keep the previous `-update.bin`. Signing keys are generated with `imgtool keygen` and stored as the GitHub secrets `MCUBOOT_SIGN_KEY_ECDSA_P256` (E73) and `MCUBOOT_SIGN_KEY_ED25519` (Ezurio); never commit them.

---

## 🎛 UART Pin Mapping & Flow Control

When operating at high baud rates (e.g., **460800 baud**), using hardware flow control (**RTS/CTS**) is highly recommended to prevent buffer overflows during high Thread network traffic periods (like Matter commissioning).

### 1. Pin Numbering Reference

#### 🔹 Ebyte E73 (nRF52840)
Zephyr counts absolute pin numbers across two ports: Port 0 (0-31) and Port 1 (32-47).
*   **TX:** Pin `43` -> `P1.11`
*   **RX:** Pin `42` -> `P1.10`
*   **RTS:** Pin `40` -> `P1.08`
*   **CTS:** Pin `39` -> `P1.07`

#### 🔹 Ezurio (nRF54L15)
The newer nRF54 architecture addresses ports directly in the Devicetree:
*   **TX:** `P2.02`
*   **RX:** `P2.00`
*   **RTS:** `P2.01`
*   **CTS:** `P2.03`

---

### 2. Wiring Matrix to Raspberry Pi (3B+, Zero 2W, 4, 5)

| Signal Direction | Ebyte Pin | Ezurio Pin | Raspberry Pi GPIO Pin | Pi Header Pin |
| :--- | :--- | :--- | :--- | :--- |
| **Module TX → Pi RX** | P1.11 (TX) | P2.02 (TX) | GPIO 15 (RXD0) | **Pin 10** |
| **Module RX ← Pi TX** | P1.10 (RX) | P2.00 (RX) | GPIO 14 (TXD0) | **Pin 8** |
| **Module RTS → Pi CTS**| P1.08 (RTS)| P2.01 (RTS)| GPIO 16 (CTS0) | **Pin 36** |
| **Module CTS ← Pi RTS**| P1.07 (CTS)| P2.03 (CTS)| GPIO 17 (RTS0) | **Pin 11** |
| **Common Ground**  | GND        | GND        | GND            | **Pin 6 / 9 / 14**|

*Note: Always remember to cross the lines! TX goes to RX, and RTS goes to CTS between the Pi and the target module.*

---

### 3. Activating RTS/CTS on Raspberry Pi OS

To enable hardware flow control on the primary PL011 UART controller of the Raspberry Pi, append the following modifications to your boot configuration:

1. Edit the config file: `sudo nano /boot/firmware/config.txt`
2. Add the appropriate line for your Pi generation at the bottom:

```text
# For Raspberry Pi 3B+, Zero 2W, and Pi 4:
dtoverlay=disable-bt
dtoverlay=uart0,ctsrts

# For Raspberry Pi 5:
dtoverlay=uart0-pi5,ctsrts
```
3. Reboot the Pi: `sudo reboot`
4. Update your `otbr-agent` execution parameters to match the chosen architecture:
   ```bash
   # Standard speed (No flow control)
   otbr-agent -I wpan0 spinel+hdlc+uart:///dev/ttyAMA0?uart-baudrate=115200

   # High speed (With Hardware Flow Control active)
   otbr-agent -I wpan0 "spinel+hdlc+uart:///dev/ttyAMA0?uart-baudrate=460800&uart-flow-control"
   ```
