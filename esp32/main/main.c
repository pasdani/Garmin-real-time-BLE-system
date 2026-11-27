//
// main.c — Entry point of the ESP32-CAM firmware (ESP-IDF v5.5, NimBLE stack).
//
// BLE peripheral for protocols v3, v4 (MULTI edge) and v5 (MONITOR): receives
// the chunks (header + payload) from the Garmin on the DATA characteristic,
// reassembles them, validates them and prints them on the console; it also
// logs to microSD. The protocol logic lives in src/ble.c (BLE module, core 0)
// and src/sd.c (logging, core 1). This file only initialises the subsystems.
//
#include "nvs_flash.h"
#include "esp_log.h"

#include "ble.h"
#include "sd.h"
#include "config.h"

static const char *TAG = "MAIN";

void app_main(void) {
    // NVS: required by the BLE stack for its keys.
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    }

    ble_init();          // NimBLE + GATT server (v3/v4/v5) + advertising
    sd_logger_start();   // microSD logging task (does not block if the card is missing)

    ESP_LOGI(TAG, "Firmware started: edge node %u (peripheral v3/v4/v5)",
             (unsigned)EDGE_NODE_ID);
}
