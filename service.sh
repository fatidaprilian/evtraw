#!/system/bin/sh
# EvtRaw Boot Service Script
# Applies kernel driver optimizations and system tuning post-boot.

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

# 2. Energy-Aware Scheduler (EAS) Foreground Touch Responsiveness Tuning
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

# 3. System Properties for Native Resampling Bypass & Idle Prevention
if command -v resetprop >/dev/null 2>&1; then
    resetprop -n ro.input.resampling 0
    resetprop -n ro.vendor.display.touch.idle.enable false
else
    # Read-only properties (ro.*) cannot be modified via setprop at runtime;
    # on systems without resetprop, they are applied at boot via system.prop
    log -p w -t EvtRaw "resetprop unavailable; ro.input.resampling must be supplied by system.prop" 2>/dev/null || true
fi

# 4. Direct Vendor Sysfs Fallback Writes
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

# 5. Retry companion app install if it was deferred during module installation
if [ -f "$MODDIR/.apk_pending" ]; then
    for apk_file in evtraw.apk RTIapp.apk; do
        if [ -f "$MODDIR/$apk_file" ]; then
            if pm install --user 0 -r "$MODDIR/$apk_file" >/dev/null 2>&1 || \
               pm install -r "$MODDIR/$apk_file" >/dev/null 2>&1; then
                log -p i -t EvtRaw "Companion app ($apk_file) installed (boot retry)."
                rm -f "$MODDIR/.apk_pending" "$MODDIR/$apk_file"
                break
            else
                # Clean reinstall if failed due to signature conflict
                pm uninstall fatidaprilian.evtraw >/dev/null 2>&1 || pm uninstall --user 0 fatidaprilian.evtraw >/dev/null 2>&1
                if pm install --user 0 -r "$MODDIR/$apk_file" >/dev/null 2>&1 || \
                   pm install -r "$MODDIR/$apk_file" >/dev/null 2>&1; then
                    log -p i -t EvtRaw "Companion app ($apk_file) reinstalled cleanly after resolving conflict."
                    rm -f "$MODDIR/.apk_pending" "$MODDIR/$apk_file"
                    break
                else
                    log -p e -t EvtRaw "Companion app ($apk_file) install failed; will retry next boot."
                fi
            fi
        fi
    done
fi

log -p i -t EvtRaw "EvtRaw applied successfully"
