/*
 * SPDX-License-Identifier: MIT
 */

#include <zephyr/device.h>
#include <zephyr/devicetree.h>
#include <zephyr/drivers/uart/cdc_acm.h>
#include <zephyr/init.h>
#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <zephyr/retention/bootmode.h>
#include <zephyr/sys/reboot.h>

LOG_MODULE_REGISTER(bootloader_on_1200_baud, CONFIG_ZMK_LOG_LEVEL);

#define TOUCH_BAUD 1200
// Lets the host's SET_LINE_CODING request complete before the device drops off the bus.
#define REBOOT_DELAY_MS 250

static void reboot_work_handler(struct k_work *work) { sys_reboot(SYS_REBOOT_WARM); }

static K_WORK_DELAYABLE_DEFINE(reboot_work, reboot_work_handler);

static void dte_rate_changed(const struct device *dev, uint32_t rate) {
    if (rate != TOUCH_BAUD || k_work_delayable_is_pending(&reboot_work)) {
        return;
    }

    int ret = bootmode_set(BOOT_MODE_TYPE_BOOTLOADER);
    if (ret < 0) {
        LOG_ERR("bootmode_set failed: %d", ret);
        return;
    }

    k_work_schedule(&reboot_work, K_MSEC(REBOOT_DELAY_MS));
}

#define REGISTER_RATE_CALLBACK(node_id)                                                            \
    do {                                                                                           \
        const struct device *dev = DEVICE_DT_GET(node_id);                                         \
        if (!device_is_ready(dev) || cdc_acm_dte_rate_callback_set(dev, dte_rate_changed) < 0) {   \
            LOG_WRN("%s: no 1200 baud touch", dev->name);                                          \
        }                                                                                          \
    } while (0);

static int bootloader_on_1200_baud_init(void) {
    DT_FOREACH_STATUS_OKAY(zephyr_cdc_acm_uart, REGISTER_RATE_CALLBACK)
    return 0;
}

SYS_INIT(bootloader_on_1200_baud_init, APPLICATION, CONFIG_APPLICATION_INIT_PRIORITY);
