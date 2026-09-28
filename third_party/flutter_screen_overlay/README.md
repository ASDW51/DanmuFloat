# flutter_screen_overlay

A Flutter plugin for displaying persistent Android overlay windows above other apps.

Forked and maintained from [flutter_overlay_window](https://github.com/X-SLAYER/flutter_overlay_window) by Iheb Briki, with production stability patches.

[![pub version](https://img.shields.io/pub/v/flutter_screen_overlay.svg?label=pub&color=orange)](https://pub.dev/packages/flutter_screen_overlay)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

---

## Features

- Display a Flutter widget as a system overlay window above all other apps
- Foreground service with persistent notification — survives app backgrounding
- Draggable PiP (Picture-in-Picture) style overlays
- **Null-intent crash recovery** on system-initiated service restarts (production patch)
- Resize and move overlay at runtime
- Send data between main app and overlay via message channels
- Configurable overlay flags (click-through, focusable, pointer)
- Position gravity (snap to left/right edge)

---

## Installation

```yaml
dependencies:
  flutter_screen_overlay: ^1.0.0
```

---

## Android Setup

### 1. Add permissions to `AndroidManifest.xml`

```xml
<uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_SPECIAL_USE" />
```

### 2. Declare the overlay service

```xml
<application>
  ...
  <service
    android:name="flutter.overlay.window.flutter_overlay_window.OverlayService"
    android:exported="false"
    android:foregroundServiceType="specialUse">
    <property
      android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"
      android:value="Displays app content as an overlay above other apps" />
  </service>
</application>
```

---

## Overlay Entry Point

In `main.dart`, define a separate entry point for your overlay widget:

```dart
@pragma('vm:entry-point')
void overlayMain() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Material(child: Text("My overlay")),
  ));
}
```

---

## Usage

```dart
import 'package:flutter_screen_overlay/flutter_screen_overlay.dart';

// Check and request permission
final bool hasPermission = await FlutterScreenOverlay.isPermissionGranted();
if (!hasPermission) {
  await FlutterScreenOverlay.requestPermission();
}

// Show fullscreen overlay
await FlutterScreenOverlay.showOverlay(
  height: WindowSize.matchParent,
  width: WindowSize.matchParent,
  alignment: OverlayAlignment.center,
  flag: OverlayFlag.defaultFlag,
  overlayTitle: 'My App',
  overlayContent: 'Running in background',
  enableDrag: false,
);

// Show draggable PiP overlay
await FlutterScreenOverlay.showOverlay(
  height: 100,
  width: 100,
  alignment: OverlayAlignment.centerRight,
  flag: OverlayFlag.defaultFlag,
  enableDrag: true,
  positionGravity: PositionGravity.auto,
);

// Send data to overlay
await FlutterScreenOverlay.shareData({'status': 'active'});

// Listen for data in overlay entry point
FlutterScreenOverlay.overlayListener.listen((event) {
  print('Received: $event');
});

// Check if active
final bool isActive = await FlutterScreenOverlay.isActive();

// Resize at runtime
await FlutterScreenOverlay.resizeOverlay(200, 200, enableDrag: true);

// Move overlay
await FlutterScreenOverlay.moveOverlay(OverlayPosition(0, 150));

// Update flag at runtime
await FlutterScreenOverlay.updateFlag(OverlayFlag.focusPointer);

// Close overlay
await FlutterScreenOverlay.closeOverlay();
```

---

## API Reference

| Method | Description |
|---|---|
| `showOverlay({...})` | Show the overlay window |
| `closeOverlay()` | Close and destroy the overlay |
| `isActive()` | Returns `true` if overlay is currently showing |
| `isPermissionGranted()` | Returns `true` if SYSTEM_ALERT_WINDOW permission is granted |
| `requestPermission()` | Opens system permission settings |
| `shareData(dynamic data)` | Send data from main app to overlay |
| `overlayListener` | Stream of data sent from main app (listen in overlay) |
| `resizeOverlay(width, height, enableDrag)` | Resize overlay at runtime |
| `moveOverlay(OverlayPosition)` | Move overlay to a specific position |
| `getOverlayPosition()` | Get current overlay position |
| `updateFlag(OverlayFlag)` | Update overlay window flag at runtime |

### `WindowSize`

| Constant | Description |
|---|---|
| `matchParent` | Full screen width or height |
| `fullCover` | Covers status bar and navigation bar |

### `OverlayFlag`

| Value | Description |
|---|---|
| `defaultFlag` | Window won't receive key focus |
| `clickThrough` | Window never receives touch events |
| `focusPointer` | Pointer events outside window pass through (use with text fields) |

### `OverlayAlignment`

`topLeft` `topCenter` `topRight` `centerLeft` `center` `centerRight` `bottomLeft` `bottomCenter` `bottomRight`

### `PositionGravity`

| Value | Description |
|---|---|
| `none` | Free positioning |
| `left` | Snaps to left edge |
| `right` | Snaps to right edge |
| `auto` | Snaps to nearest edge |

---

## Patches Over Upstream

| Fix | Description |
|---|---|
| Null-intent guard | `onStartCommand` handles `null` intent on Android system restarts — prevents `NullPointerException` crash reported in production |
| Missing engine guard | Graceful `stopSelf` if Flutter engine cache is absent on restart |
| WindowManager null guard | Graceful `stopSelf` if `WindowManager` is unavailable |

---

## License

MIT — see [LICENSE](LICENSE).

Original work © 2022 Iheb Briki. Modifications © 2025 Harshwardhan Vairagade.
