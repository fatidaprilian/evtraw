<p align="center">
  <img src="rti.webp" alt="EvtRaw Banner" width="100%">
</p>

# EvtRaw: Hardware Raw Touch Input Engine for Android

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Architecture](https://img.shields.io/badge/Architecture-aarch64-green.svg)](module.prop)
[![Target](https://img.shields.io/badge/Android-8.0_to_14+-orange.svg)](module.prop)
[![Framework](https://img.shields.io/badge/Companion-LSPosed-purple.svg)](companion/)

EvtRaw is a system-level touch optimization engine designed to bypass OS-level touch calibration, native resampling delay, VSYNC event batching, and framework gesture deadbands on Android. 

By mirroring the concept of Windows `WM_INPUT` (Raw Input), EvtRaw delivers unbuffered hardware touch reports directly to the application layer with minimal software latency and sub-pixel sensitivity.

---

## Technical Background: The Android Touch Pipeline

In standard Android deployments, touch events from the physical digitizer pass through multiple layers of filtering and synchronization before reaching the active view:

```
[Hardware Digitizer]
        │  (Scans screen at 120Hz - 360Hz)
        ▼
[Kernel Touch Driver] (/dev/xiaomi-touch, fts_ts, nt36xxx)
        │  (Applies vendor palm rejection, edge deadzones, power-saving idle states)
        ▼
[Linux Input Subsystem] (/dev/input/event*)
        │  (Standard evdev event stream)
        ▼
[Android InputReader] (system_server)
        │  (IDC calibration: applies geometric pressure/size scaling and coordinate filtering)
        ▼
[Android InputDispatcher] (system_server)
        │  (Routes raw touch events to the focused window channel without throttling)
        ▼
[InputChannel Socket] -> [Android InputConsumer / InputTransport] (App Process)
        │  (Native Resampling in InputTransport.cpp: applies 5ms RESAMPLE_LATENCY linear interpolation)
        ▼
[ViewRootImpl / Choreographer] (App Process)
        │  (VSYNC Batching: buffers events until the next display frame tick)
        ▼
[ViewConfiguration] (View Hierarchy)
        │  (Delays event dispatch until finger moves beyond touchSlop: default 8-16 dp)
        ▼
[Application Touch Handler] (onTouchEvent)
```

### Why Default Android Touch Feels Delayed
1. **IDC Calibration & Filtering**: `TouchInputMapper` normalizes raw hardware coordinates using synthetic geometric calibration curves.
2. **Native Resampling Interpolation**: `InputTransport.cpp` applies a hardcoded 5ms `RESAMPLE_LATENCY` linear interpolation filter to smooth coordinates, which delays raw packet delivery to application processes.
3. **VSYNC Batching (Project Butter)**: `ViewRootImpl` intentionally holds back touch reports in `mBatchedInputEventReceiver` until the next display Choreographer VSYNC pulse.
4. **Touch Slop Deadbands**: `ViewConfiguration` forces the system to wait for a finger to travel 8 to 16 density-independent pixels before registering a scroll or motion event.

---

## Architectural Comparison

| Stage | Default Android Pipeline | Windows Raw Input Equivalent | EvtRaw Engine |
| :--- | :--- | :--- | :--- |
| **Driver** | Power-saving sampling downclocking | Device Driver Queue | Native 360Hz hardware report rate (e.g., Poco F4 `fts_ts`) maintained via vendor ioctl & idle suppression |
| **Calibration** | Coordinate smoothing & pressure curves | Cursor ballistics & acceleration | Disabled (`touch.*.calibration = none`) |
| **Native Resampling** | 5ms linear interpolation (`RESAMPLE_LATENCY` in `InputTransport.cpp`) | Direct raw packet stream | Bypassed via `ro.input.resampling=0` |
| **VSYNC Batching** | Buffered to Choreographer frame tick (~8.3ms-16.6ms) | Unbuffered message loop | Immediate unbuffered dispatch via LSPosed `ViewRootImpl` hook (`consumeBatchedInputEvents(-1L)`) |
| **Deadband** | 8dp - 16dp touch slop (~24-48px) | Windows threshold deadzone | Reduced to 2px via LSPosed companion hook |
| **Tap Delay** | 100ms tap timeout | Standard click timeout | Reduced to 15ms via `ViewConfiguration` hook |
| **Render Pacing** | Triple Buffering presentation queue (~8.3ms) | Immediate buffer presentation | Bypassed via SurfaceFlinger `debug.sf.latch_unsignaled=1` |

---

## Multi-Layer Bypass Architecture

### 1. Scheduler Prioritization & Energy-Aware Scheduling
- **EAS Scheduler Foreground Boost (`schedtune` / `uclamp`)**: Bumps `/dev/stune/top-app/schedtune.boost` and enables `prefer_idle` so the active foreground game or UI thread handling touch dispatch is immediately scheduled on an idle performance core without frequency ramping lag.

### 2. Driver and Vendor Controller Layer
- **Xiaomi Touch Controller (`/dev/xiaomi-touch`)**: Issues ioctl requests (`0x40045403` and `0x44085400`) to enable Game Mode, unlock maximum touch sensitivity, and disable edge deadzones.
- **Hardware Sample Rate Bump**: Triggers vendor sysfs nodes (`/sys/class/touch/touch_dev/bump_sample_rate`) to switch the digitizer into high-frequency reporting mode.
- **Power Idle Suppression**: Disables `ro.vendor.display.touch.idle.enable` to prevent the digitizer from downclocking during static display frames.

### 3. Native InputReader Layer (`.idc`)
Custom Input Device Configuration files (`fts_ts.idc` and dynamic runtime fallbacks) instruct `InputReader` to bypass all software transformations:
```properties
touch.deviceType = touchScreen
touch.orientationAware = 1
touch.gestureMode = spots
touch.size.calibration = none
touch.pressure.calibration = none
touch.coverage.calibration = none
touch.distance.calibration = none
touch.orientation.calibration = none
```

### 4. Native InputTransport & Resampling Bypass Layer
- Sets `ro.input.resampling=0` via `resetprop` and `system.prop` to disable native touch resampling in `libinput.so` (`frameworks/native/libs/input/InputTransport.cpp`). This eliminates the hardcoded 5ms `RESAMPLE_LATENCY` linear interpolation filter across all processes (Java, Unity, Unreal, Flutter) with zero CPU overhead.

### 5. SurfaceFlinger Render Pacing Layer
- Sets `debug.sf.latch_unsignaled=1` and `debug.sf.enable_gl_backpressure=0` to allow `SurfaceFlinger` to latch completed graphic buffers immediately without waiting for the next VSYNC pulse. This cuts approximately 1 display frame (~8.3ms on 120Hz) from the end-to-end touch-to-photon pipeline.

### 6. Framework ViewConfiguration & VSYNC Bypass (LSPosed Companion)
Hooks `android.view.ViewConfiguration` and `ViewRootImpl` inside application runtimes:
- `getScaledTouchSlop()` -> Forced to `2` px. Motion is detected immediately upon minimal finger travel (down from 22 physical pixels default on 2.75x density).
- `getTapTimeout()` -> Forced to `15` ms.
- `getDoubleTapTimeout()` -> Forced to `100` ms.
- **Smart VSYNC Bypass**: Single-pass runtime detection automatically unbuffers touch dispatch (`consumeBatchedInputEvents(-1L)` and `mUnbufferedInputDispatch = true`) for target games while retaining standard batching for UI scrolling.

> [!WARNING]
> **Anti-Cheat Advisory (DYOR - Do Your Own Risk)**:
> Enabling a game in the LSPosed scope unlocks instantaneous touch registration and sub-pixel sensitivity. However, because LSPosed inherently attaches its runtime bridge (`liblspd.so`) into hooked target processes, online games with strict third-party environment scanners (e.g., Tencent ACE in PUBG Mobile) may detect the presence of the Xposed framework. 
> 
> You can try enabling it for your games, but proceed at your own discretion (DYOR). If you prefer zero risk on competitive accounts, simply leave the game unchecked in LSPosed—Layers 1 through 5 (Kernel 360Hz driver, IDC calibration, resampling bypass, and SurfaceFlinger pacing) will still provide ultra-low latency with 100% clean process memory.

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
*(Replace `eventX` with your touch node, e.g., `/dev/input/event2`)*. Event rate should reach between 300Hz and 360Hz during active dragging on supported 360Hz digitizers (e.g. Poco F4 `fts_ts`).

### 2. Verify Native Resampling Bypass
Verify that native touch resampling interpolation is disabled:
```bash
getprop ro.input.resampling
```
Expected output: `0`.

### 3. Verify SurfaceFlinger Render Pacing
Verify that SurfaceFlinger latch unsignaled is active:
```bash
getprop debug.sf.latch_unsignaled
```
Expected output: `1`.

### 4. Verify IDC Calibration Bypass
Check active `InputReader` mapper status:
```bash
dumpsys input | grep -A 25 "Touch Input Mapper"
```
Confirm that `Calibration:` parameters for size, pressure, and distance are listed as `none`.

### 5. Verify LSPosed Framework Hook
Inspect the Xposed runtime log:
```bash
logcat -d -s XposedBridge | grep -i "EvtRaw"
```
Expected output:
```
EvtRaw: [com.PigeonGames.Phigros] native game engine detected -> unbuffered VSYNC bypass ENABLED
```

### 6. Empirical Latency & Tracking Verification
- **Developer Options -> Pointer Location**: Turn on Pointer Location in Android Developer Options. Draw quick strokes across the screen. Notice the dense point cloud and immediate update of coordinate delta, pressure, and size without lag or synthetic curve rounding.
- **High-Speed Camera (Optional)**: Record touch interaction at 240fps or 960fps slow-motion to empirically observe the reduction in finger-to-action motion lag compared to stock OS configuration.

---

## Project Structure

```
evtraw/
├── .github/workflows/       # Automated CI/CD release pipelines
├── bin/
│   └── RTI--aarch64         # Driver ioctl & kernel node execution binary
├── system/
│   └── usr/
│       └── idc/
│           ├── fts_ts.idc          # Native FocalTech digitizer IDC
│           └── rairin_touch.idc    # Universal fallback template
├── install.sh               # Module installer & dynamic evdev scanner
├── module.prop              # Magisk/KernelSU metadata specification
├── NOTICE                   # Apache 2.0 attribution notices
├── LICENSE                  # Apache License 2.0 text
├── post-fs-data.sh          # Early boot permission script
├── companion/               # Open-source LSPosed companion app (Android Gradle project)
│   ├── app/src/main/
│   │   ├── AndroidManifest.xml # LSPosed scope metadata
│   │   └── java/.../MainHook.java # ViewConfiguration tuning & native engine VSYNC bypass
│   ├── gradle/
│   └── build.gradle
├── evtraw.apk               # Compiled LSPosed companion app (auto-built via CI/CD)
├── service.sh               # Late-start daemon tuning script
├── system.prop              # Event dispatcher system properties
└── uninstall.sh             # Clean state restoration script
```

---

## Attribution and Licensing

This project is licensed under the **Apache License 2.0**. See the [LICENSE](LICENSE) file for complete details.

- **Original Project**: RTI (Raw Touch Input) by [kaminarich](https://github.com/kaminarich).
- **Modifications & Maintenance**: [fatidaprilian](https://github.com/fatidaprilian/evtraw).
  - Dedicated support and calibration for FocalTech (`fts_ts`) and universal aarch64 digitizers.
  - Native AOSP touch resampling bypass (`ro.input.resampling=0`) eliminating 5ms `libinput` interpolation delay.
  - Retained hardware compatibility safety checks while streamlining installation workflow.
  - Open-sourced companion LSPosed hook in `companion/` with single-pass native engine VSYNC bypass.
  - Reconstructed technical documentation, empirical diagnostics, and telemetry configurations.

All trademarks, device names, and brand names are the property of their respective owners.
