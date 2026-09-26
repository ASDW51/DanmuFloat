// 悬浮窗分栏配置持久化：JSON 结构、透明度收敛与落盘往返。
import 'dart:io';

import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('clampOverlayOpacity', () {
    test('超出范围的取值被收敛到上下界', () {
      expect(clampOverlayOpacity(0.1), minOverlayOpacity);
      expect(clampOverlayOpacity(0.95), maxOverlayOpacity);
      expect(clampOverlayOpacity(0.5), 0.5);
    });

    test('NaN 回落默认值，避免写进渲染层报错', () {
      expect(clampOverlayOpacity(double.nan), defaultOverlayOpacity);
    });
  });

  group('OverlayPrefs', () {
    test('经 JSON 往返后保留栏位绑定顺序、透明度、字号与窗口尺寸', () {
      final OverlayPrefs? parsed = OverlayPrefs.tryParse(
        const OverlayPrefs(
          webRids: <String>['735', '736', '737'],
          opacity: 0.6,
          fontSize: 18,
          windowWidth: 640,
          windowHeight: 720,
        ).toJson(),
      );

      expect(parsed, isNotNull);
      expect(parsed!.webRids, <String>['735', '736', '737']);
      expect(parsed.opacity, 0.6);
      expect(parsed.fontSize, 18);
      expect(parsed.windowSize, (width: 640.0, height: 720.0));
    });

    test('越界的字号与尺寸在写文件前就被收敛', () {
      final Map<String, Object?> json = const OverlayPrefs(
        fontSize: 100,
        windowWidth: 10,
        windowHeight: 9000,
      ).toJson();
      expect(json['fontSize'], maxDanmuFontSize);

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
      final OverlayConfig single =
          const OverlayPrefs(opacity: 0.3, fontSize: 21).toConfig(<String>['735']);
      expect(single.grid.isSingle, isTrue);
      expect(single.opacity, 0.3);
      expect(single.fontSize, 21);

      final OverlayConfig quad = const OverlayPrefs()
          .toConfig(<String>['735', '736', '737']);
      expect(quad.grid.columns, 2);
      expect(quad.grid.rows, 2);
      expect(quad.opacity, defaultOverlayOpacity);
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

    test('文件内容损坏时按默认偏好处理，不抛异常', () async {
      final File file = File(
        '${directory.path}${Platform.pathSeparator}$overlayPrefsFileName',
      );
      await file.writeAsString('{broken');
      expect((await store().load()).opacity, defaultOverlayOpacity);
    });
  });
}