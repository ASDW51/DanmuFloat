## 1.0.7

### `showOverlay` surfaces service-start failures instead of lying

- **`context.startService()` is now wrapped and surfaced as a structured `SERVICE_START` error.** From a background context (the typical booking-wake path) `startService()` throws `IllegalStateException` on Android 8+ unless the process holds a background-start exemption (high-priority FCM window / battery-optimization exemption). Previously the exception propagated as an uncaught platform error *after* `WindowSetup` was already mutated, and hosts had no reliable signal that the overlay would never appear. Now `showOverlay` returns a `PlatformException(code: "SERVICE_START")` the host can catch to fall back to another alert surface (e.g. a full-screen-intent notification).

## 1.0.6

### Foreground-service notification is now silent / non-intrusive (no banner)

- **`OverlayService` notification channel lowered from `IMPORTANCE_DEFAULT` to `IMPORTANCE_LOW`** + `setSound(null)` + `enableVibration(false)`, and the notification builder now sets `PRIORITY_LOW` + `setSilent(true)` + `setOnlyAlertOnce(true)`. The foreground-service notification Android REQUIRES while an overlay is shown no longer **heads-up as a banner** or makes a sound — it appears only in the notification shade. Fixes the "notification banner when the overlay shows (device unlocked, app in background)" on OEMs (notably Xiaomi/HyperOS) that peek `IMPORTANCE_DEFAULT` notifications.
- **`OverlayConstants.CHANNEL_ID` bumped `"Overlay Channel"` → `"Overlay Channel Low"`** so the new importance applies to EXISTING installs too — Android ignores importance changes to an already-created channel, so a new channel id is required to actually drop it out of the heads-up tier.
- No API change; fully backward compatible.

## 1.0.5

### Pre-warm — `FlutterScreenOverlay.warmUp()` (instant overlay after background wake)

- **New `warmUp()` Dart API** + native `warmUpEngine` method channel handler. Creates and caches the overlay Flutter engine (running the `overlayMain` entrypoint) **without needing an Activity**, so the first `showOverlay()` paints in well under a second instead of cold-booting `overlayMain` (~5 s).
- **Why:** the engine was only ever created in `onAttachedToActivity` (app UI launch) or lazily in `OverlayService`. When a booking wakes the app **in the background** (e.g. a silent FCM data-wake) there is no Activity, so the engine cold-booted only when `showOverlay` was finally called on unlock — a ~5 s blank. `warmUp()` lets the host pre-create the engine on go-online and on background-service start.
- **`ensureOverlayEngineWarm()` helper** extracted; `onAttachedToActivity` now delegates to it (behaviour unchanged). Idempotent — a no-op when the engine is already cached, so it is safe to call repeatedly from multiple isolates (the cache is process-wide).
- Fully backward compatible — no change to any existing API.

## 1.0.4 — 2026-04-19

### showOverlay — `wakeScreen` parameter (lock-screen booking alerts)

- **New `wakeScreen` parameter** added to `showOverlay()` (Dart API, defaults to `false` — fully backward compatible). When `true`, the overlay wakes the device screen and renders above the lock screen.
- **`OverlayService` — WakeLock on screen wake**: Acquires `SCREEN_BRIGHT_WAKE_LOCK | ACQUIRE_CAUSES_WAKEUP` after a successful `addView()` so the screen turns on even from deep sleep. WakeLock is stored as an instance field, released in `onDestroy()`, and auto-releases after 12 seconds as a leak-proof fallback. Both acquire and release are wrapped in `try-catch(Throwable)`.
- **`OverlayService` — `FLAG_TURN_SCREEN_ON | FLAG_SHOW_WHEN_LOCKED` on `LayoutParams`**: Applied to the window params before `addView()` when `wakeScreen` is true, as a belt-and-suspenders complement to the WakeLock.
- **`WindowSetup` — `showWhenLocked()` method fixed**: Previous implementation was a dead copy-paste of `setFlag()` and had no effect. Replaced with `setWakeScreen(boolean)` which sets the new `wakeScreen` field read by `OverlayService`.
- **`FlutterOverlayWindowPlugin`** reads the new `wakeScreen` argument from the method call and routes it to `WindowSetup.setWakeScreen()`.

## 1.0.3 — 2026-04-14

### OverlayService — crash hardening (all Android versions)

