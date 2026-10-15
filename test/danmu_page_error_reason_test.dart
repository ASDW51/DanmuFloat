// 弹幕页失败原因的保留规则（UX-14）：与悬浮窗 UX-08 同口径——只有真正连上（live）
// 才算翻篇。抽成纯函数后无需 widget 注入口即可覆盖 error → offline → live 的迁移。
import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/ui/danmu_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('nextErrorReason', () {
    test('error 阶段的新原因覆盖旧原因', () {
      expect(
        nextErrorReason(
          '上一次的原因',
          stage: LiveSessionStage.error,
          message: '房间信息获取失败',
        ),
        '房间信息获取失败',
      );
    });

    test('解析中 / 未开播没有新原因时保留旧原因，不清空', () {
      for (final LiveSessionStage stage in <LiveSessionStage>[
        LiveSessionStage.resolvingRoom,
        LiveSessionStage.connecting,
        LiveSessionStage.offline,
      ]) {
        expect(
          nextErrorReason('接口不可用', stage: stage),
          '接口不可用',
          reason: '$stage 阶段不能把用户唯一能看到的失败原因抹掉',
        );
      }
    });

    test('只有 live 才算翻篇：清空原因', () {
      expect(
        nextErrorReason('接口不可用', stage: LiveSessionStage.live),
        isNull,
        reason: '真正连上后不该继续挂着上一次的失败原因',
      );
    });

    test('空串原因不覆盖旧原因（避免把原因置成空串）', () {
      expect(
        nextErrorReason(
          '接口不可用',
          stage: LiveSessionStage.error,
          message: '',
        ),
        '接口不可用',
      );
    });

    test('error → offline → live 全过程：原因一直可见，最后才清掉', () {
      String? reason;
      reason = nextErrorReason(
        reason,
        stage: LiveSessionStage.error,
        message: '接口不可用',
      );
      expect(reason, '接口不可用');
      reason = nextErrorReason(reason, stage: LiveSessionStage.offline);
      expect(reason, '接口不可用', reason: '未开播仍要能看到为什么失败');
      reason = nextErrorReason(reason, stage: LiveSessionStage.live);
      expect(reason, isNull);
    });
  });
}
