// 悬浮球菜单「栏位状态」一行的文案规则（UX-15）：未绑定栏写「未绑定」，不再出现
// 「第 1 栏 ·  · 等待中」——空主播名留下的双分隔符像排版事故，「等待中」还会让人
// 以为正在连接。
//
// 规则抽在 paneStatusLabel 里，所以本文件不需要 mount OverlayPage（也就绕开了它
// 静态单订阅流「一个文件只能 mount 一次」的限制）。
import 'package:danmu_float/ui/overlay_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('paneStatusLabel', () {
    test('未绑定栏只写「未绑定」，不出现空分隔符与「等待中」', () {
      final String label = paneStatusLabel(
        index: 1,
        webRid: '',
        name: '',
        stage: null,
      );
      expect(label, '第 2 栏 · 未绑定');
      expect(label, isNot(contains('·  ·')), reason: '空名不能留下两个连着的分隔符');
      expect(label, isNot(contains('等待中')), reason: '没有会话就没有「等待中」');
    });

    test('已绑定但还没有状态回报时写「等待中」', () {
      expect(
        paneStatusLabel(
          index: 0,
          webRid: '123456',
          name: '123456',
          stage: null,
        ),
        '第 1 栏 · 123456 · 等待中',
      );
    });

    test('已绑定且有状态回报时写主播名与状态词', () {
      expect(
        paneStatusLabel(index: 2, webRid: '735', name: '主播甲', stage: '失败'),
        '第 3 栏 · 主播甲 · 失败',
      );
    });
  });
}
