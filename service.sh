#!/system/bin/sh
# EvtRaw Boot Service Script v1.1.0 (Universal aarch64)
# Hardware touch driver tuning, real-time input scheduling, and game-scoped PM QoS.

MODDIR=${0%/*}

until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 2
done
sleep 5

log -p i -t EvtRaw "Starting EvtRaw v1.1.0 (aarch64)..."

if [ "$(uname -m)" != "aarch64" ]; then
    log -p e -t EvtRaw "Error: Architecture $(uname -m) is not supported (aarch64 only)"
    exit 1
fi

# 1. Energy-Aware Scheduler (EAS) & latency-sensitive hints (Active 24/7)
for boost_node in /dev/stune/top-app/schedtune.boost; do
    [ -f "$boost_node" ] && echo 10 > "$boost_node" 2>/dev/null
done
for prefer_idle in /dev/stune/top-app/schedtune.prefer_idle; do
    [ -f "$prefer_idle" ] && echo 1 > "$prefer_idle" 2>/dev/null
done
for uclamp_min in /dev/cpuctl/top-app/cpu.uclamp.min; do
    [ -f "$uclamp_min" ] && echo 20 > "$uclamp_min" 2>/dev/null
done
for uclamp_lat in /dev/cpuctl/top-app/cpu.uclamp.latency_sensitive; do
    [ -f "$uclamp_lat" ] && echo 1 > "$uclamp_lat" 2>/dev/null
done

# 2. Multi-vendor hardware driver node tuning (Active 24/7)
apply_touch_hardware_nodes() {
    # Xiaomi / POCO / Redmi / Black Shark (xiaomi_touch driver)
    for node in \
        /sys/class/touch/touch_dev/bump_sample_rate \
        /sys/devices/virtual/touch/touch_dev/bump_sample_rate \
        /sys/class/touch/touch_dev/touch_game_mode \
        /sys/class/touch/touch_dev/touch_active; do
        [ -f "$node" ] && echo 1 > "$node" 2>/dev/null
    done
    for palm in \
        /sys/class/touch/touch_dev/palm_sensor \
        /sys/devices/virtual/touch/touch_dev/palm_sensor; do
        [ -f "$palm" ] && echo 0 > "$palm" 2>/dev/null
    done

    # OnePlus / Realme / OPPO (OPlus Touchpanel driver)
    for oplus in \
        /proc/touchpanel/game_switch_enable \
        /proc/touchpanel/oplus_touch_screen_game_mode; do
        [ -f "$oplus" ] && echo 1 > "$oplus" 2>/dev/null
    done

    # Samsung Touch Screen Panel (sec_ts)
    if [ -f /sys/class/sec/tsp/cmd ]; then
        echo "set_game_mode,1" > /sys/class/sec/tsp/cmd 2>/dev/null
    fi

    # Motorola Touchscreen Interpolation
    if [ -f /sys/class/touchscreen/primary/interpolation ]; then
        echo 1 > /sys/class/touchscreen/primary/interpolation 2>/dev/null
    fi
}

apply_touch_hardware_nodes

# 3. Kernel threaded IRQ priority elevation (Active 24/7)
tune_touch_irq_threads() {
    TOUCH_IRQS=$(awk -F: '/fts_ts|goodix|synaptics|novatek|nt36|sec_ts|touchscreen|xiaomi-touch/ {print $1}' /proc/interrupts | tr -d ' ')
    
    APPLIED_IRQS=0
    for irq in $TOUCH_IRQS; do
        for tid in $(pgrep -f "irq/$irq-" 2>/dev/null); do
            if chrt -f -p "$tid" 98 2>/dev/null; then
                APPLIED_IRQS=$((APPLIED_IRQS + 1))
            fi
        done
    done
    if [ "$APPLIED_IRQS" -gt 0 ]; then
        log -p i -t EvtRaw "Applied SCHED_FIFO 98 to $APPLIED_IRQS kernel touch IRQ threads"
    fi
}

tune_touch_irq_threads

# 4. system_server input threads priority & safe cgroups (Active 24/7)
SERVER_PID=$(pidof system_server)
if [ -n "$SERVER_PID" ] && [ -d "/proc/$SERVER_PID/task" ]; then
    APPLIED_INPUT=0
    for task_dir in /proc/$SERVER_PID/task/*; do
        [ ! -f "$task_dir/comm" ] && continue
        THREAD_NAME=$(cat "$task_dir/comm" 2>/dev/null)
        case "$THREAD_NAME" in
            InputReader*|InputDispatcher*)
                TID="${task_dir##*/}"
                if chrt -f -p "$TID" 98 2>/dev/null; then
                    APPLIED_INPUT=$((APPLIED_INPUT + 1))
                fi
                if [ -f /dev/cpuset/top-app/tasks ]; then
                    echo "$TID" > /dev/cpuset/top-app/tasks 2>/dev/null
                elif [ -f /dev/cpuset/top-app/cgroup.threads ]; then
                    echo "$TID" > /dev/cpuset/top-app/cgroup.threads 2>/dev/null
                fi
                ;;
        esac
    done
    log -p i -t EvtRaw "Applied SCHED_FIFO 98 to $APPLIED_INPUT system_server input threads"
fi

