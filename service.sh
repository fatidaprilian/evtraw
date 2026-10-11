#!/system/bin/sh
# EvtRaw Boot Service Script v1.1.0 (Universal aarch64)
# Hardware touch driver tuning and userspace input thread optimization.

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

# 1. Multi-vendor hardware driver node tuning (Peak sample rate & game mode)
apply_touch_hardware_nodes() {
    # Xiaomi / POCO / Redmi / Black Shark (xiaomi_touch driver)
    # Triggers Touch IC to switch to peak hardware sampling rate (360Hz / 480Hz / 720Hz+)
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

# 2. Input thread scheduling & CPU performance core affinity (Bypasses msm_irqbalance)
get_perf_cpu_mask() {
    TOTAL_CPUS=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l)
    if [ "$TOTAL_CPUS" -le 4 ]; then
        echo "f"
        return
    fi

    MIN_FREQ=999999999
    for freq_file in /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq; do
        if [ -f "$freq_file" ]; then
            f=$(cat "$freq_file" 2>/dev/null)
            if [ -n "$f" ] && [ "$f" -lt "$MIN_FREQ" ]; then
                MIN_FREQ=$f
            fi
        fi
    done

    MASK=0
    CORE_IDX=0
    HAS_FREQ=0
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        freq_file="$cpu_dir/cpufreq/cpuinfo_max_freq"
        if [ -f "$freq_file" ]; then
            HAS_FREQ=1
            f=$(cat "$freq_file" 2>/dev/null)
            if [ -n "$f" ] && [ "$f" -gt "$MIN_FREQ" ]; then
                # Mid or Big Performance core
                MASK=$((MASK | (1 << CORE_IDX)))
            fi
        fi
        CORE_IDX=$((CORE_IDX + 1))
    done

    # Fallback to upper half (e.g. 0xf0 on 8-core) if cpufreq sysfs is restricted
    if [ "$HAS_FREQ" -eq 0 ] || [ "$MASK" -eq 0 ]; then
        if [ "$TOTAL_CPUS" -eq 8 ]; then
            echo "f0"
        else
            echo "ff"
        fi
        return
    fi

    printf "%x\n" "$MASK"
}

SERVER_PID=$(pidof system_server)
if [ -n "$SERVER_PID" ] && [ -d "/proc/$SERVER_PID/task" ]; then
    PERF_MASK=$(get_perf_cpu_mask)
    APPLIED_INPUT=0
    for task_dir in /proc/$SERVER_PID/task/*; do
        [ ! -f "$task_dir/comm" ] && continue
        THREAD_NAME=$(cat "$task_dir/comm" 2>/dev/null)
        case "$THREAD_NAME" in
            InputReader*|InputDispatcher*)
                TID="${task_dir##*/}"
                chrt -f -p "$TID" 98 2>/dev/null
                if command -v taskset >/dev/null 2>&1 && [ -n "$PERF_MASK" ]; then
                    taskset -p "$PERF_MASK" "$TID" 2>/dev/null
                fi
                if [ -f /dev/cpuset/top-app/tasks ]; then
                    echo "$TID" > /dev/cpuset/top-app/tasks 2>/dev/null
                elif [ -f /dev/cpuset/top-app/cgroup.threads ]; then
                    echo "$TID" > /dev/cpuset/top-app/cgroup.threads 2>/dev/null
                fi
                APPLIED_INPUT=$((APPLIED_INPUT + 1))
                ;;
        esac
    done
    log -p i -t EvtRaw "Applied SCHED_FIFO 98 & affinity mask (0x$PERF_MASK) to $APPLIED_INPUT system_server input threads"
fi

# 3. SurfaceFlinger display pacing
SDK_VER=$(getprop ro.build.version.sdk)
if command -v resetprop >/dev/null 2>&1; then
    if [ -n "$SDK_VER" ] && [ "$SDK_VER" -ge 33 ]; then
        resetprop -n debug.sf.auto_latch_unsignaled true
        log -p i -t EvtRaw "SurfaceFlinger: Android $SDK_VER -> auto_latch_unsignaled active"
    else
        resetprop -n debug.sf.latch_unsignaled 0
        resetprop -n debug.sf.auto_latch_unsignaled false
    fi
fi

# 4. Companion app installation retry
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

log -p i -t EvtRaw "EvtRaw v1.1.0 initialized successfully"
