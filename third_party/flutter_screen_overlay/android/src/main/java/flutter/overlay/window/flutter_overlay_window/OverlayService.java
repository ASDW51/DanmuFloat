package flutter.overlay.window.flutter_overlay_window;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.res.Configuration;
import android.content.res.Resources;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.app.PendingIntent;
import android.graphics.Point;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.PowerManager;
import android.util.DisplayMetrics;
import android.util.Log;
import android.util.TypedValue;
import android.view.Display;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;

import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;
import androidx.core.app.NotificationCompat;

import java.util.HashMap;
import java.util.Map;
import java.util.Timer;
import java.util.TimerTask;

import io.flutter.embedding.android.FlutterTextureView;
import io.flutter.embedding.android.FlutterView;
import io.flutter.FlutterInjector;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.FlutterEngineCache;
import io.flutter.embedding.engine.FlutterEngineGroup;
import io.flutter.embedding.engine.dart.DartExecutor;
import io.flutter.plugin.common.BasicMessageChannel;
import io.flutter.plugin.common.JSONMessageCodec;
import io.flutter.plugin.common.MethodChannel;

public class OverlayService extends Service implements View.OnTouchListener {
    private final int DEFAULT_NAV_BAR_HEIGHT_DP = 48;
    private final int DEFAULT_STATUS_BAR_HEIGHT_DP = 25;

    private Integer mStatusBarHeight = -1;
    private Integer mNavigationBarHeight = -1;
    private Resources mResources;

    public static final String INTENT_EXTRA_IS_CLOSE_WINDOW = "IsCloseWindow";

    /**
     * 通知栏「关闭点击穿透」动作：只改窗口 flag 并通知悬浮窗同步本地开关。
     *
     * 点击穿透开启后悬浮窗收不到触摸，窗内没有关闭入口，通知栏的按钮是唯一的就地出口。
     * 必须走独立分支处理：正常建窗流程会先 detach 再重建窗口，把已建立的弹幕连接全部断开。
     */
    public static final String ACTION_DISABLE_CLICK_THROUGH = "flutter.overlay.window.DISABLE_CLICK_THROUGH";

    private static OverlayService instance;
    public static boolean isRunning = false;
    private WindowManager windowManager = null;
    private FlutterView flutterView;
    private MethodChannel flutterChannel;
    private BasicMessageChannel<Object> overlayMessageChannel;
    private int clickableFlag = WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE | WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE |
            WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN;

    private Handler mAnimationHandler = new Handler();
    private float lastX, lastY;
    private int lastYPosition;
    private boolean dragging;
    private static final float MAXIMUM_OPACITY_ALLOWED_FOR_S_AND_HIGHER = 0.8f;
    private Point szWindow = new Point();
    private Timer mTrayAnimationTimer;
    private TrayAnimationTimerTask mTrayTimerTask;
    private PowerManager.WakeLock bookingWakeLock = null;

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void detachOverlayView() {
        if (windowManager != null && flutterView != null) {
            try {
                windowManager.removeView(flutterView);
            } catch (Throwable t) {
                Log.w("OverlayService", "Failed to remove overlay view", t);
            }
        }
        if (flutterView != null) {
            try {
                flutterView.detachFromFlutterEngine();
            } catch (Throwable t) {
                Log.w("OverlayService", "Failed to detach overlay view from engine", t);
            }
            flutterView = null;
        }
        windowManager = null;
    }

    @RequiresApi(api = Build.VERSION_CODES.M)
    @Override
    public void onDestroy() {
        Log.d("OverLay", "Destroying the overlay window service");
        // Release WakeLock before window teardown (timeout is 12s fallback).
        if (bookingWakeLock != null && bookingWakeLock.isHeld()) {
            try {
                bookingWakeLock.release();
                Log.d("OverlayService", "WakeLock released in onDestroy");
            } catch (Throwable t) {
                Log.w("OverlayService", "WakeLock release failed (non-fatal)", t);
            }
            bookingWakeLock = null;
        }
        // Cancel animation timers before detaching the view so the timer task
        // cannot call updateViewLayout on a removed view.
        if (mTrayAnimationTimer != null) {
            mTrayAnimationTimer.cancel();
            mTrayAnimationTimer = null;
        }
        if (mTrayTimerTask != null) {
            mTrayTimerTask.cancel();
            mTrayTimerTask = null;
        }
        detachOverlayView();
        isRunning = false;
        NotificationManager notificationManager = (NotificationManager) getApplicationContext().getSystemService(Context.NOTIFICATION_SERVICE);
        if (notificationManager != null) {
            notificationManager.cancel(OverlayConstants.NOTIFICATION_ID);
        }
        instance = null;
    }

