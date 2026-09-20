#!/system/bin/sh
# EvtRaw Boot Service Script
# Applies kernel driver optimizations, IRQ affinity routing, and system tuning post-boot.

MODDIR=${0%/*}

until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done
sleep 10

log -p i -t EvtRaw "Starting EvtRaw (aarch64)..."

if [ "$(uname -m)" != "aarch64" ]; then
    log -p e -t EvtRaw "ERROR: Architecture $(uname -m) is not supported (aarch64 only)"
    exit 1
fi

# 1. Run driver controller binary for ioctl and kernel nodes
if [ -f "$MODDIR/bin/RTI--aarch64" ]; then
    chmod +x "$MODDIR/bin/RTI--aarch64"
    "$MODDIR/bin/RTI--aarch64"
fi

# 2. Dynamic IRQ Affinity Routing
# Identify touch digitizer interrupt (e.g. fts_ts on Poco F4)
TS_IRQ=$(grep -E 'fts_ts|xiaomi-touch' /proc/interrupts 2>/dev/null | head -n1 | awk '{print $1}' | tr -d ':')
if [ -n "$TS_IRQ" ] && [ -d "/proc/irq/$TS_IRQ" ]; then
    # Route touch interrupts to performance cluster (Cortex-A77 Gold/Prime cores 4-7, mask 0xf0)
    # If 0xf0 is rejected by kernel affinity restrictions, fallback to 0x70 or 0x30
    if echo "f0" > "/proc/irq/$TS_IRQ/smp_affinity" 2>/dev/null; then
        log -p i -t EvtRaw "Bound touch IRQ $TS_IRQ to performance cores (affinity 0xf0)"
    elif echo "70" > "/proc/irq/$TS_IRQ/smp_affinity" 2>/dev/null; then
        log -p i -t EvtRaw "Bound touch IRQ $TS_IRQ to Gold cores (affinity 0x70)"
    fi
fi

# 3. Energy-Aware Scheduler (EAS) Foreground Touch Responsiveness Tuning
# Ensure foreground touch threads are immediately assigned to idle high-performance cores
for boost_node in /dev/stune/top-app/schedtune.boost; do
    if [ -f "$boost_node" ]; then
        echo 10 > "$boost_node" 2>/dev/null || true
    fi
done

for prefer_idle_node in /dev/stune/top-app/schedtune.prefer_idle; do
    if [ -f "$prefer_idle_node" ]; then
        echo 1 > "$prefer_idle_node" 2>/dev/null || true
    fi
done

for uclamp_node in /dev/cpuctl/top-app/cpu.uclamp.min; do
    if [ -f "$uclamp_node" ]; then
        echo 20 > "$uclamp_node" 2>/dev/null || true
    fi
done

# 4. System Properties for Unthrottled Dispatch & Idle Prevention
if command -v resetprop >/dev/null 2>&1; then
    resetprop windowsmgr.max_events_per_sec 360
    resetprop ro.vendor.display.touch.idle.enable false
else
    setprop windowsmgr.max_events_per_sec 360
    setprop ro.vendor.display.touch.idle.enable false
fi

# 5. Direct Vendor Sysfs Fallback Writes
for node in \
    /sys/class/touch/touch_dev/bump_sample_rate \
    /sys/devices/virtual/touch/touch_dev/bump_sample_rate \
    /proc/touchpanel/game_switch_enable \
    /proc/tp_report_rate_switch \
    /proc/tp_edge_deadzone \
    /proc/tp_grip_suppress; do
    if [ -f "$node" ]; then
        echo 1 > "$node" 2>/dev/null || true
    fi
done

# 6. Retry companion app install if it was deferred during module installation
if [ -f "$MODDIR/.apk_pending" ] && [ -f "$MODDIR/RTIapp.apk" ]; then
    if pm install --user 0 -r "$MODDIR/RTIapp.apk" >/dev/null 2>&1 || \
       pm install -r "$MODDIR/RTIapp.apk" >/dev/null 2>&1; then
        log -p i -t EvtRaw "Companion app installed (boot retry)."
        rm -f "$MODDIR/.apk_pending" "$MODDIR/RTIapp.apk"
    else
        log -p e -t EvtRaw "Companion app install still failing; will retry next boot."
    fi
fi

log -p i -t EvtRaw "EvtRaw applied successfully"