# 5. SurfaceFlinger display pacing (No phase offset tampering)
SDK_VER=$(getprop ro.build.version.sdk)
if command -v resetprop >/dev/null 2>&1; then
    # ro.vendor.display.touch.idle.enable is already set via system.prop
    if [ -n "$SDK_VER" ] && [ "$SDK_VER" -ge 33 ]; then
        resetprop -n debug.sf.auto_latch_unsignaled true
        log -p i -t EvtRaw "SurfaceFlinger: Android $SDK_VER -> auto_latch_unsignaled active"
    else
        resetprop -n debug.sf.latch_unsignaled 0
        resetprop -n debug.sf.auto_latch_unsignaled false
    fi
fi

# 6. Companion app installation retry
if [ -f "$MODDIR/.apk_pending" ]; then
    for apk_file in evtraw.apk RTIapp.apk; do
        if [ -f "$MODDIR/$apk_file" ]; then
            case "$apk_file" in
                RTIapp.apk) target_pkg="com.rti.idc" ;;
                *) target_pkg="fatidaprilian.evtraw" ;;
            esac
            install_out=$(pm install --user 0 -r "$MODDIR/$apk_file" 2>&1 || pm install -r "$MODDIR/$apk_file" 2>&1)
            if echo "$install_out" | grep -q "Success"; then
                log -p i -t EvtRaw "Companion app ($apk_file) installed successfully"
                rm -f "$MODDIR/.apk_pending" "$MODDIR/$apk_file"
                break
            elif echo "$install_out" | grep -q "INSTALL_FAILED_UPDATE_INCOMPATIBLE"; then
                pm uninstall "$target_pkg" >/dev/null 2>&1 || pm uninstall --user 0 "$target_pkg" >/dev/null 2>&1
                reinstall_out=$(pm install --user 0 -r "$MODDIR/$apk_file" 2>&1 || pm install -r "$MODDIR/$apk_file" 2>&1)
                if echo "$reinstall_out" | grep -q "Success"; then
                    log -p i -t EvtRaw "Companion app ($apk_file) reinstalled cleanly after signature update"
                    rm -f "$MODDIR/.apk_pending" "$MODDIR/$apk_file"
                    break
                fi
            fi
        fi
    done
fi

# 7. Dynamic game-scoped binary PM QoS daemon (Game-Only, 50us constraint)
start_pm_qos_daemon() {
    (
        exec 2>/dev/null
        QOS_HELD=0

        is_screen_on() {
            # Primary: hardware backlight node (ROM-agnostic, zero overhead)
            for bl in /sys/class/leds/lcd-backlight/brightness /sys/class/backlight/*/brightness; do
                if [ -f "$bl" ]; then
                    val=$(cat "$bl" 2>/dev/null)
                    if [ -n "$val" ]; then
                        [ "$val" -gt 0 ] 2>/dev/null && return 0
                        return 1
                    fi
                fi
            done
            # Fallback: dumpsys power state (for devices without backlight sysfs)
            dumpsys power 2>/dev/null | grep -qE "mHoldingDisplaySuspendBlocker=true|Display Power: state=ON"
        }

        while true; do
            if ! is_screen_on; then
                if [ "$QOS_HELD" = "1" ]; then
                    exec 3>&- 2>/dev/null
                    QOS_HELD=0
                    log -p i -t EvtRaw "Screen off: PM QoS latency lock released"
                fi
                sleep 8
                continue
            fi

            IS_GAME=0
            ACTIVE_NAME=""

            # Layer 1: WindowManager active focus
            FOCUS_LINE=$(dumpsys window 2>/dev/null | grep -m 1 -E "mCurrentFocus|mFocusedApp")
            if [ -n "$FOCUS_LINE" ]; then
                if ! echo "$FOCUS_LINE" | grep -qiE "com\.google\.android\.play\.games|android\.systemui|com\.miui\.home"; then
                    # Heuristic: [./_]game[s]? may match non-game packages — acceptable, only activates 50us QoS
                    if echo "$FOCUS_LINE" | grep -qiE "pubg|codm|freefire|genshin|honkai|mobile.*legends|roblox|wildrift|riotgames|epicgames|cytus|phigros|arcaea|[./_]game[s]?([./_]|$)"; then
                        IS_GAME=1
                        ACTIVE_NAME=$(echo "$FOCUS_LINE" | grep -oE '[a-zA-Z0-9._]+/[a-zA-Z0-9._]+' | head -n 1)
                    fi
                fi
            fi

            # Layer 2: top-app cpuset cgroup fallback
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
                        # 50 microseconds as 4-byte little-endian s32: 0x00000032
                        printf '\x32\x00\x00\x00' >&3
                        QOS_HELD=1
                        apply_touch_hardware_nodes
                        tune_touch_irq_threads
                        log -p i -t EvtRaw "PM QoS CPU latency lock (50us binary) active for: $ACTIVE_NAME"
                    fi
                fi
                sleep 3
            else
                if [ "$QOS_HELD" = "1" ]; then
                    exec 3>&- 2>/dev/null
                    QOS_HELD=0
                    log -p i -t EvtRaw "PM QoS CPU latency lock released"
                fi
                sleep 5
            fi
        done
    ) &
}

start_pm_qos_daemon
echo $! > "$MODDIR/.daemon_pid"
log -p i -t EvtRaw "EvtRaw v1.1.0 initialized successfully"
