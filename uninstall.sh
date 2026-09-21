#!/system/bin/sh
settings delete secure long_press_timeout 2>/dev/null
settings delete secure multi_press_timeout 2>/dev/null

# Restore palm sensor default heuristic (bump_sample_rate deliberately left intact per configuration)
echo 1 > /sys/class/touch/touch_dev/palm_sensor 2>/dev/null || true
echo 1 > /sys/devices/virtual/touch/touch_dev/palm_sensor 2>/dev/null || true

# Clean up EvtRaw system properties
resetprop --delete ro.input.resampling 2>/dev/null
resetprop --delete ro.vendor.display.touch.idle.enable 2>/dev/null
resetprop --delete ro.surface_flinger.max_frame_buffer_acquired_buffers 2>/dev/null
resetprop --delete debug.sf.early_phase_offset_ns 2>/dev/null
resetprop --delete debug.sf.early_app_phase_offset_ns 2>/dev/null
resetprop --delete debug.sf.early_gl_phase_offset_ns 2>/dev/null
resetprop --delete debug.sf.early_gl_app_phase_offset_ns 2>/dev/null
resetprop --delete debug.sf.high_fps_early_phase_offset_ns 2>/dev/null
resetprop --delete debug.sf.high_fps_early_gl_phase_offset_ns 2>/dev/null
resetprop --delete debug.sf.auto_latch_unsignaled 2>/dev/null
resetprop --delete debug.sf.latch_unsignaled 2>/dev/null
resetprop --delete debug.sf.enable_gl_backpressure 2>/dev/null

pm uninstall fatidaprilian.evtraw >/dev/null 2>&1
pm uninstall --user 0 fatidaprilian.evtraw >/dev/null 2>&1
pm uninstall com.rti.idc >/dev/null 2>&1
pm uninstall --user 0 com.rti.idc >/dev/null 2>&1

exit 0
