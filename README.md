<p align="center">
  <img src="rti.webp" alt="EvtRaw Banner" width="100%">
</p>

# EvtRaw: Hardware Raw Touch Input Engine for Android

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Architecture](https://img.shields.io/badge/Architecture-aarch64-green.svg)](module.prop)
[![Target](https://img.shields.io/badge/Android-8.0_to_14+-orange.svg)](module.prop)
[![Framework](https://img.shields.io/badge/Companion-LSPosed-purple.svg)](companion/)

EvtRaw is a system-level touch optimization engine designed to bypass OS-level touch calibration, noise filtering, event throttling, and framework gesture deadbands on Android. 

By mirroring the concept of Windows `WM_INPUT` (Raw Input), EvtRaw delivers unthrottled hardware touch reports directly to the application layer with sub-pixel sensitivity and zero artificial dispatch lag.

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
        │  (Throttled by windowsmgr.max_events_per_sec; default 60-120 Hz)
        ▼
[InputChannel Socket] -> [Android InputConsumer] (App Process)
        │  (Input Resampling: events are held and interpolated to sync with display VSYNC)
        ▼
[ViewConfiguration] (View Hierarchy)
        │  (Delays event dispatch until finger moves beyond touchSlop: default 8-16 dp)
        ▼
[Application Touch Handler] (onTouchEvent)
```

### Why Default Android Touch Feels Delayed
1. **IDC Calibration & Filtering**: `TouchInputMapper` normalizes raw hardware coordinates using synthetic geometric calibration curves.
2. **Event Dispatch Throttling**: The native `InputDispatcher` drops or caps events per second if they exceed the system event rate ceiling.
3. **VSYNC Batching (Project Butter)**: Android intentionally delays raw touch reports to interpolate them into the display refresh cycle.
4. **Touch Slop Deadbands**: `ViewConfiguration` forces the system to wait for a finger to travel 8 to 16 density-independent pixels before registering a scroll or motion event.

---

## Architectural Comparison

| Stage | Default Android Pipeline | Windows Raw Input Equivalent | EvtRaw Engine |
| :--- | :--- | :--- | :--- |
| **Driver** | Power-saving sampling (120-180Hz) | Device Driver Queue | Full 360Hz hardware report rate unlocked via vendor ioctl |
| **Calibration** | Coordinate smoothing & pressure curves | Cursor ballistics & acceleration | Disabled (`touch.*.calibration = none`) |
| **Dispatch** | Throttled (default 60-120 events/sec) | Coalesced in `WM_MOUSEMOVE` | Uncapped to 360 events/sec (`max_events_per_sec = 360`) |
| **Deadband** | 8dp - 16dp touch slop (~24-48px) | Windows threshold deadzone | Reduced to 2px via LSPosed companion hook |
| **Tap Delay** | 100ms tap timeout | Standard click timeout | Reduced to 15ms via ViewConfiguration hook |

---

## 4-Layer Bypass Architecture

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

### 4. Native InputDispatcher Layer
- Sets `windowsmgr.max_events_per_sec = 360` via `resetprop` to ensure the input channel can dispatch up to 360 raw touch packets per second, matching the hardware capability of modern high-polling screens.

### 5. Framework ViewConfiguration & VSYNC Bypass (LSPosed)
Hooks `android.view.ViewConfiguration` and `ViewRootImpl` inside application runtimes:
- `getScaledTouchSlop()` -> Forced to `2` px. Motion is detected instantly upon the slightest finger movement (down from 22 physical pixels default on 2.75x density).
- `getTapTimeout()` -> Forced to `15` ms.
- `getDoubleTapTimeout()` -> Forced to `100` ms.
- **Smart VSYNC Bypass**: Single-pass runtime detection automatically unbuffers touch dispatch (`consumeBatchedInputEvents(-1L)`) for native games (Unity, Unreal, Godot, Cocos2d-x) while retaining standard batching for UI scrolling.

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
*(Replace `eventX` with your touch node, e.g., `/dev/input/event2`)*. Event rate should reach between 300Hz and 360Hz during active dragging.

### 2. Verify IDC Calibration Bypass
Check active `InputReader` mapper status:
```bash
dumpsys input | grep -A 25 "Touch Input Mapper"
```
Confirm that `Calibration:` parameters for size, pressure, and distance are listed as `none`.

### 3. Verify LSPosed Framework Hook
Inspect the Xposed runtime log:
```bash
logcat -d -s XposedBridge | grep -i "EvtRaw"
```
Expected output:
```
EvtRaw: [com.mobile.legends] native game engine detected -> unbuffered VSYNC bypass ENABLED
```

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
  - Raised dispatch frequency limits to 360Hz.
  - Retained hardware compatibility safety checks while streamlining installation workflow.
  - Open-sourced companion LSPosed hook in `companion/` with single-pass native engine VSYNC bypass.
  - Reconstructed technical documentation and telemetry configurations.

All trademarks, device names, and brand names are the property of their respective owners.
