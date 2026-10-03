package fatidaprilian.evtraw;

import android.app.Activity;
import android.os.Handler;
import android.os.Looper;
import android.view.MotionEvent;
import android.view.View;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XC_MethodReplacement;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;

/**
 * EvtRaw Companion LSPosed Hook v1.0.9
 * Bypasses VSYNC batching delay, minimizes touch slop, and optimizes game thread priorities.
 */
public class MainHook implements IXposedHookLoadPackage {

    private static final String TAG = "EvtRaw";
    private boolean mOptimizationsApplied = false;

    @Override
    public void handleLoadPackage(XC_LoadPackage.LoadPackageParam lpparam) throws Throwable {
        if (lpparam.packageName == null 
                || lpparam.packageName.equals("android")
                || lpparam.packageName.startsWith("com.android.")
                || lpparam.packageName.startsWith("com.google.android.")
                || lpparam.packageName.equals("fatidaprilian.evtraw")) {
            return;
        }

        applyGameOptimizations(lpparam.classLoader, lpparam.packageName);
    }

    private synchronized void applyGameOptimizations(ClassLoader cl, String packageName) {
        if (mOptimizationsApplied) return;
        mOptimizationsApplied = true;

        hookViewConfiguration(cl);
        hookUnbufferedTouchDispatch(cl);
        hookThreadPriority(cl);

        XposedBridge.log(TAG + ": [" + packageName + "] Game optimizations applied");
    }

    /**
     * Minimizes touch deadzone (touchSlop) to 1px for instant analog tracking.
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
     * Bypasses Choreographer VSYNC batching on ViewRootImpl and requests unbuffered delivery.
     */
    private void hookUnbufferedTouchDispatch(ClassLoader cl) {
        try {
            Class<?> viewRootImplClass = XposedHelpers.findClass("android.view.ViewRootImpl", cl);

            XposedHelpers.findAndHookMethod(viewRootImplClass, "scheduleConsumeBatchedInput",
                    new XC_MethodReplacement() {
                        @Override
                        protected Object replaceHookedMethod(MethodHookParam param) throws Throwable {
                            try {
                                XposedHelpers.setBooleanField(param.thisObject, "mUnbufferedInputDispatch", true);
                                XposedHelpers.callMethod(param.thisObject, "consumeBatchedInput", -1L);
                            } catch (Throwable ignored) {
                            }
                            return null;
                        }
                    });

            Class<?> viewClass = XposedHelpers.findClass("android.view.View", cl);
            XposedHelpers.findAndHookMethod(viewClass, "dispatchTouchEvent", MotionEvent.class,
                    new XC_MethodHook() {
                        @Override
                        protected void beforeHookedMethod(MethodHookParam param) throws Throwable {
                            MotionEvent ev = (MotionEvent) param.args[0];
                            if (ev != null && (ev.getAction() == MotionEvent.ACTION_DOWN || ev.getAction() == MotionEvent.ACTION_MOVE)) {
                                View v = (View) param.thisObject;
                                v.requestUnbufferedDispatch(ev);
                            }
                        }
                    });
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": Failed to hook unbuffered dispatch: " + t.getMessage());
        }
    }

    /**
     * Staged thread priority elevation across game startup and loading lifecycle.
     */
    private void hookThreadPriority(ClassLoader cl) {
        try {
            try {
                android.os.Process.setThreadPriority(-10);
            } catch (Throwable ignored) {}

            Class<?> activityClass = XposedHelpers.findClass("android.app.Activity", cl);
            XposedHelpers.findAndHookMethod(activityClass, "onResume", new XC_MethodHook() {
                @Override
                protected void afterHookedMethod(MethodHookParam param) throws Throwable {
                    boostGameThreads();

                    Handler handler = new Handler(Looper.getMainLooper());
                    // Stage 1: Engine initialization
                    handler.postDelayed(() -> boostGameThreads(), 2000);
                    // Stage 2: Scene and asset loading
                    handler.postDelayed(() -> boostGameThreads(), 6000);
                    // Stage 3: Active gameplay rendering threads
                    handler.postDelayed(() -> boostGameThreads(), 15000);
                }
            });
        } catch (Throwable t) {
            XposedBridge.log(TAG + ": Failed to hook thread priority: " + t.getMessage());
        }
    }

    /**
     * Elevates rendering and game engine worker threads to nice -10.
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
                        if (name.contains("UnityMain") 
                                || name.contains("UnityGfx")
                                || name.contains("RHIThread")
                                || name.contains("RenderThread")
                                || name.contains("GLThread")
                                || name.contains("MainThread")
                                || name.contains("VkWorker")
                                || name.contains("GodotRender")) {
                            android.os.Process.setThreadPriority(tid, -10);
                            count++;
                        }
                    }
                } catch (Throwable ignored) {}
            }
            if (count > 0) {
                XposedBridge.log(TAG + ": Boosted " + count + " render/engine threads to priority -10");
            }
        } catch (Throwable ignored) {}
    }
}