    @RequiresApi(api = Build.VERSION_CODES.JELLY_BEAN_MR1)
    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        mResources = getApplicationContext().getResources();
        if (intent == null) {
            Log.w("OverlayService", "onStartCommand restarted with null intent; stopping service");
            isRunning = false;
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        int startX = intent.getIntExtra("startX", OverlayConstants.DEFAULT_XY);
        int startY = intent.getIntExtra("startY", OverlayConstants.DEFAULT_XY);
        boolean isCloseWindow = intent.getBooleanExtra(INTENT_EXTRA_IS_CLOSE_WINDOW, false);
        if (isCloseWindow) {
            detachOverlayView();
            stopSelf();
            isRunning = false;
            return START_NOT_STICKY;
        }
        if (ACTION_DISABLE_CLICK_THROUGH.equals(intent.getAction())) {
            // 通知栏动作：就地改 flag，不能走下面的 detach / 重建流程。
            disableClickThroughFromNotification();
            return START_STICKY;
        }
        if (windowManager != null || flutterView != null) {
            detachOverlayView();
        }
        isRunning = true;
        Log.d("onStartCommand", "Service started");
        FlutterEngine engine = FlutterEngineCache.getInstance().get(OverlayConstants.CACHED_TAG);
        if (engine == null) {
            Log.e("OverlayService", "Cached Flutter engine missing in onStartCommand; stopping service");
            isRunning = false;
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        engine.getLifecycleChannel().appIsResumed();
        flutterView = new FlutterView(getApplicationContext(), new FlutterTextureView(getApplicationContext()));
        flutterView.attachToFlutterEngine(engine);
        flutterView.setFitsSystemWindows(true);
        flutterView.setFocusable(true);
        flutterView.setFocusableInTouchMode(true);
        flutterView.setBackgroundColor(Color.TRANSPARENT);
        if (flutterChannel == null) {
            Log.e("OverlayService", "Method channel was not initialised before onStartCommand");
            isRunning = false;
            detachOverlayView();
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        flutterChannel.setMethodCallHandler((call, result) -> {
            if (call.method.equals("updateFlag")) {
                Object flagArg = call.argument("flag");
                if (flagArg == null) {
                    result.error("INVALID_ARG", "updateFlag: 'flag' argument is null", null);
                    return;
                }
                updateOverlayFlag(result, flagArg.toString());
            } else if (call.method.equals("updateOverlayPosition")) {
                Integer x = call.argument("x");
                Integer y = call.argument("y");
                if (x == null || y == null) {
                    result.error("INVALID_ARG", "updateOverlayPosition: 'x' or 'y' argument is null", null);
                    return;
                }
                moveOverlay(x, y, result);
            } else if (call.method.equals("resizeOverlay")) {
                Integer width = call.argument("width");
                Integer height = call.argument("height");
                Boolean enableDrag = call.argument("enableDrag");
                if (width == null || height == null || enableDrag == null) {
                    result.error("INVALID_ARG", "resizeOverlay: 'width', 'height', or 'enableDrag' argument is null", null);
                    return;
                }
                resizeOverlay(width, height, enableDrag, result);
            } else {
                result.notImplemented();
            }
        });
        if (overlayMessageChannel != null) {
            overlayMessageChannel.setMessageHandler((message, reply) -> {
                // 转发到主引擎的上行出口，不能读 WindowSetup.messenger：它此时已被悬浮窗引擎
                // 覆盖成悬浮窗自己的通道，会把消息原路弹回悬浮窗，主 App 一条都收不到。
                if (WindowSetup.upstreamMessenger != null) {
                    WindowSetup.upstreamMessenger.send(message);
                } else {
                    reply.reply(null);
                }
            });
        }
        windowManager = (WindowManager) getSystemService(WINDOW_SERVICE);
        if (windowManager == null) {
            Log.e("OverlayService", "WindowManager unavailable; stopping service");
            isRunning = false;
            detachOverlayView();
            stopSelf(startId);
            return START_NOT_STICKY;
        }

        refreshScreenSize();
        int dx = startX == OverlayConstants.DEFAULT_XY ? 0 : startX;
        int dy = startY == OverlayConstants.DEFAULT_XY ? -statusBarHeightPx() : startY;
        WindowManager.LayoutParams params = new WindowManager.LayoutParams(
                WindowSetup.width == -1999 ? -1 : WindowSetup.width,
                WindowSetup.height != -1999 ? WindowSetup.height : screenHeight(),
                0,
                -statusBarHeightPx(),
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY : WindowManager.LayoutParams.TYPE_PHONE,
                WindowSetup.flag | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS
                        | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN
                        | WindowManager.LayoutParams.FLAG_LAYOUT_INSET_DECOR
                        | WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED,
                PixelFormat.TRANSLUCENT
        );
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && WindowSetup.flag == clickableFlag) {
            params.alpha = MAXIMUM_OPACITY_ALLOWED_FOR_S_AND_HIGHER;
        }
        params.gravity = WindowSetup.gravity;
        // For wakeScreen overlays (e.g. booking), ask the system to turn the
        // screen on when this window appears.  FLAG_TURN_SCREEN_ON is
        // respected on TYPE_APPLICATION_OVERLAY windows on Android 8–13+.
        // The WakeLock below is the belt-and-suspenders fallback.
        if (WindowSetup.wakeScreen) {
            params.flags |= WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
                    | WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED;
        }
        flutterView.setOnTouchListener(this);
        try {
            windowManager.addView(flutterView, params);
        } catch (WindowManager.BadTokenException e) {
            // Window token invalid: Activity was destroyed while service was starting
            // (common during rapid app backgrounding on Android 12+).
            Log.e("OverlayService", "addView failed — window token invalid. Activity may have been destroyed.", e);
            isRunning = false;
            detachOverlayView();
            stopSelf(startId);
            return START_NOT_STICKY;
        } catch (Exception e) {
            Log.e("OverlayService", "addView failed with unexpected error", e);
            isRunning = false;
            detachOverlayView();
            stopSelf(startId);
            return START_NOT_STICKY;
        }
        // WakeLock: acquired AFTER addView so we only wake the screen when the
        // overlay window was successfully added.  ACQUIRE_CAUSES_WAKEUP forces
        // the screen on even from deep sleep.  The 12-second timeout is a
        // safety net; onDestroy() releases it earlier when the overlay closes.
        if (WindowSetup.wakeScreen) {
            try {
                PowerManager pm = (PowerManager) getSystemService(Context.POWER_SERVICE);
                if (pm != null) {
                    if (bookingWakeLock != null && bookingWakeLock.isHeld()) {
                        bookingWakeLock.release();
                    }
                    @SuppressWarnings("deprecation")
                    PowerManager.WakeLock wl = pm.newWakeLock(
                            PowerManager.SCREEN_BRIGHT_WAKE_LOCK | PowerManager.ACQUIRE_CAUSES_WAKEUP,
                            "lozy:bookingOverlayWakeLock");
                    wl.acquire(12_000L);
                    bookingWakeLock = wl;
                    Log.d("OverlayService", "WakeLock acquired — screen will wake for booking overlay");
                }
            } catch (Throwable t) {
                Log.w("OverlayService", "WakeLock acquisition failed (non-fatal)", t);
            }
        }
        moveOverlay(dx, dy, null);
        return START_STICKY;
    }


    @RequiresApi(api = Build.VERSION_CODES.JELLY_BEAN_MR1)
    private int screenHeight() {
        Display display = windowManager.getDefaultDisplay();
        DisplayMetrics dm = new DisplayMetrics();
        display.getRealMetrics(dm);
        return inPortrait() ?
                dm.heightPixels + statusBarHeightPx() + navigationBarHeightPx()
                :
                dm.heightPixels + statusBarHeightPx();
    }

    private int statusBarHeightPx() {
        if (mStatusBarHeight == -1) {
            int statusBarHeightId = mResources.getIdentifier("status_bar_height", "dimen", "android");

            if (statusBarHeightId > 0) {
                mStatusBarHeight = mResources.getDimensionPixelSize(statusBarHeightId);
            } else {
                mStatusBarHeight = dpToPx(DEFAULT_STATUS_BAR_HEIGHT_DP);
            }
        }

        return mStatusBarHeight;
    }

    int navigationBarHeightPx() {
        if (mNavigationBarHeight == -1) {
            int navBarHeightId = mResources.getIdentifier("navigation_bar_height", "dimen", "android");

            if (navBarHeightId > 0) {
                mNavigationBarHeight = mResources.getDimensionPixelSize(navBarHeightId);
            } else {
                mNavigationBarHeight = dpToPx(DEFAULT_NAV_BAR_HEIGHT_DP);
            }
        }

        return mNavigationBarHeight;
    }


    private void updateOverlayFlag(MethodChannel.Result result, String flag) {
        if (windowManager != null && flutterView != null) {
            WindowSetup.setFlag(flag);
            WindowManager.LayoutParams params = (WindowManager.LayoutParams) flutterView.getLayoutParams();
            params.flags = WindowSetup.flag | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS |
                    WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN |
                    WindowManager.LayoutParams.FLAG_LAYOUT_INSET_DECOR | WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && WindowSetup.flag == clickableFlag) {
                params.alpha = MAXIMUM_OPACITY_ALLOWED_FOR_S_AND_HIGHER;
            } else {
                params.alpha = 1;
            }
            try {
                windowManager.updateViewLayout(flutterView, params);
                result.success(true);
            } catch (Exception e) {
                Log.e("OverlayService", "updateOverlayFlag: updateViewLayout failed (permission revoked or view detached)", e);
                result.success(false);
            }
            // 穿透状态变了：通知栏按钮要跟着出现 / 消失。
            refreshNotification();
        } else {
            result.success(false);
        }
    }