- **`flutterView` NPE guards**: `updateOverlayFlag`, `resizeOverlay`, `moveOverlay`, and `onTouch` all now check `flutterView != null` before use. Previously, a method-channel call or touch event arriving just after `detachOverlayView()` zeroed the reference would throw a `NullPointerException`.
- **`call.argument()` null safety**: Method-channel handler in `onStartCommand` now validates all arguments (`flag`, `x`, `y`, `width`, `height`, `enableDrag`) before use and returns a descriptive error instead of crashing on `.toString()` / unboxing.
- **`windowManager.addView()` `BadTokenException` guard**: Wrapped in try-catch. If the window token is invalid (Activity destroyed while service was starting), the service stops cleanly instead of crashing the process.
- **`updateViewLayout` / `updateViewLayout` guards**: All `windowManager.updateViewLayout()` calls in `updateOverlayFlag`, `resizeOverlay`, `moveOverlay`, and `onTouch` are now wrapped in try-catch so a revoked `SYSTEM_ALERT_WINDOW` permission or a stale view reference causes a graceful log+fail rather than an unhandled exception.
- **`resizeOverlay` boolean logic fix**: Height condition was `(height != 1999 || height != -1)` — always `true` due to OR. Fixed to `(height == -1999 || height == -1)`, matching the width logic.
- **Timer leak in `onDestroy`**: `mTrayAnimationTimer` and `mTrayTimerTask` are now cancelled before `detachOverlayView()` so the animation tick cannot call `updateViewLayout` on a removed view.
- **`TrayAnimationTimerTask` null safety**: Constructor checks `flutterView != null` and provides safe defaults if the service is shutting down. `run()` re-checks `windowManager` and `flutterView` on every tick and cancels itself if either is null.
- **In-flight animation cancel on ACTION_UP**: Cancels any existing `mTrayAnimationTimer` before scheduling a new one, preventing double-animation from rapid touch events.
- **`onConfigurationChanged` implemented**: Recalculates and applies overlay height on screen rotation so full-height overlays remain valid after orientation change.

### FlutterOverlayWindowPlugin — crash hardening

- **`pendingResult` NPE in `onActivityResult`**: Added null check; `pendingResult` is cleared after use to prevent double-reply.
- **`onMessage` engine NPE**: Checks for null engine in `FlutterEngineCache` before calling `getDartExecutor()`. Drops the message gracefully if engine was evicted under memory pressure.
- **Duplicate `isOverlayActive` handler removed**: Dead duplicate branch eliminated.
- **`closeOverlay` always replies**: Previously returned without calling `result.success()` when the overlay was not running, leaving Dart awaiting a response forever. Now returns `result.success(false)`.

## 1.0.2 — 2026-04-14

- **ForegroundServiceStartNotAllowedException guard**: `OverlayService.onCreate` now wraps `startForeground()` in a try-catch. On Android 12+ the system can reject the call when the app transitions from paused to stopped between the `startForegroundService()` dispatch and the service `onCreate()` execution. Previously this threw an unhandled `RuntimeException` and crashed the process. The service now logs the error and calls `stopSelf()` instead, so the overlay silently fails to appear rather than killing the app.

## 1.0.1 — 2026-04-12

- Rename public API class `FlutterOverlayWindow` → `FlutterScreenOverlay` to match package name and eliminate developer confusion.
- Rename library file `flutter_overlay_window.dart` → `flutter_screen_overlay.dart`.
- Update all internal imports from package-prefixed to relative paths.

## 1.0.0 — 2026-04-12

Initial release as `flutter_screen_overlay` (forked from `flutter_overlay_window` v0.5.0).

### Patches included over upstream

- **Null-intent guard**: `OverlayService.onStartCommand` now safely handles `null`
  intent passed by Android on system-initiated service restarts. Previously caused
  a `NullPointerException` crash (reported via Google Play). Returns `START_NOT_STICKY`
  to prevent crash loop.
- **Missing engine guard**: Graceful `stopSelf` when Flutter engine is absent from
  cache on restart — prevents `IllegalStateException`.
- **WindowManager null guard**: Graceful `stopSelf` when `WindowManager` is
  unavailable — defensive check for edge-case device/OS behaviour.

### Inherited from flutter_overlay_window v0.5.0

- Foreground service with persistent notification
- Draggable PiP-style overlays with position gravity (snap to edge)
- Runtime resize and move
- Bidirectional data channel between main app and overlay
- Configurable overlay flags (defaultFlag, clickThrough, focusPointer)
- Android 12+ opacity enforcement
- `startPosition` parameter for initial overlay placement
- `moveOverlay` / `getOverlayPosition` API
