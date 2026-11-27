idf_component_register(SRCS "main.c"
                            "src/ble.c"
                            "src/sd.c"
                            "src/multi.c"
                            "src/multi_log.c"
                            "src/monitor.c"
                            "src/monitor_log.c"
                       INCLUDE_DIRS "." "include"
                       REQUIRES nvs_flash bt esp_timer fatfs sdmmc esp_driver_sdmmc)

# -Wdouble-promotion: on the ESP32 (Xtensa LX6) the FPU is SINGLE precision
# and every double is emulated in software. The warning catches accidental
# promotions (a constant 0.5 instead of 0.5f, log() instead of logf()), the
# usual way a computation becomes 30x slower without anything reporting it.
#
# NOTE: printf/fprintf of a float is still promoted to double by the C
# standard (default argument promotion of varargs). That is unavoidable and
# intended, so the casts in the format calls are explicit; the warning keeps
# being useful where it matters, in the computation code.
target_compile_options(${COMPONENT_LIB} PRIVATE -Wdouble-promotion)