    /** 当前窗口是否处于点击穿透态（不可触摸）。 */
    private boolean isClickThroughEnabled() {
        return WindowSetup.flag == clickableFlag;
    }

    /**
     * 构建前台服务通知。点击穿透开启时附一个「关闭点击穿透」动作：
     * 穿透态下悬浮窗收不到触摸，通知栏是窗内唯一可用的就地关闭入口。
     */
    private Notification buildOverlayNotification() {
        Intent notificationIntent = new Intent(this, FlutterOverlayWindowPlugin.class);
        int pendingFlags;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            pendingFlags = PendingIntent.FLAG_IMMUTABLE;
        } else {
            pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT;
        }
        PendingIntent pendingIntent = PendingIntent.getActivity(this,
                0, notificationIntent, pendingFlags);
        final int notifyIcon = getDrawableResourceId("mipmap", "launcher");
        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, OverlayConstants.CHANNEL_ID)
                .setContentTitle(WindowSetup.overlayTitle)
                .setContentText(WindowSetup.overlayContent)
                .setSmallIcon(notifyIcon == 0 ? R.drawable.notification_icon : notifyIcon)
                .setContentIntent(pendingIntent)
                .setVisibility(WindowSetup.notificationVisibility)
                // PRIORITY_LOW + silent: no heads-up banner / no sound for the
                // required foreground-service notification (covers pre-O too,
                // where importance is taken from the notification priority).
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setSilent(true)
                .setOnlyAlertOnce(true);
        if (isClickThroughEnabled()) {
            Intent actionIntent = new Intent(this, OverlayService.class);
            actionIntent.setAction(ACTION_DISABLE_CLICK_THROUGH);
            PendingIntent actionPending = PendingIntent.getService(this, 1, actionIntent, pendingFlags);
            // 动作图标沿用通知本身的小图标：Android 7 及以下会按图标渲染动作项，传 0 会显示空白。
            builder.addAction(new NotificationCompat.Action(
                    notifyIcon == 0 ? R.drawable.notification_icon : notifyIcon,
                    "关闭点击穿透", actionPending));
        }
        return builder.build();
    }

    /** 刷新前台服务通知（穿透开关变化后需要增删「关闭点击穿透」按钮）。 */
    private void refreshNotification() {
        try {
            NotificationManager manager = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (manager != null) {
                manager.notify(OverlayConstants.NOTIFICATION_ID, buildOverlayNotification());
            }
        } catch (Throwable t) {
            Log.w("OverlayService", "refreshNotification failed (non-fatal)", t);
        }
    }

    /**
     * 通知栏「关闭点击穿透」：把窗口 flag 改回可触摸，并通知悬浮窗同步本地开关。
     *
     * 不走 onStartCommand 的正常建窗流程——那会 detach 并重建窗口，
     * 已建立的弹幕连接会被全部断开。
     */
    private void disableClickThroughFromNotification() {
        if (windowManager == null || flutterView == null) {
            Log.w("OverlayService", "Click-through action ignored: overlay window is not active");
            return;
        }
        WindowSetup.setFlag("defaultFlag");
        WindowManager.LayoutParams params = (WindowManager.LayoutParams) flutterView.getLayoutParams();
        params.flags = WindowSetup.flag | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS |
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN |
                WindowManager.LayoutParams.FLAG_LAYOUT_INSET_DECOR | WindowManager.LayoutParams.FLAG_HARDWARE_ACCELERATED;
        params.alpha = 1;
        try {
            windowManager.updateViewLayout(flutterView, params);
        } catch (Exception e) {
            Log.e("OverlayService", "Click-through action: updateViewLayout failed", e);
        }
        // 让悬浮窗把本地开关与待落盘增量同步过去（主 App 随后会落盘该偏好）。
        if (overlayMessageChannel != null) {
            Map<String, Object> payload = new HashMap<>();
            payload.put("type", "clickThrough");
            payload.put("value", false);
            overlayMessageChannel.send(payload);
        }
        refreshNotification();
    }

    private void resizeOverlay(int width, int height, boolean enableDrag, MethodChannel.Result result) {
        if (windowManager != null && flutterView != null) {
            WindowManager.LayoutParams params = (WindowManager.LayoutParams) flutterView.getLayoutParams();
            params.width = (width == -1999 || width == -1) ? -1 : dpToPx(width);
            // Fixed: was (height != 1999 || height != -1) which is always true.
            params.height = (height == -1999 || height == -1) ? -1 : dpToPx(height);
            WindowSetup.enableDrag = enableDrag;
            try {
                windowManager.updateViewLayout(flutterView, params);
                result.success(true);
            } catch (Exception e) {
                Log.e("OverlayService", "resizeOverlay: updateViewLayout failed (permission revoked or view detached)", e);
                result.success(false);
            }
        } else {
            result.success(false);
        }
    }

    private void moveOverlay(int x, int y, MethodChannel.Result result) {
        if (windowManager != null && flutterView != null) {
            WindowManager.LayoutParams params = (WindowManager.LayoutParams) flutterView.getLayoutParams();
            params.x = (x == -1999 || x == -1) ? -1 : dpToPx(x);
            params.y = dpToPx(y);
            try {
                windowManager.updateViewLayout(flutterView, params);
                if (result != null) result.success(true);
            } catch (Exception e) {
                Log.e("OverlayService", "moveOverlay: updateViewLayout failed (permission revoked or view detached)", e);
                if (result != null) result.success(false);
            }
        } else {
            if (result != null) result.success(false);
        }
    }


    public static Map<String, Double> getCurrentPosition() {
        if (instance != null && instance.flutterView != null) {
            WindowManager.LayoutParams params = (WindowManager.LayoutParams) instance.flutterView.getLayoutParams();
            Map<String, Double> position = new HashMap<>();
            position.put("x", instance.pxToDp(params.x));
            position.put("y", instance.pxToDp(params.y));
            return position;
        }
        return null;
    }

    public static boolean moveOverlay(int x, int y) {
        if (instance != null && instance.flutterView != null) {
            if (instance.windowManager != null) {
                WindowManager.LayoutParams params = (WindowManager.LayoutParams) instance.flutterView.getLayoutParams();
                params.x = (x == -1999 || x == -1) ? -1 : instance.dpToPx(x);
                params.y = instance.dpToPx(y);
                instance.windowManager.updateViewLayout(instance.flutterView, params);
                return true;
            } else {
                return false;
            }
        } else {
            return false;
        }
    }


    @Override
    public void onCreate() {
        // Get the cached FlutterEngine
        FlutterEngine flutterEngine = FlutterEngineCache.getInstance().get(OverlayConstants.CACHED_TAG);

        if (flutterEngine == null) {
            // Handle the error if engine is not found
            Log.e("OverlayService", "Flutter engine not found, hence creating new flutter engine");
            FlutterEngineGroup engineGroup = new FlutterEngineGroup(this);
            DartExecutor.DartEntrypoint entryPoint = new DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                "overlayMain"
            );  // "overlayMain" is custom entry point

            flutterEngine = engineGroup.createAndRunEngine(this, entryPoint);

            // Cache the created FlutterEngine for future use
            FlutterEngineCache.getInstance().put(OverlayConstants.CACHED_TAG, flutterEngine);
        }

        // Create the MethodChannel with the properly initialized FlutterEngine
        if (flutterEngine != null) {
            flutterChannel = new MethodChannel(flutterEngine.getDartExecutor(), OverlayConstants.OVERLAY_TAG);
            overlayMessageChannel = new BasicMessageChannel(flutterEngine.getDartExecutor(), OverlayConstants.MESSENGER_TAG, JSONMessageCodec.INSTANCE);
        }

        createNotificationChannel();
        // Guard: on Android 12+ the system throws ForegroundServiceStartNotAllowedException
        // when startForeground() is called but the app no longer has a foreground context
        // (e.g. the Activity finished its paused→stopped transition between the
        // startForegroundService() call and this onCreate() execution).
        // Catching Exception rather than the API-31 class keeps us compatible with
        // lower minSdk compilations while still handling the crash gracefully.
        try {
            startForeground(OverlayConstants.NOTIFICATION_ID, buildOverlayNotification());
        } catch (Exception e) {
            Log.e("OverlayService", "startForeground failed — app may have gone to background before service started. Stopping service.", e);
            stopSelf();
            return;
        }
        instance = this;
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // IMPORTANCE_LOW: the foreground-service notification is REQUIRED by
            // Android but must NOT heads-up as a banner or make a sound when the
            // overlay shows (esp. unlocked + app in background on HyperOS, where
            // IMPORTANCE_DEFAULT peeked as a banner). LOW = visible only in the
            // shade, no banner, no sound.
            NotificationChannel serviceChannel = new NotificationChannel(
                    OverlayConstants.CHANNEL_ID,
                    "Foreground Service Channel",
                    NotificationManager.IMPORTANCE_LOW
            );
            serviceChannel.setSound(null, null);
            serviceChannel.enableVibration(false);
            NotificationManager manager = getSystemService(NotificationManager.class);
            assert manager != null;
            manager.createNotificationChannel(serviceChannel);
        }
    }

    private int getDrawableResourceId(String resType, String name) {
        return getApplicationContext().getResources().getIdentifier(String.format("ic_%s", name), resType, getApplicationContext().getPackageName());
    }

    private int dpToPx(int dp) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP,
                Float.parseFloat(dp + ""), mResources.getDisplayMetrics());
    }

    private double pxToDp(int px) {
        return (double) px / mResources.getDisplayMetrics().density;
    }

    private boolean inPortrait() {
        return mResources.getConfiguration().orientation == Configuration.ORIENTATION_PORTRAIT;
    }

    /** 刷新缓存的屏幕像素尺寸 szWindow：建窗与横竖屏切换后都要重取。 */
    private void refreshScreenSize() {
        if (windowManager == null) return;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.HONEYCOMB) {
            windowManager.getDefaultDisplay().getSize(szWindow);
        } else {
            DisplayMetrics displaymetrics = new DisplayMetrics();
            windowManager.getDefaultDisplay().getMetrics(displaymetrics);
            szWindow.set(displaymetrics.widthPixels, displaymetrics.heightPixels);
        }
    }

    /**
     * 把窗口偏移收敛回屏幕可见范围内（旋转 / 改尺寸后避免窗口被摆到屏幕外）。
     *
     * 水平方向贴左 / 贴右都是从对应边缘起算，可用范围同为 0 ~ 屏幕宽-窗宽；
     * 垂直方向按 TOP / CENTER / BOTTOM 分别换算。
     */
    private void clampPositionToScreen(WindowManager.LayoutParams params) {
        int width = flutterView != null ? flutterView.getWidth() : 0;
        int height = flutterView != null ? flutterView.getHeight() : 0;
        if (width <= 0) width = params.width > 0 ? params.width : szWindow.x;
        if (height <= 0) height = params.height > 0 ? params.height : szWindow.y;
        int maxX = Math.max(0, szWindow.x - width);
        params.x = Math.max(0, Math.min(params.x, maxX));
        int maxY = Math.max(0, szWindow.y - height);
        int verticalGravity = params.gravity & Gravity.VERTICAL_GRAVITY_MASK;
        if (verticalGravity == Gravity.CENTER_VERTICAL) {
            int half = maxY / 2;
            params.y = Math.max(-half, Math.min(params.y, half));
        } else if (verticalGravity == Gravity.BOTTOM) {
            params.y = Math.max(0, Math.min(params.y, maxY));
        } else {
            params.y = Math.max(0, Math.min(params.y, maxY));
        }
    }

    /**
     * 上报窗口当前位置（dp）给悬浮窗，由其并入偏好增量交主 App 落盘。
     *
     * 只在拖动结束（无吸附）或贴边吸附动画收敛时调用，必须在平台主线程上执行。
     */
    private void reportOverlayPosition() {
        if (overlayMessageChannel == null || flutterView == null) return;
        WindowManager.LayoutParams params = (WindowManager.LayoutParams) flutterView.getLayoutParams();
        if (params == null) return;
        Map<String, Object> payload = new HashMap<>();
        payload.put("type", "position");
        payload.put("x", pxToDp(params.x));
        payload.put("y", pxToDp(params.y));
        overlayMessageChannel.send(payload);
    }

    @Override
    public void onConfigurationChanged(Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        // Recalculate overlay height when the device is rotated so the window
        // dimensions remain valid (portrait vs landscape heights differ).
        if (windowManager == null || flutterView == null) return;
        try {
            // 必须刷新缓存屏幕尺寸：贴边吸附按 szWindow 计算水平停靠点，沿用旧值会把
            // 横屏下的可拖动范围压回竖屏宽度（用户反馈横屏拖不动）。
            refreshScreenSize();
            WindowManager.LayoutParams params = (WindowManager.LayoutParams) flutterView.getLayoutParams();
            // Only adjust full-height overlays; fixed-size overlays (booking card) are left alone.
            if (params.height < 0) {
                params.height = screenHeight();
            }
            // 旋转后窗口可能落到屏幕外：把水平 / 垂直偏移收敛回可见范围。
            clampPositionToScreen(params);
            windowManager.updateViewLayout(flutterView, params);
            Log.d("OverlayService", "onConfigurationChanged: overlay layout refreshed");
        } catch (Exception e) {
            Log.e("OverlayService", "onConfigurationChanged: failed to update overlay layout", e);
        }
    }

    @Override
    public boolean onTouch(View view, MotionEvent event) {
        // Guard: flutterView may be null if detachOverlayView() ran concurrently
        // (e.g. closeOverlay called while a touch event is being processed).
        if (windowManager == null || flutterView == null || !WindowSetup.enableDrag) {
            return false;
        }
        WindowManager.LayoutParams params = (WindowManager.LayoutParams) flutterView.getLayoutParams();
        switch (event.getAction()) {
            case MotionEvent.ACTION_DOWN:
                dragging = false;
                lastX = event.getRawX();
                lastY = event.getRawY();
                break;
            case MotionEvent.ACTION_MOVE:
                float dx = event.getRawX() - lastX;
                float dy = event.getRawY() - lastY;
                if (!dragging && dx * dx + dy * dy < 25) {
                    return false;
                }
                lastX = event.getRawX();
                lastY = event.getRawY();
                boolean invertX = WindowSetup.gravity == (Gravity.TOP | Gravity.RIGHT)
                        || WindowSetup.gravity == (Gravity.CENTER | Gravity.RIGHT)
                        || WindowSetup.gravity == (Gravity.BOTTOM | Gravity.RIGHT);
                boolean invertY = WindowSetup.gravity == (Gravity.BOTTOM | Gravity.LEFT)
                        || WindowSetup.gravity == Gravity.BOTTOM
                        || WindowSetup.gravity == (Gravity.BOTTOM | Gravity.RIGHT);
                int xx = params.x + ((int) dx * (invertX ? -1 : 1));
                int yy = params.y + ((int) dy * (invertY ? -1 : 1));
                params.x = xx;
                params.y = yy;
                try {
                    windowManager.updateViewLayout(flutterView, params);
                } catch (Exception e) {
                    Log.e("OverlayService", "onTouch ACTION_MOVE: updateViewLayout failed", e);
                }
                dragging = true;
                break;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL:
                // Re-check flutterView: detachOverlayView() may have run between ACTION_DOWN and ACTION_UP.
                if (flutterView == null || windowManager == null) return false;
                // 只是点了一下没有位移：位置没变，不必上报。
                if (!dragging) return false;
                lastYPosition = params.y;
                if (WindowSetup.positionGravity != null && !WindowSetup.positionGravity.equals("none")) {
                    try {
                        windowManager.updateViewLayout(flutterView, params);
                        // Cancel any in-flight animation before starting a new one.
                        if (mTrayAnimationTimer != null) {
                            mTrayAnimationTimer.cancel();
                            mTrayAnimationTimer = null;
                        }
                        mTrayTimerTask = new TrayAnimationTimerTask();
                        mTrayAnimationTimer = new Timer();
                        mTrayAnimationTimer.schedule(mTrayTimerTask, 0, 25);
                    } catch (Exception e) {
                        Log.e("OverlayService", "onTouch ACTION_UP: layout update or timer failed", e);
                    }
                } else {
                    // 无吸附：松手位置即最终位置，直接上报给悬浮窗落盘。
                    reportOverlayPosition();
                }
                return false;
            default:
                return false;
        }
        return false;
    }

    private class TrayAnimationTimerTask extends TimerTask {
        int mDestX;
        int mDestY;
        // Snapshot layout params at construction time.
        // Guard: flutterView can be null if detachOverlayView() races with ACTION_UP.
        final WindowManager.LayoutParams params;

        public TrayAnimationTimerTask() {
            super();
            if (flutterView == null) {
                // Service is shutting down; provide safe defaults so run() is a no-op.
                params = null;
                mDestX = 0;
                mDestY = 0;
                return;
            }
            params = (WindowManager.LayoutParams) flutterView.getLayoutParams();
            mDestY = lastYPosition;
            switch (WindowSetup.positionGravity) {
                case "auto":
                    mDestX = (params.x + (flutterView.getWidth() / 2)) <= szWindow.x / 2 ? 0 : szWindow.x - flutterView.getWidth();
                    return;
                case "left":
                    mDestX = 0;
                    return;
                case "right":
                    mDestX = szWindow.x - flutterView.getWidth();
                    return;
                default:
                    mDestX = params.x;
                    mDestY = params.y;
                    break;
            }
        }

        @Override
        public void run() {
            if (params == null) {
                // Constructor bailed out because flutterView was null; stop immediately.
                TrayAnimationTimerTask.this.cancel();
                return;
            }
            mAnimationHandler.post(() -> {
                // Guard: flutterView or windowManager may have become null while the
                // timer was scheduled (overlay closed between touch-up and animation tick).
                if (windowManager == null || flutterView == null) {
                    TrayAnimationTimerTask.this.cancel();
                    if (mTrayAnimationTimer != null) mTrayAnimationTimer.cancel();
                    return;
                }
                params.x = (2 * (params.x - mDestX)) / 3 + mDestX;
                params.y = (2 * (params.y - mDestY)) / 3 + mDestY;
                try {
                    windowManager.updateViewLayout(flutterView, params);
                } catch (Exception e) {
                    Log.e("OverlayService", "TrayAnimation: updateViewLayout failed — stopping animation", e);
                    TrayAnimationTimerTask.this.cancel();
                    if (mTrayAnimationTimer != null) mTrayAnimationTimer.cancel();
                    return;
                }
                if (Math.abs(params.x - mDestX) < 2 && Math.abs(params.y - mDestY) < 2) {
                    // 收敛到吸附点：此刻才是最终位置，上报给悬浮窗落盘。
                    reportOverlayPosition();
                    TrayAnimationTimerTask.this.cancel();
                    mTrayAnimationTimer.cancel();
                }
            });
        }
    }


}
