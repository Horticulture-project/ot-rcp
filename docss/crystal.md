# External Crystals on nRF52 / nRF54L Modules Used as an OpenThread RCP

*Context: nRF52/nRF54L module running the NCS (nRF Connect SDK) 3.4.1 RCP firmware behind OTBR-posix. Sources checked: sdk-nrf `v3.4.1`, sdk-zephyr `ncs-v3.4.1`, sdk-nrfxlib `v3.4.1` and OpenThread. Checked 2026-10-20.*

## Summary

| Crystal | Needed? | Why |
|---|---|---|
| **32 MHz (HFXO)** | **Required** | The 802.15.4 radio only runs from the external 32 MHz crystal on both nRF52 and nRF54L. The internal 32 MHz oscillator is far too imprecise for the 2.4 GHz carrier. Every module includes this crystal. |
| **32.768 kHz (LFXO)** | **Optional, but recommended in one important case** | It matters when the border router is a parent to **sleepy end devices that use CSL** (coordinated sampled listening; "SSED" children), or when the RCP also runs Bluetooth LE. It hardly matters for an RCP that only serves routers, MEDs and polling SEDs. |

## What the 32.768 kHz clock affects on an RCP

On an RCP, the 32.768 kHz clock drives the 802.15.4 radio driver's timer, which schedules timed transmissions and receptions. Its accuracy affects three things.

### 1. Battery life of CSL children (the main effect)

The parent advertises its clock accuracy to its children. Each child widens its receive window by:

```
elapsed × (child accuracy + parent accuracy) + uncertainties
```

This is in OpenThread `src/core/mac/sub_mac_csl_receiver.cpp`:

```cpp
semiWindow = elapsed * (Get<Radio>().GetCslAccuracy() + mCslParentAccuracy.GetClockAccuracy()) / 1000000;
semiWindow += mCslParentAccuracy.GetUncertaintyInMicrosec() + Get<Radio>().GetCslUncertainty() * 10;
```

Example with 60 s since the last sync and a child clock accuracy of 20 ppm:

