package fatidaprilian.evtraw;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XC_MethodReplacement;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

/**
 * EvtRaw Companion LSPosed Hook
 *
 * Provides ultra-low latency touch dispatch and reduced deadzones for competitive games.
 * Features single-pass native game engine detection to apply unbuffered VSYNC bypass
 * without inducing scrolling micro-stutter in standard UI layouts.
 */
public class MainHook implements IXposedHookLoadPackage {

    private static final String TAG = "EvtRaw";

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) throws Throwable {
        if (lpparam.packageName == null || lpparam.packageName.equals("android")) {
            return;
        }

        // Stage 1: Universal ViewConfiguration Tuning (Safe for all apps in scope)
        hookViewConfiguration(lpparam.classLoader);

        // Stage 2: Single-pass Game Detection (Category inspection & engine classes)
        boolean isNativeGame = isGamePackage(lpparam);

        if (isNativeGame) {
            // Stage 3: Direct Unbuffered Touch Dispatch (Bypass VSYNC buffering)
            hookVsyncBatching(lpparam.classLoader);
            // Stage 4: Adaptive Window Flags (3-Button SLIPPERY vs Gesture Preservation)
            hookAdaptiveGameWindow(lpparam.classLoader);
            // Stage 5: In-Process Thread Priority Booster (RenderThread & UI Thread)
            hookThreadPriority(lpparam.classLoader);
            XposedBridge.log(TAG + ": [" + lpparam.packageName + "] native game engine detected -> ultra optimizations ENABLED");
        } else {
            XposedBridge.log(TAG + ": [" + lpparam.packageName + "] standard view hierarchy -> VSYNC batching retained for smooth scrolling");
        }
    }

    /**
     * Identifies games via ApplicationInfo category or third-party native game engine runtimes.
     * Evaluated strictly once during package load; zero runtime overhead during frame loops.
     */
    private boolean isGamePackage(XC_LoadPackage.LoadPackageParam lpparam) {
        if (lpparam.appInfo != null) {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                if (lpparam.appInfo.category == android.content.pm.ApplicationInfo.CATEGORY_GAME) {
                    return true;
                }
            }
            if ((lpparam.appInfo.flags & android.content.pm.ApplicationInfo.FLAG_IS_GAME) != 0) {
                return true;
            }
        }

        // Check for dedicated third-party native game engines
        String[] engineClasses = new String[] {
            "com.unity3d.player.UnityPlayer",              // Unity (Mobile Legends, Genshin, Wild Rift)
            "com.epicgames.ue4.GameActivity",              // Unreal Engine 4 (PUBG Mobile, Fortnite)
            "com.epicgames.unreal.GameActivity",           // Unreal Engine 5
            "org.godotengine.godot.Godot",                 // Godot Engine
            "org.cocos2dx.lib.Cocos2dxActivity"            // Cocos2d-x Engine
        };

        for (String className : engineClasses) {
            try {
                Class.forName(className, false, lpparam.classLoader);
                return true;
            } catch (ClassNotFoundException ignored) {
                // Class not found in target package, continue searching
            }
        }
        return false;
    }

    /**
     * Reduces touch deadzone (touchSlop) to 0px and tap timeouts to 5ms for absolute instantaneous response.
     */
    private void hookViewConfiguration(ClassLoader cl) {
        try {
            Class<?> viewConfigClass = XposedHelpers.findClass("android.view.ViewConfiguration", cl);

            XposedHelpers.findAndHookMethod(viewConfigClass, "getScaledTouchSlop",
                    XC_MethodReplacement.returnConstant(0));

            XposedHelpers.findAndHookMethod(viewConfigClass, "getScaledPagingTouchSlop",
                    XC_MethodReplacement.returnConstant(1));

            XposedHelpers.findAndHookMethod(viewConfigClass, "getTapTimeout",
                    XC_MethodReplacement.returnConstant(5));

            XposedHelpers.findAndHookMethod(viewConfigClass, "getDoubleTapTimeout",
                    XC_MethodReplacement.returnConstant(80));

            XposedHelpers.findAndHookMethod(viewConfigClass, "getLongPressTimeout",
                    XC_MethodReplacement.returnConstant(200));
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": Failed to hook ViewConfiguration: " + t.getMessage());
        }
    }

    /**
     * Bypasses Choreographer VSYNC delay for touch dispatch.
     * Immediately consumes pending input events with unresampled raw coordinates (-1L).
     */
    private void hookVsyncBatching(ClassLoader cl) {
        try {
            Class<?> viewRootImplClass = XposedHelpers.findClass("android.view.ViewRootImpl", cl);

            XposedHelpers.findAndHookMethod(viewRootImplClass, "scheduleConsumeBatchedInput",
                    new XC_MethodHook() {
                        @Override
                        protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
                            try {
                                try {
                                    XposedHelpers.setBooleanField(param.thisObject, "mUnbufferedInputDispatch", true);
                                } catch (Throwable ignored) {
                                    // Field not present on older Android versions; -1L already drains unbuffered
                                }
                                // -1L consumes all batched input events immediately without resampling
                                XposedHelpers.callMethod(param.thisObject, "doConsumeBatchedInput", -1L);
                                param.setResult(null); // Prevent scheduling Choreographer VSYNC callback
                            } catch (Throwable inner) {
                                // Graceful fallback: let default scheduleConsumeBatchedInput proceed
                            }
                        }
                    });
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": Failed to hook scheduleConsumeBatchedInput: " + t.getMessage());
        }
    }

    /**
     * Adaptively applies FLAG_SLIPPERY (0x20000000) only for 3-Button navigation users.
     * If gesture navigation is detected (MIUI force_fsg_nav_bar=1 or AOSP navigation_mode=2),
     * FLAG_SLIPPERY is omitted so full-screen edge gestures (Back/Home) remain 100% functional.
     */
    private void hookAdaptiveGameWindow(ClassLoader cl) {
        try {
            Class<?> activityClass = XposedHelpers.findClass("android.app.Activity", cl);

            XposedHelpers.findAndHookMethod(activityClass, "onAttachedToWindow", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) throws Throwable {
                    try {
                        android.app.Activity activity = (android.app.Activity) param.thisObject;
                        int fsg = android.provider.Settings.Global.getInt(
                                activity.getContentResolver(), "force_fsg_nav_bar", -1);
                        int nav = android.provider.Settings.Secure.getInt(
                                activity.getContentResolver(), "navigation_mode", -1);

                        boolean isGesture = (fsg == 1) || (nav == 2);

                        if (!isGesture) {
                            // 3-Button navigation: safe to apply FLAG_SLIPPERY
                            activity.getWindow().addFlags(0x20000000);
                            XposedBridge.log(TAG + ": [" + activity.getPackageName() + "] 3-Button navigation detected -> FLAG_SLIPPERY enabled");
                        } else {
                            // Gesture navigation: omit flag to preserve back/home edge gestures
                            XposedBridge.log(TAG + ": [" + activity.getPackageName() + "] Gesture navigation detected -> FLAG_SLIPPERY omitted for gesture safety");
                        }
                    } catch (Throwable inner) {
                        // Graceful fallback if settings provider is inaccessible
                    }
                }
            });
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": Failed to hook Activity.onAttachedToWindow: " + t.getMessage());
        }
    }

    /**
     * Elevates in-process thread scheduling priority for UI and rendering threads to THREAD_PRIORITY_URGENT_DISPLAY (-8).
     * Eliminates Linux CFS scheduling jitter during heavy 3D rendering loops without requiring root inside the app.
     */
    private void hookThreadPriority(ClassLoader cl) {
        try {
            // Elevate main UI thread immediately
            try {
                android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_URGENT_DISPLAY);
            } catch (Throwable ignored) {
                // Ignore if process sandbox restricts main thread nice level
            }

            // Hook Activity.onResume to scan and elevate game engine threads once created
            Class<?> activityClass = XposedHelpers.findClass("android.app.Activity", cl);
            XposedHelpers.findAndHookMethod(activityClass, "onResume", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) throws Throwable {
                    boostGameThreads();
                }
            });
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": Failed to hook thread priority: " + t.getMessage());
        }
    }

    /**
     * Scans /proc/self/task to identify game engine worker and render threads,
     * elevating them to URGENT_DISPLAY priority.
     */
    private void boostGameThreads() {
        try {
            java.io.File taskDir = new java.io.File("/proc/self/task");
            java.io.File[] tasks = taskDir.listFiles();
            if (tasks == null) return;

            for (java.io.File task : tasks) {
                try {
                    int tid = Integer.parseInt(task.getName());
                    java.io.File commFile = new java.io.File(task, "comm");
                    if (!commFile.exists()) continue;

                    java.io.BufferedReader reader = new java.io.BufferedReader(new java.io.FileReader(commFile));
                    String comm = reader.readLine();
                    reader.close();

                    if (comm != null) {
                        String name = comm.trim();
                        if (name.contains("UnityMain") || name.contains("RenderThread")
                                || name.contains("GLThread") || name.contains("Job.Worker")
                                || name.contains("MainThread")) {
                            android.os.Process.setThreadPriority(tid, android.os.Process.THREAD_PRIORITY_URGENT_DISPLAY);
                            XposedBridge.log(TAG + ": Boosted game thread [" + name + "] (tid " + tid + ") to URGENT_DISPLAY");
                        }
                    }
                } catch (Throwable ignored) {
                    // Safe per-thread fallback
                }
            }
        } catch (Throwable ignored) {
            // Graceful directory read fallback
        }
    }
}

