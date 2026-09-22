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
        │  (Bypasses default 8-16dp touchSlop down to 0px, tapTimeout to 5ms)
        ▼
[Application & Engine Threads] (UnityMain, RenderThread, GLThread)
        │  (In-process priority boosted to THREAD_PRIORITY_URGENT_DISPLAY -8)
        ▼
[SurfaceFlinger] (Display Pipeline)
        │  (Pure Double Buffering eliminates ~8.33ms Triple Buffering queue latency)
        ▼
[Display Panel] (Glass Photon Output at 120Hz)
```

### Why Default Android Touch & Display Feels Delayed
1. **Touch Slop Deadbands**: `ViewConfiguration` forces the system to wait for a finger to travel 8 to 16 density-independent pixels (~24px - 48px) before registering analog motion.
2. **Tap Delay Timers**: Gesture recognizers enforce a 100ms tap timeout before confirming button or skill presses.
3. **CFS Scheduling Contention**: UI and game engine render threads run with standard CFS timeslices, causing 2-6ms scheduling jitter during heavy 3D rendering.
4. **Triple Buffering Queues**: SurfaceFlinger buffers up to 3 frames in queue, introducing an extra 1-frame (~8.33ms at 120Hz) presentation latency.

---

## Architectural Comparison

| Stage | Default Android Pipeline | EvtRaw Engine | Latency Impact |
| :--- | :--- | :--- | :--- |
| **Driver & TSR** | Throttled / power-saving idle downclocking | Native peak hardware rate (e.g. 360Hz / 480Hz) preserved via vendor driver tuning | **~2.77ms** scan interval |
| **Input Scheduling** | CFS `SCHED_OTHER` thread timeslice delays | Elevated to `SCHED_FIFO` 98 on `InputReader` & `InputDispatcher` + Dynamic PM QoS (0µs) | **-2ms to -4ms** jitter reduction |
| **Deadband (Slop)** | 8dp - 16dp touch slop (~24px - 48px deadzone) | Reduced to **0px** (sub-pixel tracking on the very first pixel delta) | **-15ms to -30ms** finger travel delay |
| **Tap Delay** | 100ms tap timeout | Reduced to **5ms** via `ViewConfiguration` hook | **-95ms** skill release delay |
| **Engine Priority** | Normal thread priority (nice 0 / 10) | Elevated in-process to `THREAD_PRIORITY_URGENT_DISPLAY` (-8) for `UnityMain` and render threads | **-1ms to -3ms** frame dispatch lag |
| **Render Pacing** | Triple Buffering presentation queue (~8.33ms) | SurfaceFlinger Pure Double Buffering (`max_frame_buffer_acquired_buffers=2`) & 0.5ms phase offsets | **-8.33ms** buffer queue latency |

---

## Multi-Layer Bypass Architecture

### 1. Scheduler Prioritization & Real-Time Input Scheduling
- **EAS Scheduler Foreground Boost (`schedtune` / `uclamp`)**: Bumps `/dev/stune/top-app/schedtune.boost` and enables `prefer_idle` so the active foreground game or UI thread handling touch dispatch is immediately scheduled on an idle performance core without frequency ramping lag.
- **Real-Time Input Thread Priority (`SCHED_FIFO` 98)**: Elevates kernel priority for `InputReader` and `InputDispatcher` threads in `system_server` via `chrt -f -p 98` and binds them to `/dev/cpuset/top-app/tasks`, eliminating 2-6ms scheduling jitter during peak 3D rendering load.
- **Dynamic Game-Scoped PM QoS Daemon**: Opens `/dev/cpu_dma_latency` with value `0` while games are active to eliminate C-state transition latency (100-300 $\mu$s), automatically releasing the lock upon exiting to preserve battery life.

### 2. Driver and Vendor Controller Layer
- **Hardware Sample Rate Bump & Palm Tuning**: Triggers vendor sysfs nodes (`/sys/class/touch/touch_dev/bump_sample_rate` = 1, `palm_sensor` = 0) to unlock maximum polling capacity on supported drivers without conflicting ioctls.
- **Power Idle Suppression**: Disables `ro.vendor.display.touch.idle.enable` to prevent the digitizer from downclocking during static display frames.

### 3. Native Vendor Calibration & Peak TSR Preservation
- **Preserves Native Vendor IDC**: Does not override or strip factory IDC calibration files, ensuring vendor multi-touch heuristics and high touch sampling rates (up to 360Hz/480Hz+) operate with full accuracy and zero synthetic coordinate distortion.
- **Uncapped Framework Motion Event Pipeline**: Avoids artificial resampling suppression so the application layer receives dense, peak-frequency motion events natively.

### 4. SurfaceFlinger Render Pacing Layer (Freeze-Free)
- **Pure Double Buffering**: Forces `ro.surface_flinger.max_frame_buffer_acquired_buffers=2` to eliminate the 1-frame (~8.33ms at 120Hz) Triple Buffering queue latency.
- **VSYNC Phase Offset Optimization**: Tightens phase offsets (`debug.sf.early_phase_offset_ns=500000`, `high_fps` offsets = 500000) to reduce presentation queue latency to ~3.5ms - 4.5ms.
- **Version-Conditional Pacing**: Automatically activates `debug.sf.auto_latch_unsignaled=true` on Android 13+ (SDK $\ge$ 33), while disabling aggressive latching on Android 12 to guarantee 100% immunity from display lockups and black screens.

### 5. Framework ViewConfiguration, Adaptive Navigation & In-Process Thread Priority (LSPosed Companion)
Hooks `android.view.ViewConfiguration`, `ViewRootImpl`, and `Activity` inside application runtimes:
- `getScaledTouchSlop()` -> Forced to `0` px (true sub-pixel tracking; motion is registered immediately on the very first pixel delta).
- `getTapTimeout()` -> Forced to `5` ms (single taps register 95ms faster).
- `getDoubleTapTimeout()` -> Forced to `80` ms.
- **Smart VSYNC Bypass**: Single-pass runtime detection automatically unbuffers touch dispatch (`consumeBatchedInputEvents(-1L)` and `mUnbufferedInputDispatch = true`) for target games while retaining standard batching for UI scrolling.
- **In-Process Thread Priority Booster**: Elevates the game's Main UI Thread and background rendering threads (`UnityMain`, `RenderThread`, `GLThread`, `Job.Worker`) to `THREAD_PRIORITY_URGENT_DISPLAY` (-8) via `android.os.Process.setThreadPriority`, eliminating CFS scheduling jitter. Emits a clean, single-line summary log on resume.
- **Adaptive Navigation Detection**: Reads `force_fsg_nav_bar` and `navigation_mode` dynamically. Automatically applies `FLAG_SLIPPERY` for 3-Button navigation users, while strictly omitting it for Full Screen Gesture users to preserve edge back/home swipe actions.

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

### 2. Verify SurfaceFlinger Pure Double Buffering
Verify that SurfaceFlinger buffer limit is active:
```bash
getprop ro.surface_flinger.max_frame_buffer_acquired_buffers
```
Expected output: `2`.

### 3. Verify LSPosed Framework Hook & Thread Booster
Inspect the Xposed runtime log:
```bash
logcat -d -s XposedBridge | grep -i "EvtRaw"
```
Expected output:
```
EvtRaw: Native game engine detected -> ultra optimizations ENABLED
EvtRaw: Boosted 9 engine/render threads to URGENT_DISPLAY
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
- **Modifications & Maintenance**: [fatidaprilian](https://github.com/fatidaprilian/evtraw).
  - Re-engineered Level 5 ultra-low latency pipeline with 0px sub-pixel touch slop and 5ms tap timeouts.
  - In-process engine thread priority booster elevating UI and 3D rendering threads (`UnityMain`, `RenderThread`) to `THREAD_PRIORITY_URGENT_DISPLAY` (-8).
  - SurfaceFlinger Pure Double Buffering and 0.5ms tightened VSYNC phase offsets.
  - Preserved full native 360Hz+ hardware touch sampling rate by eliminating conflicting legacy binary ioctls and synthetic IDC overrides.
  - Open-sourced companion LSPosed hook in `companion/` with clean single-line logging.

All trademarks, device names, and brand names are the property of their respective owners.
