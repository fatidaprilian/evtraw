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

# 3. System Properties for Native Resampling Bypass, Idle Prevention & Conditional SurfaceFlinger Pacing
SDK_VER=$(getprop ro.build.version.sdk)

if command -v resetprop >/dev/null 2>&1; then
    resetprop -n ro.input.resampling 0
    resetprop -n ro.vendor.display.touch.idle.enable false
    resetprop -n debug.sf.enable_gl_backpressure 0
    if [ -n "$SDK_VER" ] && [ "$SDK_VER" -ge 33 ]; then
        # Android 13/14+ official safe auto-latch
        resetprop -n debug.sf.auto_latch_unsignaled true
        log -p i -t EvtRaw "SurfaceFlinger: Android $SDK_VER detected -> auto_latch_unsignaled enabled"
    else
        # Android 12 or below: prevent freeze by disabling latch_unsignaled
        resetprop -n debug.sf.latch_unsignaled 0
        resetprop -n debug.sf.auto_latch_unsignaled false
        log -p i -t EvtRaw "SurfaceFlinger: Android $SDK_VER detected -> pure Double Buffering active (anti-freeze safe)"
    fi
else
    setprop debug.sf.enable_gl_backpressure 0 2>/dev/null || true
    if [ -n "$SDK_VER" ] && [ "$SDK_VER" -ge 33 ]; then
        setprop debug.sf.auto_latch_unsignaled true 2>/dev/null || true
    else
        setprop debug.sf.latch_unsignaled 0 2>/dev/null || true
        setprop debug.sf.auto_latch_unsignaled false 2>/dev/null || true
    fi
    log -p w -t EvtRaw "resetprop unavailable; ro.* properties applied via system.prop" 2>/dev/null || true
fi

# 4. Direct Hardware Driver Configuration (FocalTech 360Hz & Palm Sensor Bypass)
for bump_node in \
    /sys/class/touch/touch_dev/bump_sample_rate \
    /sys/devices/virtual/touch/touch_dev/bump_sample_rate; do
    if [ -f "$bump_node" ]; then
        echo 1 > "$bump_node" 2>/dev/null || true
    fi
done

for palm_node in \
    /sys/class/touch/touch_dev/palm_sensor \
    /sys/devices/virtual/touch/touch_dev/palm_sensor; do
    if [ -f "$palm_node" ]; then
        echo 0 > "$palm_node" 2>/dev/null || true
    fi
done

# 5. Real-Time Scheduler Priority for system_server Input Threads (SCHED_FIFO 98)
SERVER_PID=$(pidof system_server)
if [ -n "$SERVER_PID" ]; then
    for tid in $(ps -T -p "$SERVER_PID" -o TID,CMDLINE 2>/dev/null | grep -E "InputReader|InputDispatcher" | awk '{print $1}'); do
        chrt -f -p 98 "$tid" 2>/dev/null || true
        echo "$tid" > /dev/cpuset/top-app/tasks 2>/dev/null || true
    done
    log -p i -t EvtRaw "Real-time SCHED_FIFO 98 applied to InputReader & InputDispatcher"
fi

# 6. Retry companion app install if it was deferred during module installation
if [ -f "$MODDIR/.apk_pending" ]; then
    for apk_file in evtraw.apk RTIapp.apk; do
        if [ -f "$MODDIR/$apk_file" ]; then
            case "$apk_file" in
                RTIapp.apk) target_pkg="com.rti.idc" ;;
                *) target_pkg="fatidaprilian.evtraw" ;;
            esac

            install_out=$(pm install --user 0 -r "$MODDIR/$apk_file" 2>&1 || pm install -r "$MODDIR/$apk_file" 2>&1)
            if echo "$install_out" | grep -q "Success"; then
                log -p i -t EvtRaw "Companion app ($apk_file) installed (boot retry)."
                rm -f "$MODDIR/.apk_pending" "$MODDIR/$apk_file"
                break
            elif echo "$install_out" | grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE"; then
                # Clean reinstall only on explicit signature conflict
                pm uninstall "$target_pkg" >/dev/null 2>&1 || pm uninstall --user 0 "$target_pkg" >/dev/null 2>&1
                reinstall_out=$(pm install --user 0 -r "$MODDIR/$apk_file" 2>&1 || pm install -r "$MODDIR/$apk_file" 2>&1)
                if echo "$reinstall_out" | grep -q "Success"; then
                    log -p i -t EvtRaw "Companion app ($apk_file) reinstalled cleanly after resolving conflict."
                    rm -f "$MODDIR/.apk_pending" "$MODDIR/$apk_file"
                    break
                else
                    log -p e -t EvtRaw "Companion app ($apk_file) reinstall failed: $reinstall_out; will retry next boot."
                fi
            else
                log -p w -t EvtRaw "Companion app ($apk_file) install deferred: $install_out; will retry next boot."
            fi
        fi
    done
fi

# 7. Dynamic Game-Scoped PM QoS Daemon (0us CPU latency strictly when games are active)
start_pm_qos_daemon() {
    (
        exec 2>/dev/null
        QOS_HELD=0

        while true; do
            sleep 2
            IS_GAME=0
            ACTIVE_NAME=""

            # Layer 1: WindowManager focus (100% authoritative for active foreground window)
            FOCUS_LINE=$(dumpsys window 2>/dev/null | grep -m 1 -E "mCurrentFocus|mFocusedApp")
            if [ -n "$FOCUS_LINE" ]; then
                if echo "$FOCUS_LINE" | grep -qiE "game|pubg|codm|freefire|genshin|honkai|mobile.*legends|unity|epicgames|riotgames|roblox"; then
                    IS_GAME=1
                    ACTIVE_NAME=$(echo "$FOCUS_LINE" | grep -oE '[a-zA-Z0-9._]+/[a-zA-Z0-9._]+' | head -n 1)
                fi
            fi

            # Layer 2: Kernel cpuset top-app fallback
            if [ "$IS_GAME" = "0" ]; then
                for pid in $(cat /dev/cpuset/top-app/cgroup.procs 2>/dev/null); do
                    if [ -d "/proc/$pid" ]; then
                        PKG=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | awk '{print $1}')
                        if echo "$PKG" | grep -qiE "game|pubg|codm|freefire|genshin|honkai|mobile.*legends|unity|epicgames|riotgames|roblox"; then
                            IS_GAME=1
                            ACTIVE_NAME="$PKG"
                            break
                        fi
                    fi
                done
            fi

            if [ "$IS_GAME" = "1" ]; then
                if [ "$QOS_HELD" = "0" ] && [ -c "/dev/cpu_dma_latency" ]; then
                    exec 3>/dev/cpu_dma_latency
                    printf '\x00\x00\x00\x00' >&3
                    QOS_HELD=1
                    log -p i -t EvtRaw "PM QoS CPU latency lock (0us) ACTIVE for: $ACTIVE_NAME"
                fi
            else
                if [ "$QOS_HELD" = "1" ]; then
                    exec 3>&- 2>/dev/null || true
                    QOS_HELD=0
                    log -p i -t EvtRaw "PM QoS CPU latency lock RELEASED"
                fi
            fi
        done
    ) &
}

start_pm_qos_daemon

log -p i -t EvtRaw "EvtRaw applied successfully"