| Parent's 32 kHz source (accuracy) | Child's receive window per CSL sample |
|---|---|
| Crystal (~20 ppm) | about ±2.4 ms |
| Calibrated RC (250 ppm, Zephyr's default for nRF54) | about ±16 ms |
| RC (500 ppm, Zephyr's default for nRF52) | about ±31 ms |

That is roughly **7–13 times more radio-on time for every sleepy child, on every wake-up**. The window is capped at half the CSL period.

### 2. Precision of CSL transmissions to children

The RCP has to hit each child's sample time. The parent's drift adds to the child's drift.

### 3. Multiprotocol RCP with Bluetooth LE

This applies to the NCS RCP + HCI variant (`samples/openthread/coprocessor/extra_conf/rcp_hci.conf`). Nordic's multiprotocol layer (MPSL) then uses the 32.768 kHz clock for BLE sleep-clock accuracy, which allows up to 500 ppm. With the RC oscillator it needs periodic calibration: recommended every 4 s, at least every 8 s, and more often when the temperature changes (`nrfxlib/mpsl/include/mpsl_clock.h`).

## A configuration trap if you leave out the 32.768 kHz crystal

In NCS 3.4.1, the clock accuracy the RCP reports to OpenThread (`otPlatRadioGetCslAccuracy()` in `modules/openthread/platform/radio_nrf5.c`) comes from `CONFIG_NRF5_DELAY_TRX_ACC`. That setting **defaults to 20 ppm whatever the actual clock source is** (except on the nRF52840 Dongle):

```kconfig
# sdk-nrf v3.4.1: modules/openthread/Kconfig.nrf5
config NRF5_DELAY_TRX_ACC
	int "Clock accuracy for delayed operations"
	default CLOCK_CONTROL_NRF_ACCURACY if BOARD_NRF52840DONGLE_NRF52840
	default 20
```

Nordic made this a separate setting on purpose. Commit `aec518c08d` ("Fix OpenThread CSL Accuracy") says it "must be configurable by users, depending on the used oscillators".

If you run on the RC oscillator and don't raise it, the RCP claims 20 ppm while drifting at 250–500 ppm. Children then open windows that are too narrow, and CSL frames get missed intermittently. That is hard to debug.

## Options without a 32.768 kHz crystal

The source is chosen with `CONFIG_CLOCK_CONTROL_NRF_SOURCE` and the accuracy with `CONFIG_CLOCK_CONTROL_NRF_ACCURACY_PPM` (sdk-zephyr `drivers/clock_control/Kconfig.nrf`).

| Source | Accuracy | Cost on an RCP | Notes |
|---|---|---|---|
| Crystal (`K32SRC_XTAL`, the Zephyr default) | Crystal spec, typically 20–50 ppm | Small BOM cost. nRF54L has internal load capacitors, so it's just the crystal. | Best for CSL parents and BLE |
| RC + calibration (`K32SRC_RC`) | Zephyr assumes 500 ppm on nRF52, 250 ppm otherwise | Periodic calibration. This needs the 32 MHz crystal, which the radio keeps running anyway. | Fine without SSED children. Set `NRF5_DELAY_TRX_ACC` to match. |
| Synthesized from 32 MHz (`K32SRC_SYNTH`) | Follows the 32 MHz crystal | Keeps the 32 MHz crystal running permanently | Attractive for an RCP (see below). MPSL supports it (`MPSL_CLOCK_LF_SRC_SYNTH`). |

A border-router RCP keeps its receiver on all the time, so the 32 MHz crystal is already running nearly always. That makes the synthesized option cheap. RC calibration overhead hardly matters either, since this is a mains-powered device with a receive current in the mA range.

> I haven't checked Nordic's 802.15.4 release notes for any limits on the synthesized source in Thread builds, so test it before relying on it.

## Recommendation

- **The border router will serve CSL sleepy end devices, or the RCP runs BLE too:** fit the 32.768 kHz crystal, or pick a module that has it. Set `CONFIG_NRF5_DELAY_TRX_ACC` to the real crystal spec, plus a margin for ageing and temperature.
- **The border router won't serve such devices:** you can leave out the 32.768 kHz crystal and use the synthesized source or calibrated RC. Set both `CONFIG_CLOCK_CONTROL_NRF_ACCURACY_PPM` and `CONFIG_NRF5_DELAY_TRX_ACC` honestly.
- **In both cases:** the 32 MHz crystal is required, and its accuracy determines whether the 802.15.4 carrier stays within the standard's frequency tolerance.

Example settings for an RCP without a 32.768 kHz crystal (adjust the numbers to the real accuracy):

```kconfig
# Option A: synthesized from the 32 MHz crystal
CONFIG_CLOCK_CONTROL_NRF_K32SRC_SYNTH=y
CONFIG_CLOCK_CONTROL_NRF_K32SRC_50PPM=y
CONFIG_NRF5_DELAY_TRX_ACC=50

# Option B: calibrated RC (nRF52)
CONFIG_CLOCK_CONTROL_NRF_K32SRC_RC=y
CONFIG_CLOCK_CONTROL_NRF_K32SRC_500PPM=y
CONFIG_NRF5_DELAY_TRX_ACC=500
```

## Caveats

- The 7–13× receive-window figures come from OpenThread's formula with the example values above. They show the scale of the effect; I haven't measured them on hardware.
- I haven't measured any of this on hardware. Validate with an SSED child (CSL) and check its current consumption and missed-frame counters with each clock configuration.

## Sources

- OpenThread `src/core/mac/sub_mac_csl_receiver.cpp`: CSL receive-window calculation
- sdk-nrf `v3.4.1`: `modules/openthread/Kconfig.nrf5` (`NRF5_DELAY_TRX_ACC`), `modules/openthread/platform/radio_nrf5.c` (`otPlatRadioGetCslAccuracy`), commit `aec518c08d`
- sdk-zephyr `ncs-v3.4.1`: `drivers/clock_control/Kconfig.nrf` (32.768 kHz clock source and accuracy choices)
- sdk-nrfxlib `v3.4.1`: `mpsl/include/mpsl_clock.h` (clock sources, RC calibration guidance)
