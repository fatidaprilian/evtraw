<p align="center">
  <img src="rti.webp" alt="EvtRaw Banner" width="100%">
</p>

# EvtRaw: Hardware Raw Touch Input Engine for Android

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Architecture](https://img.shields.io/badge/Architecture-aarch64-green.svg)](module.prop)
[![Target](https://img.shields.io/badge/Android-8.0_to_14+-orange.svg)](module.prop)
[![Companion](https://img.shields.io/badge/Companion-LSPosed-purple.svg)](companion/)

EvtRaw is a system-level touch and display latency optimization engine designed to eliminate touch deadbands, VSYNC delivery batching, CPU scheduling jitter, and idle digitizer downclocking on Android.

---

## Technical Pipeline Overview

In standard Android deployments, touch events from the digitizer pass through filtering, batching, and buffer queuing before rendering:

```
[Hardware Digitizer]
        │  (Hardware peak scan rate: 240Hz - 480Hz+)
        ▼
[Kernel Touch Driver] (/dev/xiaomi-touch, fts_ts, goodix, oplus)
        │  (Kernel threaded IRQ worker elevated to SCHED_FIFO 98)
        ▼
[Linux Input Subsystem] (/dev/input/event*)
        │  (Standard evdev event stream)
        ▼
[InputReader & InputDispatcher] (system_server)
        │  (Real-Time SCHED_FIFO 98 priority & top-app cgroup.threads binding)
        ▼
[InputChannel Socket] -> [ViewRootImpl / Choreographer] (App Process)
        │  (Unbuffered dispatch bypass via LSPosed companion)
        ▼
[ViewConfiguration] (View Hierarchy)
        │  (Reduces touchSlop to 1px for sub-pixel tracking)
        ▼
[Engine Render & Worker Threads] (UnityGfxDeviceWorker, RHIThread, RenderThread)
        │  (In-process priority boosted to nice -10)
        ▼
[SurfaceFlinger] (Display Pipeline)
        │  (Safe auto-latch unsignaled; zero interference with display timings or 144Hz mods)
        ▼
[Display Panel]
```

---

## Architectural Comparison

| Pipeline Stage | Default Android Behavior | EvtRaw Engine (v1.0.9) | Latency Reduction |
| :--- | :--- | :--- | :--- |
| **Driver & TSR** | Power-saving idle downclocking | Peak hardware rate preserved via vendor driver sysfs nodes | **~2.77ms** scan interval |
| **Kernel IRQ Worker** | CFS timeslice scheduling (`SCHED_OTHER`) | Elevated to Real-Time `SCHED_FIFO` 98 (immune to `msm_irqbalance`) | **-1ms to -2ms** interrupt delay |
| **Input Scheduling** | CFS thread queue in `system_server` | Elevated to `SCHED_FIFO` 98 + `cgroup.threads` top-app binding | **-2ms to -4ms** scheduling jitter |
| **CPU Wakeup Latency** | C3/C4 deep sleep power collapse (200-800µs wake) | Game-scoped binary PM QoS lock (50µs) on `/dev/cpu_dma_latency` | **-0.5ms to -1ms** response time |
| **Touch Slop Deadband** | 8dp - 16dp touch slop (~24px - 48px deadzone) | Reduced to **1px** in target games | **-15ms to -30ms** finger travel delay |
| **Input Dispatch** | VSYNC-batched move events | Unbuffered dispatch via `requestUnbufferedDispatch` & batch drain | **-4ms to -8ms** dispatch delay |
| **Engine Worker Threads** | Standard thread priority (nice 0 / 10) | Elevated in-process to nice -10 (`UnityGfx`, `RHIThread`, etc.) | **-1ms to -3ms** frame dispatch lag |

---

## Architecture Breakdown

### 1. Active 24/7 Pipeline (Always On, Zero Idle Drain)
Because Linux input threads use event-driven blocking (`wait_for_completion`, `epoll_wait`), real-time scheduling consumes 0.00% CPU when fingers are not on the glass.
- **Hardware TSR Tuning**: Sets vendor sysfs nodes (`bump_sample_rate=1`, `touch_game_mode=1`, `touch_active=1`, `palm_sensor=0`, `game_switch_enable=1`).
- **Idle Downclock Suppression**: Sets `ro.vendor.display.touch.idle.enable=false`.
- **Kernel Threaded IRQ Priority**: Dynamically identifies touch IRQs and sets `irq/<N>-*` kthreads to `SCHED_FIFO 98`.
- **System Input Priority**: Elevates `InputReader` and `InputDispatcher` to `SCHED_FIFO 98` and assigns them to `/dev/cpuset/top-app/cgroup.threads`.
- **Scheduler Hints**: Applies EAS `prefer_idle` and `uclamp.latency_sensitive` to `top-app`.

### 2. Game-Only Dynamic Features
- **Dynamic Binary PM QoS Daemon**: Writes 4-byte binary `0x00000032` (50µs little-endian) to `/dev/cpu_dma_latency` while a game is active in the foreground. Automatically closes the file descriptor when leaving games or when the screen turns off, allowing normal battery-saving CPU deep sleep.
- **LSPosed Companion Hooks**:
  - `ViewConfiguration`: Sets `touchSlop` to 1px and `longPressTimeout` to 300ms.
  - `ViewRootImpl` & `View`: Hooks `scheduleConsumeBatchedInput` to consume batches immediately and calls `requestUnbufferedDispatch` on touch movements.
  - In-process thread booster: Elevates `UnityMain`, `UnityGfxDeviceWorker`, `RHIThread`, `RenderThread`, `GLThread`, `MainThread`, `VkWorker`, and `GodotRender` to nice -10 across a staged lifecycle scan (immediate, 2s, 6s, 15s).

### 3. Display Mod Compatibility (e.g. munch-144hz)
EvtRaw does not alter DTBOs, display refresh rates, or SurfaceFlinger phase offsets (`debug.sf.*phase_offset*`). It provides high-frequency touch reports (360Hz-480Hz) that cleanly feed into 144Hz/120Hz display refresh cycles without tearing or frame drops.

---

## Hardware Support

- **Architecture**: `aarch64` (ARM64)
- **Platforms**: Qualcomm Snapdragon, MediaTek Dimensity, and modern ARM SoCs
- **Digitizer Controllers**: FocalTech (`fts_ts`), Novatek (`nt36xxx`), Goodix (`goodix_ts`), Synaptics, and standard Linux multitouch controllers
- **Display Refresh Rates**: 60Hz, 90Hz, 120Hz, 144Hz, and up to 480Hz+ touch sampling rates
- **Factory Calibration**: Leaves native vendor IDC calibration files intact to preserve multi-touch heuristics without synthetic distortion.

---

## Installation

### Prerequisites
1. Root access via **Magisk** (v24.0+), **KernelSU** (v0.6.0+), or **APatch** (v10500+).
2. **LSPosed** framework installed and active.

### Procedure
1. Flash the module zip file in your Root Manager.
2. Reboot the device.
3. Open LSPosed Manager, enable the **EvtRaw** companion module (`fatidaprilian.evtraw`), and select your games in the scope list.
4. Launch your games.

---

## Verification

Run the following commands in a root shell (`su`):

### 1. Verify Event Polling Rate
```bash
getevent -r -t /dev/input/eventX
```
*(Replace `eventX` with your touch node).* Event rate should maintain ~360Hz+ during active dragging.

### 2. Verify Real-Time Priority
```bash
for tid in $(cat /proc/$(pidof system_server)/task/*/comm 2>/dev/null | grep -E "InputReader|InputDispatcher"); do
  chrt -p "$tid"
done
```
Output must show `policy=SCHED_FIFO` and `priority=98`.

### 3. Verify Kernel IRQ Worker Priority
```bash
chrt -p $(pgrep -f "irq/.*-fts_ts|goodix|novatek|xiaomi-touch")
```
Output must show `policy=SCHED_FIFO` and `priority=98`.

### 4. Verify LSPosed Companion Log
```bash
logcat -d -s XposedBridge | grep -i "EvtRaw"
```
Example output:
```
EvtRaw: [com.example.game] Game optimizations applied
EvtRaw: Boosted 4 render/engine threads to priority -10
```

---

## Project Structure

```
evtraw/
├── .github/workflows/       # CI/CD build workflows
├── companion/               # LSPosed companion app (Android Gradle project)
│   ├── app/src/main/
│   │   ├── AndroidManifest.xml # LSPosed scope metadata
│   │   └── java/.../MainHook.java # ViewConfiguration & thread priority booster
│   ├── gradle/
│   └── build.gradle
├── evtraw.apk               # Prebuilt companion APK
├── install.sh               # Root module installer
├── module.prop              # Module metadata
├── NOTICE                   # Attribution notices
├── LICENSE                  # Apache License 2.0 text
├── post-fs-data.sh          # Early boot script
├── service.sh               # Late-start service script
├── system.prop              # Vendor touch idle suppression
└── uninstall.sh             # Uninstallation script
```

---

## Attribution and Licensing

Licensed under the **Apache License 2.0**. See the [LICENSE](LICENSE) file for details.

- **Original Concept**: RTI (Raw Touch Input) by [kaminarich](https://github.com/kaminarich).
