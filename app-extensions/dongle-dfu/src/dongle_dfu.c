/*
 * 1200-baud touch for the nRF52840 dongle's pre-flashed USB DFU bootloader.
 *
 * The USB device context of the CDC ACM serial backend is private to Zephyr's
 * cdc_acm_serial.c (static), so usbd_msg_register_cb() cannot be used. Instead the
 * CDC ACM device's line state is polled through the UART line control API:
 * uart_line_ctrl_get() returns the last baud rate set by the host (SET_LINE_CODING)
 * and the DTR bit (SET_CONTROL_LINE_STATE), see
 * subsys/usb/device_next/class/usbd_cdc_acm.c (cdc_acm_line_ctrl_get).
 *
 * Trigger: baud rate == 1200 AND DTR low, stable for a few polls. The baud rate stays
 * latched at 1200 after the host closes the port, so even a very fast open/close is
 * caught. otbr-agent sets 460800 by default (and never 1200), so this cannot match
 * during normal operation.
 */
#include <zephyr/kernel.h>
#include <zephyr/init.h>
#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/sys/reboot.h>
#include <hal/nrf_power.h>

#define POLL_MS      20
#define STABLE_POLLS 3

BUILD_ASSERT(DT_HAS_CHOSEN(zephyr_ot_uart),
	     "zephyr,ot-uart must be chosen (set by the sample's dongle overlay)");

static const struct device *const cdc_dev = DEVICE_DT_GET(DT_CHOSEN(zephyr_ot_uart));
static struct k_timer poll_timer;
static unsigned int hits;

static void poll_fn(struct k_timer *timer)
{
	uint32_t baud = 0;
	uint32_t dtr = 1;

	ARG_UNUSED(timer);

	if (!device_is_ready(cdc_dev) ||
	    uart_line_ctrl_get(cdc_dev, UART_LINE_CTRL_BAUD_RATE, &baud) != 0 ||
	    uart_line_ctrl_get(cdc_dev, UART_LINE_CTRL_DTR, &dtr) != 0) {
		hits = 0;
		return;
	}

	if (baud != CONFIG_DONGLE_DFU_TOUCH_BAUD || dtr != 0) {
		hits = 0;
		return;
	}

	if (++hits < STABLE_POLLS) {
		return;
	}

	(void)irq_lock();
	nrf_power_gpregret_set(NRF_POWER, 0, CONFIG_DONGLE_DFU_GPREGRET_MAGIC);
	sys_reboot(SYS_REBOOT_WARM);
}

static int dongle_dfu_init(void)
{
	k_timer_init(&poll_timer, poll_fn, NULL);
	k_timer_start(&poll_timer, K_MSEC(POLL_MS), K_MSEC(POLL_MS));
	return 0;
}

SYS_INIT(dongle_dfu_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
