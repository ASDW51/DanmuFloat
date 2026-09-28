package flutter.overlay.window.flutter_overlay_window;


import android.view.Gravity;
import android.view.WindowManager;

import androidx.core.app.NotificationCompat;

import io.flutter.plugin.common.BasicMessageChannel;

public abstract class WindowSetup {

    static int height = WindowManager.LayoutParams.MATCH_PARENT;
    static int width = WindowManager.LayoutParams.MATCH_PARENT;
    static int flag = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE;
    static int gravity = Gravity.CENTER;
    static BasicMessageChannel<Object> messenger = null;
    /**
     * 主引擎上的 overlay_messenger 通道，供 OverlayService 把悬浮窗的上行消息转发回主 App。
     *
     * 不能用 [messenger] 代替：那个字段谁最后附着插件就指向谁，悬浮窗引擎附着时会被覆盖成
     * 悬浮窗自己的通道，转发出去的消息会原路弹回悬浮窗。这个字段由主引擎处理 showOverlay
     * 时写入（见 FlutterOverlayWindowPlugin#onMethodCall），每次开窗刷新，
     * 因此既不受字段覆盖影响，也不受悬浮窗引擎缓存复用影响。
     */
    static BasicMessageChannel<Object> upstreamMessenger = null;
    static String overlayTitle = "Overlay is activated";
    static String overlayContent = "Tap to edit settings or disable";
    static String positionGravity = "none";
    static int notificationVisibility = NotificationCompat.VISIBILITY_PRIVATE;
    static boolean enableDrag = false;
    /** When true the overlay will wake the screen and show above the lock screen. */
    static boolean wakeScreen = false;


    static void setNotificationVisibility(String name) {
        if (name.equalsIgnoreCase("visibilityPublic")) {
            notificationVisibility = NotificationCompat.VISIBILITY_PUBLIC;
        }
        if (name.equalsIgnoreCase("visibilitySecret")) {
            notificationVisibility = NotificationCompat.VISIBILITY_SECRET;
        }
        if (name.equalsIgnoreCase("visibilityPrivate")) {
            notificationVisibility = NotificationCompat.VISIBILITY_PRIVATE;
        }
    }

    static void setFlag(String name) {
        if (name.equalsIgnoreCase("flagNotFocusable") || name.equalsIgnoreCase("defaultFlag")) {
            flag = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE;
        }
        if (name.equalsIgnoreCase("flagNotTouchable") || name.equalsIgnoreCase("clickThrough")) {
            flag = WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE | WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE |
                    WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN;
        }
        if (name.equalsIgnoreCase("flagNotTouchModal") || name.equalsIgnoreCase("focusPointer")) {
            flag = WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL;
        }
    }

    static void setWakeScreen(boolean wake) {
        wakeScreen = wake;
    }

    static void setGravityFromAlignment(String alignment) {
        if (alignment.equalsIgnoreCase("topLeft")) {
            gravity = Gravity.TOP | Gravity.LEFT;
            return;
        }
        if (alignment.equalsIgnoreCase("topCenter")) {
            gravity = Gravity.TOP;
        }
        if (alignment.equalsIgnoreCase("topRight")) {
            gravity = Gravity.TOP | Gravity.RIGHT;
            return;
        }

        if (alignment.equalsIgnoreCase("centerLeft")) {
            gravity = Gravity.CENTER | Gravity.LEFT;
            return;
        }
        if (alignment.equalsIgnoreCase("center")) {
            gravity = Gravity.CENTER;
        }
        if (alignment.equalsIgnoreCase("centerRight")) {
            gravity = Gravity.CENTER | Gravity.RIGHT;
            return;
        }

        if (alignment.equalsIgnoreCase("bottomLeft")) {
            gravity = Gravity.BOTTOM | Gravity.LEFT;
            return;
        }
        if (alignment.equalsIgnoreCase("bottomCenter")) {
            gravity = Gravity.BOTTOM;
        }
        if (alignment.equalsIgnoreCase("bottomRight")) {
            gravity = Gravity.BOTTOM | Gravity.RIGHT;
            return;
        }

    }
}
