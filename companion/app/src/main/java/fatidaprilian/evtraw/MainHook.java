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
            XposedBridge.log(TAG + ": [" + lpparam.packageName + "] native game engine detected -> unbuffered VSYNC bypass ENABLED");
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
     * Reduces touch deadzone (touchSlop) and tap timeouts to achieve near-instantaneous touch response.
     */
    private void hookViewConfiguration(ClassLoader cl) {
        try {
            Class<?> viewConfigClass = XposedHelpers.findClass("android.view.ViewConfiguration", cl);

            XposedHelpers.findAndHookMethod(viewConfigClass, "getScaledTouchSlop",
                    XC_MethodReplacement.returnConstant(2));

            XposedHelpers.findAndHookMethod(viewConfigClass, "getScaledPagingTouchSlop",
                    XC_MethodReplacement.returnConstant(4));

            XposedHelpers.findAndHookMethod(viewConfigClass, "getTapTimeout",
                    XC_MethodReplacement.returnConstant(15));

            XposedHelpers.findAndHookMethod(viewConfigClass, "getDoubleTapTimeout",
                    XC_MethodReplacement.returnConstant(100));

            XposedHelpers.findAndHookMethod(viewConfigClass, "getLongPressTimeout",
                    XC_MethodReplacement.returnConstant(250));
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": Failed to hook ViewConfiguration: " + t.getMessage());
        }
    }
            } catch (ClassNotFoundException ignored) {
                // Class not found in target package, continue searching
            }
        }
        return false;
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
}
