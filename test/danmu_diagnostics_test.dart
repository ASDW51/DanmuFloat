// 诊断信息（用户一键复制反馈）：连接状态用中文，且不得出现凭证内容（UX-09）。
//
// 诊断文本会经剪贴板外发，所以这两点都要有测试兜住：一是别把 idle / connecting 这类
// 英文枚举名丢给用户，二是别把 SESSDATA 之类的凭证混进去。
import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:danmu_float/connection/connection_state.dart';
import 'package:danmu_float/ui/danmu_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('connectionStateLabel', () {
    test('每个状态都有中文文案，不把英文枚举名暴露给用户', () {
      for (final DanmuConnectionState state in DanmuConnectionState.values) {
        final String label = connectionStateLabel(state);
        expect(label, isNotEmpty);
        expect(
          label,
          isNot(contains(state.name)),
          reason: '直接写 state.name，用户看不懂也没法据此描述问题',
        );
      }
    });
  });

  group('buildDanmuDiagnostics', () {
    test('未连接时给中文状态，并带上阶段、房间号与已收条数', () {
      final String text = buildDanmuDiagnostics(
        webRid: '123456',
        stageLabel: '未连接',
        received: 0,
        session: null,
        errorMessage: null,
      );

      expect(text, contains('webRid: 123456'));
      expect(text, contains('阶段: 未连接'));
      expect(text, contains('已收条数: 0'));
      expect(text, contains('连接状态: 未连接'));
      expect(
        text,
        isNot(contains('连接错误')),
        reason: '没有连接错误时不该出现空字段',
      );
    });

    test('带凭证的会话：诊断文本里不得出现任何凭证内容', () {
      final LiveDanmuSession session = LiveDanmuSession(
        webRid: '123456',
        credentialCookies:
            'SESSDATA=secret-sessdata-value; bili_jct=secret-csrf-token',
      );

      final String text = buildDanmuDiagnostics(
        webRid: '123456',
        stageLabel: '已连接',
        received: 12,
        session: session,
        errorMessage: null,
      );

      expect(text, isNot(contains('secret-sessdata-value')));
      expect(text, isNot(contains('secret-csrf-token')));
      expect(text, isNot(contains('SESSDATA')));
      expect(text, isNot(contains('bili_jct')));
      // 连接状态是中文，不是枚举名。
      final String label = connectionStateLabel(session.connectionState);
      expect(text, contains('连接状态: $label'));
      expect(text, isNot(contains('idle')));
    });

    test('错误与签名降级要能落进诊断文本（真机排查靠它）', () {
      final String text = buildDanmuDiagnostics(
        webRid: '123456',
        stageLabel: '异常',
        received: 3,
        session: null,
        errorMessage: '房间信息获取失败：SocketException',
      );

      expect(text, contains('阶段: 异常'));
      expect(text, contains('错误: 房间信息获取失败：SocketException'));
    });
  });
}
