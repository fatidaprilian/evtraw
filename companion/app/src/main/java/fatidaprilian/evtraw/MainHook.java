package fatidaprilian.evtraw;

import android.app.Activity;
import android.content.pm.ApplicationInfo;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XC_MethodReplacement;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

/**
 * EvtRaw Companion LSPosed Hook
 *
 * Provides ultra-low latency touch dispatch and reduced deadzones for competitive games.
 * Safely gates ViewConfiguration deadzone tuning and thread priority boosts strictly
 * to verified game engines to prevent UI degradation in standard applications.
 */
public class MainHook implements IXposedHookLoadPackage {

    private static final String TAG = "EvtRaw";

    private static final Set<String> KNOWN_GAMES = new HashSet<>(Arrays.asList(
            "com.mobile.legends",
            "com.tencent.ig",
            "com.dts.freefireth",
            "com.activision.callofduty.shooter",
            "com.miHoYo.GenshinImpact",
            "com.PigeonGames.Phigros",
            "moe.low.arc",
            "com.rayark.cytus2",
            "com.dynamix.c3",
            "com.roblox.client",
            "com.riotgames.league.wildrift",
            "com.epicgames.portal"
    ));

    private static final String[] ENGINE_CLASSES = new String[] {
            "com.unity3d.player.UnityPlayer",
            "com.unity3d.player.UnityPlayerActivity",
            "com.epicgames.ue4.GameActivity",
            "com.epicgames.unreal.GameActivity",
            "org.godotengine.godot.Godot",
            "org.cocos2dx.lib.Cocos2dxActivity"
    };

