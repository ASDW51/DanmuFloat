// 悬浮窗分栏配置持久化：JSON 结构、透明度收敛与落盘往返。
import 'dart:io';

import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('clampOverlayOpacity', () {
    test('超出范围的取值被收敛到上下界', () {
      expect(clampOverlayOpacity(-0.5), minOverlayOpacity);
      expect(clampOverlayOpacity(1.5), maxOverlayOpacity);
      expect(clampOverlayOpacity(0.5), 0.5);
    });

    test('0 与 1 是合法取值，不再被夹到 0.2 / 0.8', () {
      expect(minOverlayOpacity, 0.0);
      expect(maxOverlayOpacity, 1.0);
      expect(clampOverlayOpacity(0.0), 0.0);
      expect(clampOverlayOpacity(1.0), 1.0);
    });

    test('NaN 回落默认值，避免写进渲染层报错', () {
      expect(clampOverlayOpacity(double.nan), defaultOverlayOpacity);
    });
  });

  group('OverlayPrefs', () {
    test('经 JSON 往返后保留栏位绑定顺序、透明度、字号、滚动速度与窗口尺寸', () {
      final OverlayPrefs? parsed = OverlayPrefs.tryParse(
        const OverlayPrefs(
          webRids: <String>['735', '736', '737'],
          opacity: 0.6,
          fontSize: 18,
          scrollSpeed: 2.25,
          windowWidth: 640,
          windowHeight: 720,
        ).toJson(),
      );

      expect(parsed, isNotNull);
      expect(parsed!.webRids, <String>['735', '736', '737']);
      expect(parsed.opacity, 0.6);
      expect(parsed.fontSize, 18);
      expect(parsed.scrollSpeed, 2.25);
      expect(parsed.windowSize, (width: 640.0, height: 720.0));
    });

    test('越界的字号、滚动速度与尺寸在写文件前就被收敛', () {
      final Map<String, Object?> json = const OverlayPrefs(
        fontSize: 100,
        scrollSpeed: 10,
        windowWidth: 10,
        windowHeight: 9000,
      ).toJson();
      expect(json['fontSize'], maxDanmuFontSize);
      expect(json['scrollSpeed'], maxDanmuScrollSpeed);

      final OverlayPrefs? parsed = OverlayPrefs.tryParse(json);
      expect(parsed!.windowSize, (
        width: minOverlayWidth,
        height: maxOverlayHeight,
      ));
    });

    test('panes 缺序号时按出现顺序补位，空房间与坏记录被跳过', () {
      final OverlayPrefs? parsed = OverlayPrefs.tryParse(<String, Object?>{
        'panes': <Object?>[
          <String, Object?>{'room_id': ' 735 '},
          'not a map',
          <String, Object?>{'room_id': '   '},
          <String, Object?>{'index': 0, 'room_id': '736'},
        ],
      });

      // 736 的序号是 0，排到补位的 735 前面。
      expect(parsed!.webRids, <String>['736', '735']);
    });

    test('缺 panes / 非法透明度时回落默认值，结构不符返回 null', () {
      final OverlayPrefs? parsed = OverlayPrefs.tryParse(<String, Object?>{
        'opacity': 'x',
      });
      expect(parsed!.webRids, isEmpty);
      expect(parsed.opacity, defaultOverlayOpacity);
      expect(parsed.fontSize, defaultDanmuFontSize);
      expect(parsed.windowSize, (
        width: defaultOverlayWidth,
        height: defaultOverlayHeight,
      ));
      expect(OverlayPrefs.tryParse('prefs'), isNull);
      expect(OverlayPrefs.tryParse(null), isNull);
    });

    test('组装下发给悬浮窗的配置：网格按房间数推断、透明度与字号收敛', () {
      final OverlayConfig single = const OverlayPrefs(
        opacity: 0.3,
        fontSize: 21,
        scrollSpeed: 2,
      ).toConfig(<String>['735']);
      expect(single.grid.isSingle, isTrue);
      expect(single.opacity, 0.3);
      expect(single.fontSize, 21);
      expect(single.scrollSpeed, 2);

      final OverlayConfig quad = const OverlayPrefs()
          .toConfig(<String>['735', '736', '737']);
      expect(quad.grid.columns, 2);
      expect(quad.grid.rows, 2);
      expect(quad.opacity, defaultOverlayOpacity);
    });

    test('单栏样式按 webRid 写进 panes，往返后仍跟着房间走', () {
      const OverlayPrefs prefs = OverlayPrefs(
        webRids: <String>['735', '736'],
        paneStyles: <String, PaneStyle>{
          '735': PaneStyle(fontSize: 20, textColor: 0xFFFFEB3B),
          '736': PaneStyle(opacity: 0.3),
        },
      );
      final OverlayPrefs? parsed = OverlayPrefs.tryParse(prefs.toJson());
      expect(parsed!.paneStyles['735']!.fontSize, 20);
      expect(parsed.paneStyles['735']!.textColor, 0xFFFFEB3B);
      expect(parsed.paneStyles['736']!.opacity, 0.3);

      // 换栏位顺序不影响样式归属：覆盖键是房间号而不是序号。
      final OverlayPrefs? reordered = OverlayPrefs.tryParse(
        const OverlayPrefs(
          webRids: <String>['736', '735'],
          paneStyles: <String, PaneStyle>{
            '735': PaneStyle(fontSize: 20),
            '736': PaneStyle(opacity: 0.3),
          },
        ).toJson(),
      );
      expect(reordered!.webRids, <String>['736', '735']);
      expect(reordered.paneStyles['735']!.fontSize, 20);
      expect(reordered.paneStyles['736']!.opacity, 0.3);
    });

    test('toConfig 只下发当前绑定房间的样式，解绑房间的覆盖被剔除', () {
      const OverlayPrefs prefs = OverlayPrefs(
        paneStyles: <String, PaneStyle>{
          '735': PaneStyle(fontSize: 20),
          '999': PaneStyle(fontSize: 22),
        },
      );
      final OverlayConfig config = prefs.toConfig(<String>['735']);
      expect(config.paneStyles.keys, <String>['735']);
      expect(config.paneStyles.containsKey('999'), isFalse);
    });

    test('皮肤、栏目标识与焦点模式经 JSON 往返后保留，缺省回落默认值', () {
      final OverlayPrefs? parsed = OverlayPrefs.tryParse(
        const OverlayPrefs(
          lightTheme: true,
          showTitleBar: false,
          focusBehavior: focusBehaviorHide,
        ).toJson(),
      );
      expect(parsed!.lightTheme, isTrue);
      expect(parsed.showTitleBar, isFalse);
      expect(parsed.focusBehavior, focusBehaviorHide);
      // 焦点模式也随 config 下发给悬浮窗。
      final OverlayConfig config = parsed.toConfig(<String>['735']);
      expect(config.lightTheme, isTrue);
      expect(config.showTitleBar, isFalse);
      expect(config.focusBehavior, focusBehaviorHide);

      final OverlayPrefs? legacy =
          OverlayPrefs.tryParse(const OverlayPrefs().toJson());
      expect(legacy!.lightTheme, isFalse);
      expect(legacy.showTitleBar, isTrue);
      expect(legacy.focusBehavior, defaultFocusBehavior);
      // 非法取值在写文件/发消息前就被收敛。
      expect(
        OverlayPrefs.tryParse(
          const OverlayPrefs(focusBehavior: 'no_such').toJson(),
        )!.focusBehavior,
        defaultFocusBehavior,
      );
    });
  });

  group('encodeOverlayPrefs / decodeOverlayPrefs', () {
    test('内容损坏或结构不符返回 null，由调用方回落默认值', () {
      expect(decodeOverlayPrefs(''), isNull);
      expect(decodeOverlayPrefs('{oops'), isNull);
      expect(decodeOverlayPrefs('[]'), isNull);
    });
  });

  group('OverlayPrefsStore', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('overlay_prefs_test');
    });

    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    OverlayPrefsStore store() =>
        OverlayPrefsStore(directoryResolver: () async => directory);

    test('文件不存在时返回默认偏好', () async {
      final OverlayPrefs prefs = await store().load();
      expect(prefs.webRids, isEmpty);
      expect(prefs.opacity, defaultOverlayOpacity);
    });

    test('保存后可重新读出，且覆盖写不会残留旧数据', () async {
      final OverlayPrefsStore prefsStore = store();
      await prefsStore.save(
        const OverlayPrefs(webRids: <String>['735', '736'], opacity: 0.4),
      );
      OverlayPrefs loaded = await prefsStore.load();
      expect(loaded.webRids, <String>['735', '736']);
      expect(loaded.opacity, 0.4);

      await prefsStore.save(const OverlayPrefs(webRids: <String>['737']));
      loaded = await prefsStore.load();
      expect(loaded.webRids, <String>['737']);
      expect(loaded.opacity, defaultOverlayOpacity);
    });

    test('皮肤与栏位偏好落盘后可重新读出', () async {
      final OverlayPrefsStore prefsStore = store();
      await prefsStore.save(const OverlayPrefs(
        lightTheme: true,
        showTitleBar: false,
        focusBehavior: focusBehaviorHide,
      ));
      final OverlayPrefs loaded = await prefsStore.load();
      expect(loaded.lightTheme, isTrue);
      expect(loaded.showTitleBar, isFalse);
      expect(loaded.focusBehavior, focusBehaviorHide);
    });

    test('文件内容损坏时按默认偏好处理，不抛异常', () async {
      final File file = File(
        '${directory.path}${Platform.pathSeparator}$overlayPrefsFileName',
      );
      await file.writeAsString('{broken');
      expect((await store().load()).opacity, defaultOverlayOpacity);
    });
  });
}