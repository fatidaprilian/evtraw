#!/system/bin/sh
# EvtRaw Boot Service Script
# Applies kernel driver optimizations and system tuning post-boot.

MODDIR=${0%/*}

until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done
sleep 10

log -p i -t EvtRaw "Starting EvtRaw v1.0.8 (aarch64)..."

if [ "$(uname -m)" != "aarch64" ]; then
    log -p e -t EvtRaw "ERROR: Architecture $(uname -m) is not supported (aarch64 only)"
    exit 1
fi

# 1. Energy-Aware Scheduler (EAS) Foreground Touch Responsiveness Tuning
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

# 2. System Properties for Idle Prevention & Conditional SurfaceFlinger Pacing
SDK_VER=$(getprop ro.build.version.sdk)

if command -v resetprop >/dev/null 2>&1; then
    resetprop -n ro.vendor.display.touch.idle.enable false

    # Defensive cleanup: remove legacy phase offsets if lingering from older versions (v1.0.6/v1.0.7)
    for prop in \
        debug.sf.early_phase_offset_ns \
        debug.sf.early_app_phase_offset_ns \
        debug.sf.early_gl_phase_offset_ns \
        debug.sf.early_gl_app_phase_offset_ns \
        debug.sf.high_fps_early_phase_offset_ns \
        debug.sf.high_fps_early_gl_phase_offset_ns \
        debug.sf.high_fps_late_app_phase_offset_ns \
        debug.sf.high_fps_late_sf_phase_offset_ns; do
        if [ "$(getprop "$prop")" = "500000" ]; then
            resetprop --delete "$prop" 2>/dev/null || true
        fi
    done
    if [ "$(getprop debug.sf.enable_gl_backpressure)" = "0" ]; then
        resetprop --delete debug.sf.enable_gl_backpressure 2>/dev/null || true
    fi
    if [ -n "$SDK_VER" ] && [ "$SDK_VER" -ge 33 ]; then
        resetprop -n debug.sf.auto_latch_unsignaled true
        log -p i -t EvtRaw "SurfaceFlinger: Android $SDK_VER detected -> auto_latch_unsignaled active"
    else
        resetprop -n debug.sf.latch_unsignaled 0
        resetprop -n debug.sf.auto_latch_unsignaled false
        log -p i -t EvtRaw "SurfaceFlinger: Android $SDK_VER detected -> anti-freeze safety active"
    fi
else
    if [ -n "$SDK_VER" ] && [ "$SDK_VER" -ge 33 ]; then
        setprop debug.sf.auto_latch_unsignaled true 2>/dev/null || true
    else
        setprop debug.sf.latch_unsignaled 0 2>/dev/null || true
        setprop debug.sf.auto_latch_unsignaled false 2>/dev/null || true
    fi
    log -p w -t EvtRaw "resetprop unavailable; ro.* properties applied via system.prop" 2>/dev/null || true
fi

# 3. Direct Hardware Driver Configuration (High Touch Polling Rate & Palm Sensor Tuning)
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

# 4. Real-Time Scheduler Priority for system_server Input Threads (SCHED_FIFO 98)
SERVER_PID=$(pidof system_server)
if [ -n "$SERVER_PID" ] && [ -d "/proc/$SERVER_PID/task" ]; then
    APPLIED_COUNT=0
    for task_dir in /proc/$SERVER_PID/task/*; do
        [ ! -f "$task_dir/comm" ] && continue
        THREAD_NAME=$(cat "$task_dir/comm" 2>/dev/null)
        case "$THREAD_NAME" in
            InputReader*|InputDispatcher*)
                TID="${task_dir##*/}"
                # Toybox syntax: chrt -f -p PID PRIORITY
                if chrt -f -p "$TID" 98 2>/dev/null; then
                    APPLIED_COUNT=$((APPLIED_COUNT + 1))
                fi
                if [ -f /dev/cpuset/top-app/tasks ]; then
                    echo "$TID" > /dev/cpuset/top-app/tasks 2>/dev/null || true
                elif [ -f /dev/cpuset/top-app/cgroup.procs ]; then
                    echo "$TID" > /dev/cpuset/top-app/cgroup.procs 2>/dev/null || true
                fi
                ;;
        esac
    done
    if [ "$APPLIED_COUNT" -gt 0 ]; then
        log -p i -t EvtRaw "Real-time SCHED_FIFO 98 applied to $APPLIED_COUNT input threads (InputReader/Dispatcher)"
    else
        log -p w -t EvtRaw "Warning: Input threads not found or chrt failed for system_server ($SERVER_PID)"
    fi