    private boolean mOptimizationsApplied = false;

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) throws Throwable {
        if (lpparam.packageName == null || lpparam.packageName.equals("android")
                || lpparam.packageName.startsWith("com.android.")
                || lpparam.packageName.equals("com.google.android.play.games")) {
            return;
        }

        boolean isGame = isGamePackage(lpparam);

        if (isGame) {
            applyGameOptimizations(lpparam.classLoader, lpparam.packageName, "early-detect");
        } else {
            // Hook Activity.onCreate to catch games loaded via dynamic split APKs or custom ClassLoaders
            hookLateGameDetection(lpparam);
        }
    }

    /**
     * Applies latency optimizations strictly to confirmed game packages.
     */
    private synchronized void applyGameOptimizations(ClassLoader cl, String packageName, String stage) {
        if (mOptimizationsApplied) return;
        mOptimizationsApplied = true;

        // Stage 1: ViewConfiguration deadzone reduction (strictly within game process)
        hookViewConfiguration(cl);

        // Stage 2: Native unbuffered touch dispatch
        hookUnbufferedTouchDispatch(cl);

        // Stage 3: In-process thread priority booster (RenderThread & UI Thread)
        hookThreadPriority(cl);

        XposedBridge.log(TAG + ": [" + packageName + "] native game detected (" + stage + ") -> optimizations ENABLED");
    }

    /**
     * Identifies games via known scope list, ApplicationInfo category, or runtime engine classes.
     */
    private boolean isGamePackage(XC_LoadPackage.LoadPackageParam lpparam) {
        if (KNOWN_GAMES.contains(lpparam.packageName)) {
            return true;
        }

        if (lpparam.appInfo != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                if (lpparam.appInfo.category == ApplicationInfo.CATEGORY_GAME) {
                    return true;
                }
            }
            if ((lpparam.appInfo.flags & ApplicationInfo.FLAG_IS_GAME) != 0) {
                return true;
            }
        }

        for (String className : ENGINE_CLASSES) {
            try {
                Class.forName(className, false, lpparam.classLoader);
                return true;
            } catch (ClassNotFoundException ignored) {
            }
        }

        return false;
    }

    /**
     * Hooks Activity.onCreate to catch multidex / dynamic asset delivery splits
     * where engine classes are loaded after package load.
     */
    private void hookLateGameDetection(final XC_LoadPackage.LoadPackageParam lpparam) {
        try {
            Class<?> activityClass = XposedHelpers.findClass("android.app.Activity", lpparam.classLoader);
            XposedHelpers.findAndHookMethod(activityClass, "onCreate", android.os.Bundle.class, new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) throws Throwable {
                    if (mOptimizationsApplied) return;

                    Activity act = (Activity) param.thisObject;
                    ClassLoader actCl = act.getClassLoader();

                    for (String className : ENGINE_CLASSES) {
                        try {
                            Class.forName(className, false, actCl);
                            applyGameOptimizations(actCl, lpparam.packageName, "late-detect");
                            return;
                        } catch (ClassNotFoundException ignored) {
                        }
                    }
                }
            });
        } catch (Throwable ignored) {
        }
    }

    /**
     * Reduces touch deadzone (touchSlop) to 1px for instant analog/swipe response in games.
     * Never applied to non-game apps to ensure normal UI scrolling remains intact.
     */
    private void hookViewConfiguration(ClassLoader cl) {
        try {
            Class<?> viewConfigClass = XposedHelpers.findClass("android.view.ViewConfiguration", cl);

            XposedHelpers.findAndHookMethod(viewConfigClass, "getScaledTouchSlop",
                    XC_MethodReplacement.returnConstant(1));

            XposedHelpers.findAndHookMethod(viewConfigClass, "getScaledPagingTouchSlop",
                    XC_MethodReplacement.returnConstant(1));

            XposedHelpers.findAndHookMethod(viewConfigClass, "getLongPressTimeout",
                    XC_MethodReplacement.returnConstant(300));
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": Failed to hook ViewConfiguration: " + t.getMessage());
        }
    }

    /**
     * Natively enables unbuffered touch dispatch via ViewRootImpl's mUnbufferedInputDispatch flag.
     * Prevents AOSP from resetting unbuffered mode on touch-up, ensuring continuous immediate delivery.
     */
    private void hookUnbufferedTouchDispatch(ClassLoader cl) {
        try {
            Class<?> viewRootImplClass = XposedHelpers.findClass("android.view.ViewRootImpl", cl);

            // Keep mUnbufferedInputDispatch active on the window receiver
            XposedHelpers.findAndHookMethod(viewRootImplClass, "scheduleConsumeBatchedInput",
                    new XC_MethodHook() {
                        @Override
                        protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
                            try {
                                XposedHelpers.setBooleanField(param.thisObject, "mUnbufferedInputDispatch", true);
                            } catch (Throwable ignored) {
                            }
                        }
                    });
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": Failed to hook unbuffered dispatch: " + t.getMessage());
        }
    }

    /**
     * Elevates rendering and UI threads to TOP_APP_BOOST (-10).
     * Excludes background worker threads (Job.Worker) to prevent CPU contention against render loops.
     */
    private void hookThreadPriority(ClassLoader cl) {
        try {
            // Elevate main UI thread
            try {
                android.os.Process.setThreadPriority(-10);
            } catch (Throwable ignored) {
            }

            Class<?> activityClass = XposedHelpers.findClass("android.app.Activity", cl);
            XposedHelpers.findAndHookMethod(activityClass, "onResume", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) throws Throwable {
                    boostGameThreads();

                    // Delayed scan for asynchronously spawned rendering threads
                    new Handler(Looper.getMainLooper()).postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            boostGameThreads();
                        }
                    }, 3000);
                }
            });
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": Failed to hook thread priority: " + t.getMessage());
        }
    }

    /**
     * Scans /proc/self/task to identify game graphics and rendering loops,
     * elevating them to TOP_APP_BOOST (-10).
     */
    private void boostGameThreads() {
        try {
            File taskDir = new File("/proc/self/task");
            File[] tasks = taskDir.listFiles();
            if (tasks == null) return;

            int count = 0;
            for (File task : tasks) {
                try {
                    int tid = Integer.parseInt(task.getName());
                    File commFile = new File(task, "comm");
                    if (!commFile.exists()) continue;

                    BufferedReader reader = new BufferedReader(new FileReader(commFile));
                    String comm = reader.readLine();
                    reader.close();

                    if (comm != null) {
                        String name = comm.trim();
                        // Strictly boost rendering/UI threads; do NOT boost Job.Worker
                        if (name.contains("UnityMain") || name.contains("RenderThread")
                                || name.contains("GLThread") || name.contains("MainThread")) {
                            android.os.Process.setThreadPriority(tid, -10);
                            count++;
                        }
                    }
                } catch (Throwable ignored) {
                }
            }
            if (count > 0) {
                XposedBridge.log(TAG + ": Boosted " + count + " render/engine threads to priority -10");
            }
        } catch (Throwable ignored) {
        }
    }
}
