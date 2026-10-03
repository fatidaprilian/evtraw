#!/system/bin/sh

# Restore palm sensor default heuristic
echo 1 > /sys/class/touch/touch_dev/palm_sensor 2>/dev/null || true
echo 1 > /sys/devices/virtual/touch/touch_dev/palm_sensor 2>/dev/null || true

# Clean up EvtRaw properties
resetprop --delete ro.vendor.display.touch.idle.enable 2>/dev/null
resetprop --delete debug.sf.auto_latch_unsignaled 2>/dev/null
resetprop --delete debug.sf.latch_unsignaled 2>/dev/null

pm uninstall fatidaprilian.evtraw >/dev/null 2>&1
pm uninstall --user 0 fatidaprilian.evtraw >/dev/null 2>&1
pm uninstall com.rti.idc >/dev/null 2>&1
pm uninstall --user 0 com.rti.idc >/dev/null 2>&1

exit 0
