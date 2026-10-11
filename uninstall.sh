#!/system/bin/sh

MODDIR=${0%/*}

# Restore palm sensor default heuristic
echo 1 > /sys/class/touch/touch_dev/palm_sensor 2>/dev/null || true
echo 1 > /sys/devices/virtual/touch/touch_dev/palm_sensor 2>/dev/null || true

# Clean up EvtRaw properties
resetprop --delete ro.vendor.display.touch.idle.enable 2>/dev/null
resetprop --delete debug.sf.auto_latch_unsignaled 2>/dev/null
resetprop --delete debug.sf.latch_unsignaled 2>/dev/null

# 1. Immediate companion app uninstallation
pm uninstall fatidaprilian.evtraw >/dev/null 2>&1
pm uninstall --user 0 fatidaprilian.evtraw >/dev/null 2>&1
pm uninstall com.rti.idc >/dev/null 2>&1
pm uninstall --user 0 com.rti.idc >/dev/null 2>&1

# 2. Deferred companion app uninstallation
# Handles scenarios where uninstall.sh is invoked during boot before PackageManagerService is ready
CLEANUP_SCRIPT="/data/adb/service.d/evtraw_cleanup.sh"
if [ -d "/data/adb/service.d" ]; then
    cat <<'EOF' > "$CLEANUP_SCRIPT"
#!/system/bin/sh
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done
sleep 3
pm uninstall fatidaprilian.evtraw >/dev/null 2>&1
pm uninstall --user 0 fatidaprilian.evtraw >/dev/null 2>&1
pm uninstall com.rti.idc >/dev/null 2>&1
pm uninstall --user 0 com.rti.idc >/dev/null 2>&1
rm -f "$0"
EOF
    chmod 755 "$CLEANUP_SCRIPT"
fi

# 3. Detached subshell fallback for APatch / environments without service.d
(
    until [ "$(getprop sys.boot_completed)" = "1" ]; do
        sleep 2
    done
    sleep 3
    pm uninstall fatidaprilian.evtraw >/dev/null 2>&1
    pm uninstall --user 0 fatidaprilian.evtraw >/dev/null 2>&1
    pm uninstall com.rti.idc >/dev/null 2>&1
    pm uninstall --user 0 com.rti.idc >/dev/null 2>&1
) &

exit 0
