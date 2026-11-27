//
// esp_log.h — STUB for compiling the tests ON THE HOST.
//
// multi.c and monitor.c include esp_log.h for their ESP_LOGD/W. On the host
// there is no ESP-IDF: this stub empties the macros so that the REAL MODULES
// (not a simplified copy of them) can be compiled and tested with gcc, without
// flashing anything.
//
// It lives in main/test/stub/ and NOT in an include dir of the component: the
// ESP-IDF build never sees it (main/CMakeLists.txt declares only "." and
// "include"), so it cannot shadow the real header.
//
#pragma once

#define ESP_LOGE(tag, ...) do { (void)(tag); } while (0)
#define ESP_LOGW(tag, ...) do { (void)(tag); } while (0)
#define ESP_LOGI(tag, ...) do { (void)(tag); } while (0)
#define ESP_LOGD(tag, ...) do { (void)(tag); } while (0)
#define ESP_LOGV(tag, ...) do { (void)(tag); } while (0)