fi

# 5. Retry companion app install if it was deferred during module installation
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

# 6. Dynamic Game-Scoped PM QoS Daemon (50us CPU latency constraint strictly when games are active)
# Target 50us blocks deep C-states (C3/C4 power collapse) without killing C1/C2 retention.
start_pm_qos_daemon() {
    (
        exec 2>/dev/null
        QOS_HELD=0
        TARGET_LATENCY=50

        is_screen_on() {
            if dumpsys power 2>/dev/null | grep -qE "mHoldingDisplaySuspendBlocker=true|Display Power: state=ON"; then
                return 0
            fi
            return 1
        }

        while true; do
            # Adaptive sleep: release lock and sleep longer when screen is off
            if ! is_screen_on; then
                if [ "$QOS_HELD" = "1" ]; then
                    exec 3>&- 2>/dev/null || true
                    QOS_HELD=0
                    log -p i -t EvtRaw "Screen off: PM QoS latency lock RELEASED"
                fi
                sleep 8
                continue
            fi

            IS_GAME=0
            ACTIVE_NAME=""

            # Layer 1: WindowManager focus (100% authoritative for active foreground window)
            FOCUS_LINE=$(dumpsys window 2>/dev/null | grep -m 1 -E "mCurrentFocus|mFocusedApp")
            if [ -n "$FOCUS_LINE" ]; then
                if ! echo "$FOCUS_LINE" | grep -qiE "com\.google\.android\.play\.games|android\.systemui|com\.miui\.home"; then
                    if echo "$FOCUS_LINE" | grep -qiE "pubg|codm|freefire|genshin|honkai|mobile.*legends|roblox|wildrift|riotgames|epicgames|cytus|phigros|arcaea|[./_]game[s]?([./_]|$)"; then
                        IS_GAME=1
                        ACTIVE_NAME=$(echo "$FOCUS_LINE" | grep -oE '[a-zA-Z0-9._]+/[a-zA-Z0-9._]+' | head -n 1)
                    fi
                fi
            fi

            # Layer 2: Kernel cpuset top-app fallback
            if [ "$IS_GAME" = "0" ] && [ -f /dev/cpuset/top-app/cgroup.procs ]; then
                for pid in $(cat /dev/cpuset/top-app/cgroup.procs 2>/dev/null); do
                    if [ -f "/proc/$pid/cmdline" ]; then
                        PKG=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | awk '{print $1}')
                        if [ -n "$PKG" ] && [ "$PKG" != "com.google.android.play.games" ] && [ "$PKG" != "com.android.systemui" ]; then
                            if echo "$PKG" | grep -qiE "pubg|codm|freefire|genshin|honkai|mobile.*legends|roblox|wildrift|riotgames|epicgames|cytus|phigros|arcaea|[./_]game[s]?([./_]|$)"; then
                                IS_GAME=1
                                ACTIVE_NAME="$PKG"
                                break
                            fi
                        fi
                    fi
                done
            fi

            if [ "$IS_GAME" = "1" ]; then
                if [ "$QOS_HELD" = "0" ] && [ -c "/dev/cpu_dma_latency" ]; then
                    if exec 3>/dev/cpu_dma_latency; then
                        printf '%d' "$TARGET_LATENCY" >&3
                        QOS_HELD=1
                        log -p i -t EvtRaw "PM QoS CPU latency lock (${TARGET_LATENCY}us) ACTIVE for: $ACTIVE_NAME"
                    fi
                fi
                sleep 3
            else
                if [ "$QOS_HELD" = "1" ]; then
                    exec 3>&- 2>/dev/null || true
                    QOS_HELD=0
                    log -p i -t EvtRaw "PM QoS CPU latency lock RELEASED"
                fi
                sleep 5
            fi
        done
    ) &
}

start_pm_qos_daemon

log -p i -t EvtRaw "EvtRaw applied successfully"
