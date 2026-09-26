// 悬浮窗与主 App 之间的消息协议：主 App 与悬浮窗引擎不共享内存，
// 载荷必须能经 JSONMessageCodec 往返，故用例统一走 jsonEncode/jsonDecode。
import 'dart:convert';

import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:flutter_test/flutter_test.dart';

/// 模拟 BasicMessageChannel 的 JSONMessageCodec 往返。
Object? roundTrip(Map<String, Object?> message) =>
    jsonDecode(jsonEncode(message));

void main() {
  group('OverlayConfig', () {
    test('经 JSON 往返后保留各栏房间、opacity、fontSize 与 scrollSpeed', () {
      final OverlayConfig? parsed = OverlayConfig.tryParse(
        roundTrip(const OverlayConfig(
          webRids: <String>['735', '736', '737', '738'],
          opacity: 0.6,
          fontSize: 18,
          scrollSpeed: 1.75,
        ).toJson()),
      );
      expect(parsed, isNotNull);
      expect(parsed!.webRids, <String>['735', '736', '737', '738']);
      expect(parsed.opacity, 0.6);
      expect(parsed.fontSize, 18);
      expect(parsed.scrollSpeed, 1.75);
    });

    test('布局由房间数推导，缺省 opacity / fontSize / scrollSpeed 回落默认值', () {
      final OverlayConfig? parsed = OverlayConfig.tryParse(
        roundTrip(<String, Object?>{
          'type': 'config',
          'webRids': <String>['1', '2', '3', '4'],
        }),
      );
      expect(parsed, isNotNull);
      expect(parsed!.grid.count, 4);
      expect(parsed.opacity, defaultOverlayOpacity);
      expect(parsed.fontSize, defaultDanmuFontSize);
      expect(parsed.scrollSpeed, defaultDanmuScrollSpeed);
    });

    test('空白房间号被剔除，单栏布局只绑定一个房间', () {
      final OverlayConfig? parsed = OverlayConfig.tryParse(
        roundTrip(<String, Object?>{
          'type': 'config',
          'webRids': <String>[' 123 ', '', '  '],
        }),
      );
      expect(parsed, isNotNull);
      expect(parsed!.webRids, <String>['123']);
      expect(parsed.grid.isSingle, isTrue);
    });

    test('非 config 消息、无 webRids、无有效房间、非 Map 均返回 null', () {
      expect(
        OverlayConfig.tryParse(roundTrip(<String, Object?>{'type': 'state'})),
        isNull,
      );
      expect(
        OverlayConfig.tryParse(
          roundTrip(<String, Object?>{
            'type': 'config',
            'webRids': <String>[],
          }),
        ),
        isNull,
      );
      expect(
        OverlayConfig.tryParse(
          roundTrip(<String, Object?>{
            'type': 'config',
            'webRids': <String>[''],
          }),
        ),
        isNull,
      );
      expect(OverlayConfig.tryParse('config'), isNull);
      expect(OverlayConfig.tryParse(null), isNull);
    });
  });

  group('OverlayGrid', () {
    test('列数按栏位数推导：1 栏单列，2~4 栏 2 列，5~9 栏 3 列', () {
      expect(const OverlayGrid(1).columns, 1);
      expect(const OverlayGrid(2).columns, 2);
      expect(const OverlayGrid(4).columns, 2);
      expect(const OverlayGrid(5).columns, 3);
      expect(const OverlayGrid(9).columns, 3);
    });

    test('行数向上取整，单栏即铺满', () {
      expect(const OverlayGrid(1).rows, 1);
      expect(const OverlayGrid(3).rows, 2);
      expect(const OverlayGrid(5).rows, 2);
      expect(const OverlayGrid(7).rows, 3);
      expect(const OverlayGrid(9).rows, 3);
      expect(const OverlayGrid(0).rows, 0);
    });

    test('单栏标记只在 0~1 栏时为真，空栏位不参与布局', () {
      expect(const OverlayGrid(0).isSingle, isTrue);
      expect(const OverlayGrid(1).isSingle, isTrue);
      expect(const OverlayGrid(2).isSingle, isFalse);
    });
  });

  group('字号与窗口尺寸', () {
    test('字号越界收敛，NaN 回落默认值', () {
      expect(clampDanmuFontSize(4), minDanmuFontSize);
      expect(clampDanmuFontSize(40), maxDanmuFontSize);
      expect(clampDanmuFontSize(double.nan), defaultDanmuFontSize);
    });

    test('多栏按栏数缩小基准字号，单栏原样使用', () {
      expect(paneFontSize(16, 1), 16);
      expect(paneFontSize(16, 4), closeTo(13.6, 1e-9));
      expect(paneFontSize(16, 9), closeTo(11.2, 1e-9));
    });

    test('滚动速度越界收敛，NaN 回落默认值', () {
      expect(clampDanmuScrollSpeed(0.1), minDanmuScrollSpeed);
      expect(clampDanmuScrollSpeed(9), maxDanmuScrollSpeed);
      expect(clampDanmuScrollSpeed(1.5), 1.5);
      expect(clampDanmuScrollSpeed(double.nan), defaultDanmuScrollSpeed);
    });

    test('窗口宽高越界收敛，NaN 回落默认值', () {
      expect(clampOverlayWidth(100), minOverlayWidth);
      expect(clampOverlayWidth(4000), maxOverlayWidth);
      expect(clampOverlayWidth(double.nan), defaultOverlayWidth);
      expect(clampOverlayHeight(10), minOverlayHeight);
      expect(clampOverlayHeight(4000), maxOverlayHeight);
      expect(clampOverlayHeight(double.nan), defaultOverlayHeight);
    });

    test('推荐尺寸随栏数递增，且都落在可调范围内', () {
      final List<int> counts = <int>[0, 1, 2, 4, 6, 9];
      double previousArea = 0;
      for (final int count in counts) {
        final ({double width, double height}) size =
            recommendedOverlaySize(count);
        expect(clampOverlayWidth(size.width), size.width);
        expect(clampOverlayHeight(size.height), size.height);
        expect(size.width * size.height, greaterThanOrEqualTo(previousArea));
        previousArea = size.width * size.height;
      }
    });

    test('窗口上限取固定上限与屏幕尺寸的较小值', () {
      // 手机屏幕比固定上限窄：上限收敛到屏幕宽度。
      expect(overlayWidthLimit(360), 360);
      expect(overlayHeightLimit(800), 800);
      // 平板屏幕比固定上限宽：仍用固定上限。
      expect(overlayWidthLimit(2000), maxOverlayWidth);
      expect(overlayHeightLimit(3000), maxOverlayHeight);
      // 极窄屏幕不低于最小值，避免出现非法区间。
      expect(overlayWidthLimit(100), minOverlayWidth);
    });

    test('fitOverlaySize 把尺寸收敛到屏幕内，超出屏幕的值被压到上限', () {
      expect(
        fitOverlaySize(
          (width: 1080, height: 1600),
          screenWidth: 360,
          screenHeight: 800,
        ),
        (width: 360.0, height: 800.0),
      );
      // 屏幕足够大时不受影响。
      expect(
        fitOverlaySize(
          (width: 400, height: 560),
          screenWidth: 800,
          screenHeight: 1600,
        ),
        (width: 400.0, height: 560.0),
      );
      // 低于下限或非法的存量值先被固定范围收敛，再按屏幕收敛。
      expect(
        fitOverlaySize(
          (width: 10, height: double.nan),
          screenWidth: 360,
          screenHeight: 800,
        ),
        (width: minOverlayWidth, height: defaultOverlayHeight),
      );
    });
  });

  group('OverlayStyle', () {
    test('经 JSON 往返后保留透明度、字号与滚动速度，并把越界值收敛到范围', () {
      final OverlayStyle? parsed = OverlayStyle.tryParse(
        roundTrip(const OverlayStyle(
          opacity: 0.5,
          fontSize: 20,
          scrollSpeed: 2.5,
        ).toJson()),
      );
      expect(parsed!.opacity, 0.5);
      expect(parsed.fontSize, 20);
      expect(parsed.scrollSpeed, 2.5);

      expect(
        OverlayStyle.tryParse(
          roundTrip(const OverlayStyle(opacity: 0.1).toJson()),
        )!.opacity,
        minOverlayOpacity,
      );
      // 缺 scrollSpeed 的旧消息回落默认速度，不会被当成非法值。
      expect(
        OverlayStyle.tryParse(
          roundTrip(const OverlayStyle(opacity: 0.3).toJson()),
        )!.scrollSpeed,
        defaultDanmuScrollSpeed,
      );
    });

    test('非 style 消息或缺少透明度返回 null，不会被当成 config 处理', () {
      expect(
        OverlayStyle.tryParse(roundTrip(<String, Object?>{'type': 'config'})),
        isNull,
      );
      expect(
        OverlayStyle.tryParse(
          roundTrip(<String, Object?>{'type': 'style', 'opacity': 'x'}),
        ),
        isNull,
      );
      // 样式消息不能被 config 解析器认领，否则会把各栏绑定冲掉。
      expect(
        OverlayConfig.tryParse(
          roundTrip(<String, Object?>{'type': 'style', 'opacity': 0.3}),
        ),
        isNull,
      );
    });
  });

  group('PaneStyle', () {
    test('经 JSON 往返后保留字号、透明度与字色，越界值收敛', () {
      final PaneStyle? parsed = PaneStyle.tryParse(
        roundTrip(const PaneStyle(
          fontSize: 18,
          opacity: 0.4,
          textColor: 0xFFFFEB3B,
        ).toJson()),
      );
      expect(parsed, isNotNull);
      expect(parsed!.fontSize, 18);
      expect(parsed.opacity, 0.4);
      expect(parsed.textColor, 0xFFFFEB3B);

      // 越界值在写文件/发消息前就被收敛，避免渲染层拿到非法值。
      final PaneStyle clamped = PaneStyle.tryParse(
        const PaneStyle(fontSize: 100, opacity: 0.95).toJson(),
      )!;
      expect(clamped.fontSize, maxDanmuFontSize);
      expect(clamped.opacity, maxOverlayOpacity);
    });

    test('三字段都缺省时解析为 null，非 Map 也返回 null', () {
      expect(PaneStyle.tryParse(const <String, Object?>{}), isNull);
      expect(PaneStyle.tryParse('x'), isNull);
      expect(PaneStyle.tryParse(null), isNull);
      // 只有颜色也算有效覆盖，不能整体丢弃。
      expect(
        PaneStyle.tryParse(const <String, Object?>{'textColor': 0xFF000000}),
        isNotNull,
      );
    });

    test('copyWith 的 clear 开关能把单项改回「跟随全局」', () {
      const PaneStyle style = PaneStyle(fontSize: 20, opacity: 0.5);
      expect(style.copyWith(clearFontSize: true).fontSize, isNull);
      expect(style.copyWith(clearFontSize: true).opacity, 0.5);
      expect(style.copyWith(clearOpacity: true).opacity, isNull);
      expect(style.copyWith(clearOpacity: true).fontSize, 20);
    });

    test('parsePaneStyles 按 webRid 索引，跳过空房间与全缺省记录', () {
      final Map<String, PaneStyle> styles = parsePaneStyles(<Object?, Object?>{
        ' 735 ': const <String, Object?>{'fontSize': 16},
        '': const <String, Object?>{'fontSize': 16},
        '736': const <String, Object?>{},
        '737': 'not a map',
      });
      expect(styles.keys, <String>['735']);
      expect(styles['735']!.fontSize, 16);
      expect(parsePaneStyles(null), isEmpty);
      expect(parsePaneStyles('x'), isEmpty);
    });

    test('OverlayConfig / OverlayStyle 经 JSON 往返后保留 paneStyles', () {
      final OverlayConfig? config = OverlayConfig.tryParse(
        roundTrip(const OverlayConfig(
          webRids: <String>['735', '736'],
          paneStyles: <String, PaneStyle>{
            '735': PaneStyle(fontSize: 20, textColor: 0xFF00FF00),
          },
        ).toJson()),
      );
      expect(config!.paneStyles['735']!.fontSize, 20);
      expect(config.paneStyles['735']!.textColor, 0xFF00FF00);

      final OverlayStyle? style = OverlayStyle.tryParse(
        roundTrip(const OverlayStyle(
          opacity: 0.5,
          paneStyles: <String, PaneStyle>{
            '736': PaneStyle(opacity: 0.3),
          },
        ).toJson()),
      );
      expect(style!.paneStyles['736']!.opacity, 0.3);
      // 缺 paneStyles 的旧消息回落空表，不会被当成非法值。
      expect(
        OverlayStyle.tryParse(
          roundTrip(<String, Object?>{'type': 'style', 'opacity': 0.3}),
        )!.paneStyles,
        isEmpty,
      );
    });
  });

  group('OverlayStatus', () {
    test('经 JSON 往返后保留 stage、received、webRid、error', () {
      final OverlayStatus? parsed = OverlayStatus.tryParse(
        roundTrip(const OverlayStatus(
          stage: LiveSessionStage.live,
          received: 42,
          webRid: '735',
          error: 'boom',
        ).toJson()),
      );
      expect(parsed, isNotNull);
      expect(parsed!.stage, LiveSessionStage.live);
      expect(parsed.received, 42);
      expect(parsed.webRid, '735');
      expect(parsed.error, 'boom');
      // 默认不是权限撤销，缺字段的上报按未撤销处理。
      expect(parsed.permissionRevoked, isFalse);
    });

    test('权限撤销标记经 JSON 往返后保留', () {
      final OverlayStatus? parsed = OverlayStatus.tryParse(
        roundTrip(const OverlayStatus(
          stage: LiveSessionStage.error,
          received: 0,
          error: '悬浮窗权限已被撤销，已断开全部连接',
          permissionRevoked: true,
        ).toJson()),
      );
      expect(parsed!.permissionRevoked, isTrue);
      expect(parsed.stage, LiveSessionStage.error);
    });

    test('各栏最新绑定经 state 回报，缺省回落空表（prd F8 / F15）', () {
      final OverlayStatus? parsed = OverlayStatus.tryParse(
        roundTrip(const OverlayStatus(
          stage: LiveSessionStage.live,
          received: 3,
          webRids: <String>['735', '737'],
        ).toJson()),
      );
      expect(parsed!.webRids, <String>['735', '737']);

      final OverlayStatus? legacy = OverlayStatus.tryParse(
        roundTrip(<String, Object?>{
          'type': 'state',
          'stage': 'idle',
          'received': 0,
        }),
      );
      expect(legacy!.webRids, isEmpty);
    });

    test('未知 stage 回落为 idle，非 state 消息返回 null', () {
      final OverlayStatus? parsed = OverlayStatus.tryParse(
        roundTrip(<String, Object?>{
          'type': 'state',
          'stage': 'no_such_stage',
          'received': 1,
        }),
      );
      expect(parsed, isNotNull);
      expect(parsed!.stage, LiveSessionStage.idle);
      expect(
        OverlayStatus.tryParse(roundTrip(<String, Object?>{'type': 'config'})),
        isNull,
      );
    });
  });

  group('RoomOption / OverlayRooms', () {
    test('候选房间经 JSON 往返后保留直播间号、展示名与分组（prd F14）', () {
      final List<RoomOption>? parsed = OverlayRooms.tryParse(
        roundTrip(const OverlayRooms(<RoomOption>[
          RoomOption(webRid: '735', name: '老王', group: '关注'),
          RoomOption(webRid: '736'),
        ]).toJson()),
      );
      expect(parsed, isNotNull);
      expect(parsed!.length, 2);
      expect(parsed.first.webRid, '735');
      expect(parsed.first.name, '老王');
      expect(parsed.first.group, '关注');
      // 未分组用空串表示，不写进载荷。
      expect(parsed.last.group, '');
      expect(parsed.last.name, '');
    });

    test('坏记录被跳过，非 rooms 消息返回 null', () {
      expect(RoomOption.tryParse(<String, Object?>{'name': '缺id'}), isNull);
      expect(RoomOption.tryParse('x'), isNull);
      expect(parseRoomOptions(<Object?>['x', 1]), isEmpty);
      expect(
        OverlayRooms.tryParse(roundTrip(<String, Object?>{'type': 'style'})),
        isNull,
      );
      expect(parseRoomOptions(null), isEmpty);
    });

    test('config 携带候选房间，缺省回落空表', () {
      final OverlayConfig? config = OverlayConfig.tryParse(
        roundTrip(const OverlayConfig(
          webRids: <String>['735'],
          roomOptions: <RoomOption>[
            RoomOption(webRid: '735', name: '老王', group: '关注'),
            RoomOption(webRid: '736', name: '小李'),
          ],
        ).toJson()),
      );
      expect(config!.roomOptions.length, 2);
      expect(config.roomOptions[1].name, '小李');

      final OverlayConfig? legacy = OverlayConfig.tryParse(
        roundTrip(<String, Object?>{
          'type': 'config',
          'webRids': <String>['735'],
        }),
      );
      expect(legacy!.roomOptions, isEmpty);
    });
  });

  group('皮肤与焦点模式（prd F20 / F6 / F7）', () {
    test('clampFocusBehavior 只认两个已知取值，其余回落「缩小」', () {
      expect(clampFocusBehavior(focusBehaviorHide), focusBehaviorHide);
      expect(clampFocusBehavior(focusBehaviorShrink), focusBehaviorShrink);
      expect(clampFocusBehavior('no_such'), defaultFocusBehavior);
      expect(clampFocusBehavior(null), defaultFocusBehavior);
      expect(clampFocusBehavior(1), defaultFocusBehavior);
    });

    test('OverlayStyle 经 JSON 往返保留皮肤、栏目标识与焦点模式', () {
      final OverlayStyle? parsed = OverlayStyle.tryParse(
        roundTrip(const OverlayStyle(
          opacity: 0.5,
          lightTheme: true,
          showTitleBar: false,
          focusBehavior: focusBehaviorHide,
        ).toJson()),
      );
      expect(parsed!.lightTheme, isTrue);
      expect(parsed.showTitleBar, isFalse);
      expect(parsed.focusBehavior, focusBehaviorHide);
    });

    test('缺省字段回落默认值，非法焦点模式被收敛', () {
      final OverlayStyle? legacy = OverlayStyle.tryParse(
        roundTrip(const <String, Object?>{'type': 'style', 'opacity': 0.3}),
      );
      expect(legacy!.lightTheme, isFalse);
      expect(legacy.showTitleBar, isTrue);
      expect(legacy.focusBehavior, defaultFocusBehavior);

      // showTitleBar 只在显式 false 时关闭，避免旧消息被误判成隐藏标识。
      final OverlayStyle? weird = OverlayStyle.tryParse(
        roundTrip(const <String, Object?>{
          'type': 'style',
          'opacity': 0.3,
          'showTitleBar': 'false',
          'focusBehavior': 'no_such',
        }),
      );
      expect(weird!.showTitleBar, isTrue);
      expect(weird.focusBehavior, defaultFocusBehavior);
    });

    test('OverlayConfig 经 JSON 往返保留皮肤、栏目标识与焦点模式，缺省回落默认值', () {
      final OverlayConfig? parsed = OverlayConfig.tryParse(
        roundTrip(const OverlayConfig(
          webRids: <String>['735'],
          lightTheme: true,
          showTitleBar: false,
          focusBehavior: focusBehaviorHide,
        ).toJson()),
      );
      expect(parsed!.lightTheme, isTrue);
      expect(parsed.showTitleBar, isFalse);
      expect(parsed.focusBehavior, focusBehaviorHide);

      final OverlayConfig? legacy = OverlayConfig.tryParse(
        roundTrip(const <String, Object?>{
          'type': 'config',
          'webRids': <String>['735'],
        }),
      );
      expect(legacy!.lightTheme, isFalse);
      expect(legacy.showTitleBar, isTrue);
      expect(legacy.focusBehavior, defaultFocusBehavior);
    });
  });

  test('close 指令识别，主 App 构造的关闭载荷可被悬浮窗识别', () {
    expect(isOverlayCloseMessage(roundTrip(buildOverlayCloseMessage())), isTrue);
    expect(isOverlayCloseMessage(roundTrip(<String, Object?>{'type': 'close'})),
        isTrue);
    expect(
        isOverlayCloseMessage(roundTrip(<String, Object?>{'type': 'config'})),
        isFalse);
    expect(isOverlayCloseMessage(null), isFalse);
  });
}