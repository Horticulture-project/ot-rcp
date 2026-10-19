# OpenThread RCP Firmware Project

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
| **Holyiot Dongle** | nRF52840 | USB (Virtual Serial / CDC ACM) | `nrf52840dongle_nrf52840` |
| **Ebyte E73** | nRF52840 | Physical UART (Pins Rx/Tx) | `nrf52840dk_nrf52840` |
| **Ezurio Module** | nRF54L15 | Physical UART (Pins Rx/Tx) | `sela_nrf54l15_cpuapp` |

---

## 🚀 CI/CD Pipeline (GitHub Actions)

Every time you push to the `main` branch or trigger the workflow manually via **Workflow Dispatch**, GitHub Actions compiles the firmware using Nordic's official NCS v3.4.1 Docker environment.

### Output Artifacts
The build produces a zip-archive containing:
* `zephyr.hex` / `zephyr.bin` – Raw binaries for hardware programmers (SWD).
* `dfu_application.zip` – OTA/USB update package specifically for the Holyiot DFU bootloader.

---

## ⚡ Flashing Instructions

### 1. Holyiot nRF52840 USB Dongle (USB DFU Bootloader)

This device features a pre-flashed USB bootloader. You do **not** need a hardware programmer.

#### 🍏 Programmatic Reset (No magnet needed!)
Instead of using a physical magnet or button to force DFU mode, you can trigger a software restart into the bootloader by toggling the serial port at **1200 baud**.

#### 🔸 From Raspberry Pi
1. Install the required tool: `pip install nrfutil`
2. Run the automated deployment sequence:
   ```bash
   # Stop the OTBR daemon to release the port
   sudo systemctl stop otbr-agent

   # Trigger DFU mode via 1200 baud trick
   python3 -c "import serial; serial.Serial('/dev/ttyACM0', 1200).close()"
   sleep 2

   # Flash the new zip package
   nrfutil dfu usb-serial -pkg dfu_application.zip -p /dev/ttyACM0 -b 115200

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
2. Create a flash configuration file named `flash.cfg`:
   ```text
   adapter driver sysfsgpio
   sysfsgpio_swd_nums 24 25
   transport select swd

   # Use target/nrf52.cfg for Ebyte or target/nrf54.cfg for Ezurio
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

1. Install the official [nRF Command Line Tools](https://nordicsemi.com).
2. Connect your debug probe to the target module's SWD pins and plug the probe into your computer via USB.
3. Open a Command Prompt or PowerShell terminal and flash the raw `.hex` file:
   ```cmd
   # For nRF52840 (Ebyte E73)
   nrfjprog --program zephyr.hex --chiperase --verify --reset

   # For nRF54L15 (Ezurio)
   nrfjprog --family NRF54L --program zephyr.hex --chiperase --verify --reset
   ```

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
| **TX out / RX in** | P1.11 (TX) | P2.02 (TX) | GPIO 15 (RXD0) | **Pin 10** |
| **RX in / TX out** | P1.10 (RX) | P2.00 (RX) | GPIO 14 (TXD0) | **Pin 8** |
| **RTS out / CTS in**| P1.08 (RTS)| P2.01 (RTS)| GPIO 16 (CTS0) | **Pin 36** |
| **CTS in / RTS out**| P1.07 (CTS)| P2.03 (CTS)| GPIO 17 (RTS0) | **Pin 11** |
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
   otbr-agent -I wpan0 spinel+hdlc+uart:///dev/ttyAMA0?uart-baudrate=460800
   ```


[![Lint Code](https://github.com/Horticulture-project/ot-ncp/workflows/Lint%20Code%20Base/badge.svg)](https://github.com/marketplace/actions/super-linter)
[![Build FW for Particle Xenon](https://github.com/Horticulture-project/ot-ncp/workflows/BuildFirmware/badge.svg?step=Build%20FW%20for%20Particle_xenon)](https://github.com/Horticulture-project/Horticulture-LED-fw/actions)
[![Build FW for E73-Minimal](https://github.com/Horticulture-project/ot-ncp/workflows/BuildFirmware/badge.svg?step=Build%20FW%20for%20E73-Minimal)](https://github.com/Horticulture-project/Horticulture-LED-fw/actions)

