# Out-of-tree Zephyr module: 1200-baud touch -> reboot into the dongle's USB DFU bootloader.
# Added to the NCS coprocessor sample only for nrf52840dongle/nrf52840 (see .github/workflows/build-rcp.yml).
if(CONFIG_DONGLE_DFU_TOUCH)
  zephyr_library()
  zephyr_library_sources(src/dongle_dfu.c)
endif()
