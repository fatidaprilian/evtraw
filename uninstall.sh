#!/system/bin/sh

MODDIR=${0%/*}

# Kill PM QoS daemon if still running (prevents orphan on mid-session disable)
if [ -f "$MODDIR/.daemon_pid" ]; then
    kill "$(cat "$MODDIR/.daemon_pid")" 2>/dev/null
    rm -f "$MODDIR/.daemon_pid"
fi

# Restore palm sensor default heuristic
echo 1 > /sys/class/touch/touch_dev/palm_sensor 2>/dev/null || true
echo 1 > /sys/devices/virtual/touch/touch_dev/palm_sensor 2>/dev/null || true

# Revert EAS/UCLAMP scheduler hints to AOSP defaults (volatile, reset on reboot anyway)
echo 0 > /dev/stune/top-app/schedtune.boost 2>/dev/null || true
echo 0 > /dev/stune/top-app/schedtune.prefer_idle 2>/dev/null || true
echo 0 > /dev/cpuctl/top-app/cpu.uclamp.min 2>/dev/null || true
echo 0 > /dev/cpuctl/top-app/cpu.uclamp.latency_sensitive 2>/dev/null || true

# Clean up EvtRaw properties
resetprop --delete ro.vendor.display.touch.idle.enable 2>/dev/null
resetprop --delete debug.sf.auto_latch_unsignaled 2>/dev/null
resetprop --delete debug.sf.latch_unsignaled 2>/dev/null

pm uninstall fatidaprilian.evtraw >/dev/null 2>&1
pm uninstall --user 0 fatidaprilian.evtraw >/dev/null 2>&1
pm uninstall com.rti.idc >/dev/null 2>&1
pm uninstall --user 0 com.rti.idc >/dev/null 2>&1

exit 0
