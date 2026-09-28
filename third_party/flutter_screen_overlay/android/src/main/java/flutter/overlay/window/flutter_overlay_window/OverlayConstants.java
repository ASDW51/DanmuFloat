package flutter.overlay.window.flutter_overlay_window;

final public class OverlayConstants {

    static final String CACHED_TAG = "myCachedEngine";
    static final String CHANNEL_TAG = "x-slayer/overlay_channel";
    static final String OVERLAY_TAG = "x-slayer/overlay";
    static final String MESSENGER_TAG = "x-slayer/overlay_messenger";
    // Bumped from "Overlay Channel" so the lowered IMPORTANCE_LOW takes effect on
    // EXISTING installs too — Android ignores importance changes to an
    // already-created channel, so a new id is required to drop the foreground-
    // service notification out of the heads-up/banner tier.
    static final String CHANNEL_ID = "Overlay Channel Low";
    static final int NOTIFICATION_ID = 4579;
    static final int DEFAULT_XY = -6;
}
