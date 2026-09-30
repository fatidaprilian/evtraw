<p align="center">
  <img src="rti.webp" alt="EvtRaw Banner" width="100%">
</p>

# EvtRaw: Hardware Raw Touch Input Engine for Android

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Architecture](https://img.shields.io/badge/Architecture-aarch64-green.svg)](module.prop)
[![Target](https://img.shields.io/badge/Android-8.0_to_14+-orange.svg)](module.prop)
[![Framework](https://img.shields.io/badge/Companion-LSPosed-purple.svg)](companion/)

EvtRaw is a system-level touch and display latency optimization engine designed to eliminate touch slop deadbands, tap timeouts, VSYNC delivery batching, CPU scheduling jitter, and presentation buffer queues on Android.

By streamlining the input-to-render pipeline, EvtRaw delivers unbuffered touch reports directly to game engines with sub-pixel sensitivity and minimal end-to-end touch-to-photon latency.

---

## Technical Background: The Android Touch & Render Pipeline

In standard Android deployments, touch events from the physical digitizer pass through multiple layers of filtering, batching, and buffer queuing before photon emission:

```
[Hardware Digitizer]
        │  (Hardware polling at native peak rate, e.g. 240Hz - 360Hz+)
        ▼
[Kernel Touch Driver] (/dev/xiaomi-touch, fts_ts, goodix)
        │  (Kernel input interrupt dispatch)
        ▼
[Linux Input Subsystem] (/dev/input/event*)
        │  (Standard evdev event stream)
        ▼
[Android InputReader & InputDispatcher] (system_server)
        │  (Real-Time SCHED_FIFO 98 priority & top-app cpuset binding)
        ▼
[InputChannel Socket] -> [ViewRootImpl / Choreographer] (App Process)
        │  (Smart unbuffered VSYNC bypass for target games via LSPosed)
        ▼
[ViewConfiguration] (View Hierarchy)
        │  (Bypasses default 8-16dp touchSlop down to 1px for target games)
        ▼
[Application & Engine Threads] (UnityMain, RenderThread, GLThread)
        │  (In-process priority boosted to TOP_APP_BOOST -10)
        ▼
[SurfaceFlinger] (Display Pipeline)
        │  (Preserves vendor triple buffering without GPU stalls; safe auto-latch pacing)
        ▼
[Display Panel] (Glass Photon Output at 120Hz)
```

### Why Default Android Touch & Display Feels Delayed
1. **Touch Slop Deadbands**: `ViewConfiguration` forces the system to wait for a finger to travel 8 to 16 density-independent pixels (~24px - 48px) before registering analog motion.
2. **Input Batching Delay**: Move events are held in queue until the next Choreographer VSYNC callback instead of immediately notifying game loops.
3. **CFS Scheduling Contention**: UI and game engine render threads run with standard CFS timeslices, causing 2-6ms scheduling jitter during heavy 3D rendering.
4. **Deep C-State Wakeup Penalties**: CPU cores transitioning into C3/C4 power collapse introduce 200µs - 800µs wake-up latency on new touch interrupts.

---

## Architectural Comparison

| Stage | Default Android Pipeline | EvtRaw Engine | Latency Impact |
| :--- | :--- | :--- | :--- |
| **Driver & TSR** | Throttled / power-saving idle downclocking | Native peak hardware rate preserved via vendor driver sysfs tuning | **~2.77ms** scan interval |
| **Input Scheduling** | CFS `SCHED_OTHER` thread timeslice delays | Elevated to `SCHED_FIFO` 98 on `InputReader` & `InputDispatcher` + Dynamic PM QoS (50µs) | **-2ms to -4ms** jitter reduction |
| **Deadband (Slop)** | 8dp - 16dp touch slop (~24px - 48px deadzone) | Reduced to **1px** in target games (sub-pixel tracking on first delta) | **-15ms to -30ms** finger travel delay |
| **Input Dispatch** | VSYNC-batched move events | Unbuffered touch dispatch enabled natively in `ViewRootImpl` | **-4ms to -8ms** dispatch delay |
| **Engine Priority** | Normal thread priority (nice 0 / 10) | Elevated in-process to `TOP_APP_BOOST` (-10) for `UnityMain` and render threads | **-1ms to -3ms** frame dispatch lag |

---

## Multi-Layer Bypass Architecture

### 1. Scheduler Prioritization & Real-Time Input Scheduling
- **EAS Scheduler Foreground Boost (`schedtune` / `uclamp`)**: Baseline hints set on boot to assign foreground touch threads to idle high-performance cores without frequency ramping lag.
- **Real-Time Input Thread Priority (`SCHED_FIFO` 98)**: Elevates kernel priority for `InputReader` and `InputDispatcher` threads in `system_server` via `chrt -f -p $TID 98` and binds them to `top-app` cpuset, eliminating scheduling jitter during peak 3D rendering load.
- **Dynamic Game-Scoped PM QoS Daemon**: Opens `/dev/cpu_dma_latency` with value `50` while games are active to prevent CPU cores from entering deep sleep C3/C4 states (200-800µs wake latency) while allowing power-saving retention, automatically releasing the lock upon exiting or screen-off.

### 2. Driver and Vendor Controller Layer
- **Hardware Sample Rate Bump & Palm Tuning**: Triggers vendor sysfs nodes (`/sys/class/touch/touch_dev/bump_sample_rate` = 1, `palm_sensor` = 0) to unlock maximum polling capacity on supported drivers.
- **Power Idle Suppression**: Disables `ro.vendor.display.touch.idle.enable` to prevent the digitizer from downclocking during static display frames.

### 3. Native Vendor Calibration & Peak TSR Preservation
- **Preserves Native Vendor IDC**: Does not override or strip factory IDC calibration files, ensuring vendor multi-touch heuristics and high touch sampling rates operate with full accuracy and zero synthetic coordinate distortion.
- **Dense Motion Event Pipeline**: Avoids artificial resampling suppression so the application layer receives dense, peak-frequency motion events natively.

### 4. SurfaceFlinger Render Pacing Layer (Freeze-Free)
- **Vendor-Safe Buffer Architecture**: Preserves vendor-tuned display buffers on `FramebufferSurface` to avoid GPU composition stalls and jank.
- **Version-Conditional Pacing**: Automatically activates `debug.sf.auto_latch_unsignaled=true` on Android 13+ (SDK $\ge$ 33), while disabling aggressive latching on Android 12 to guarantee immunity from display lockups.

### 5. Framework ViewConfiguration & In-Process Thread Priority (LSPosed Companion)
Hooks inside target game processes:
- `getScaledTouchSlop()` -> Reduced to `1` px for games (instant analog response; normal applications are untouched).
- **Native Unbuffered Touch Dispatch**: Activates `mUnbufferedInputDispatch` on `ViewRootImpl` to consume motion events immediately without VSYNC batching.
- **In-Process Thread Priority Booster**: Elevates the game's Main UI Thread and rendering threads (`UnityMain`, `RenderThread`, `GLThread`) to `TOP_APP_BOOST` (-10) via `android.os.Process.setThreadPriority`. Background compute workers (`Job.Worker`) are intentionally excluded to prevent render thread contention.

> [!WARNING]
> **Anti-Cheat Advisory (DYOR - Do Your Own Risk)**:
> Enabling a game in the LSPosed scope unlocks instantaneous touch registration and sub-pixel sensitivity. However, because LSPosed inherently attaches its runtime bridge (`liblspd.so`) into hooked target processes, online games with strict third-party environment scanners (e.g., Tencent ACE in PUBG Mobile) may detect the presence of the Xposed framework. 
> 
> You can try enabling it for your games, but proceed at your own discretion (DYOR). If you prefer zero risk on competitive accounts, simply leave the game unchecked in LSPosed—Layers 1 through 4 (Kernel driver tuning, native 360Hz TSR, and SurfaceFlinger double buffering) will still provide ultra-low latency with 100% clean process memory.

---

## Hardware Support

EvtRaw is architected for `aarch64` Android devices running Android 8.0 through Android 14+.

### Supported Architecture
- **Architecture**: `aarch64` (ARM64)
- **Platforms**: Qualcomm Snapdragon, MediaTek Dimensity, and modern ARM SoCs
- **Digitizer Controllers**: FocalTech (`fts_ts`), Novatek (`nt36xxx`), Goodix (`goodix_ts`), Synaptics, and standard Linux multitouch controllers
- **Display Rates**: Compatible with 60Hz, 90Hz, 120Hz, 144Hz, and up to 360Hz+ touch sampling rates

### Universal Digitizer Scanning
The module dynamically queries the Linux `evdev` subsystem (`/dev/input/event*`) at installation time. Any touchscreen supporting standard multitouch axes (`ABS_MT_POSITION_X`) receives an automated IDC profile.

---

## Installation

### Prerequisites
1. Root access via **Magisk** (v24.0+), **KernelSU** (v0.6.0+), or **APatch** (v10500+).
2. **LSPosed** framework installed and active (Zygisk or Riru release).

### Flashing Procedure
1. Download the latest `evtraw-v*.zip` from the [Releases](https://github.com/fatidaprilian/evtraw/releases) page.
2. Open your Root Manager (Magisk / KernelSU / APatch).
3. Navigate to Modules, select **Install from storage**, and select the zip file.
4. Reboot the device.
5. Open the LSPosed Manager notification, enable the **EvtRaw** companion module (`fatidaprilian.evtraw`), and select your desired game applications in the scope list.
6. Launch your games to apply all runtime hooks.

---

## Verification and Diagnostics

To verify that EvtRaw is operating correctly on your device, execute the following commands in a root shell (`su`):

### 1. Verify Event Polling Rate
Swipe continuously across the screen while monitoring evdev timestamps:
```bash
getevent -r -t /dev/input/eventX
```
*(Replace `eventX` with your touch node, e.g., `/dev/input/event2`)*. Event rate should reach between 300Hz and 360Hz+ during active dragging on supported high-rate digitizers.

### 2. Verify Real-Time Input Scheduling Priority
Verify that `InputReader` and `InputDispatcher` run under `SCHED_FIFO` 98:
```bash
for tid in $(cat /proc/$(pidof system_server)/task/*/comm 2>/dev/null | grep -E "InputReader|InputDispatcher"); do
  chrt -p "$tid"
done
```
Expected output: Policy `SCHED_FIFO`, priority `98`.

### 3. Verify LSPosed Framework Hook & Thread Booster
Inspect the Xposed runtime log:
```bash
logcat -d -s XposedBridge | grep -i "EvtRaw"
```
Expected output:
```
EvtRaw: [com.example.game] native game detected (early-detect) -> optimizations ENABLED
EvtRaw: Boosted 4 render/engine threads to priority -10
```

### 4. Empirical Latency & Tracking Verification
- **Touch Sample Rate Tester**: Check that All Historical Movement Rate maintains ~350Hz – 360Hz (solid 333Hz/500Hz intervals) during fast swipes without dropping to 240Hz/166Hz idle states.
- **Developer Options -> Pointer Location**: Turn on Pointer Location in Android Developer Options. Draw quick strokes across the screen. Notice the dense point cloud and immediate coordinate updates without initial touch-slop deadbands.

---

## Project Structure

```
evtraw/
├── .github/workflows/       # Automated CI/CD release pipelines
├── companion/               # Open-source LSPosed companion app (Android Gradle project)
│   ├── app/src/main/
│   │   ├── AndroidManifest.xml # LSPosed scope metadata
│   │   └── java/.../MainHook.java # ViewConfiguration tuning & thread priority booster
│   ├── gradle/
│   └── build.gradle
├── evtraw.apk               # Compiled LSPosed companion app (auto-built via CI/CD)
├── install.sh               # Universal module installer
├── module.prop              # Magisk/KernelSU metadata specification
├── NOTICE                   # Apache 2.0 attribution notices
├── LICENSE                  # Apache License 2.0 text
├── post-fs-data.sh          # Early boot permission script
├── service.sh               # Late-start daemon tuning script
├── system.prop              # Event dispatcher & SurfaceFlinger properties
└── uninstall.sh             # Clean state restoration script
```

---

## Attribution and Licensing

This project is licensed under the **Apache License 2.0**. See the [LICENSE](LICENSE) file for complete details.

- **Original Project**: RTI (Raw Touch Input) by [kaminarich](https://github.com/kaminarich).
  - Enforced real-time `SCHED_FIFO` 98 priority for `InputReader` and `InputDispatcher` in `system_server`.
  - Dynamic game-scoped PM QoS CPU DMA latency bounding (50µs) preventing deep sleep wake delays while preserving battery-saving retention.
  - In-process engine thread priority booster elevating UI and 3D rendering threads (`UnityMain`, `RenderThread`, `GLThread`) to `TOP_APP_BOOST` (-10).
  - Native unbuffered touch dispatch via `mUnbufferedInputDispatch` and 1px touch slop strictly inside verified game packages.
  - Hardware touch driver polling rate maximization and palm deadzone reduction via vendor sysfs.

All trademarks, device names, and brand names are the property of their respective owners.
