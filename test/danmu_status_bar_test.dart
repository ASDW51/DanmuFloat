import 'package:danmu_float/ui/danmu_status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按固定宽度挂载状态栏：360dp 是主流机型的逻辑宽度，内容区拿到手只有 ~336dp。
///
/// 这里刻意用 `Align + SizedBox` 而不是 `Scaffold` 的默认铺满：要复现的是「横向不够
/// 宽」这一种情况，纵向留白不参与判断。
Future<void> _pumpStatusBar(
  WidgetTester tester, {
  double width = 360,
  double textScale = 1.0,
}) async {
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearAllTestValues);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: DanmuStatusBar(
              stageLabel: '主播未开播 · 自动复检中',
              stageColor: Colors.orange,
              received: 12345,
              online: 123456,
              connectionLabel: '重连中',
              retryable: true,
              onRetry: () {},
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('360dp 下状态栏不溢出，且在线人数 / 已收 / 连接状态一条不少（UX-17）',
      (WidgetTester tester) async {
    await _pumpStatusBar(tester);

    expect(tester.takeException(), isNull);
    // 信息不丢是这条的硬要求：UX-12 已裁定在线人数不可省略，所以换行可以、裁剪不行。
    expect(find.textContaining('在线'), findsOneWidget);
    expect(find.textContaining('已收'), findsOneWidget);
    expect(find.textContaining('连接'), findsOneWidget);
  });

  testWidgets('系统字号放大到 2 倍仍不溢出（UX-17）', (WidgetTester tester) async {
    await _pumpStatusBar(tester, textScale: 2.0);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('在线'), findsOneWidget);
  });

  testWidgets('「重试」是可点中的标准触控高度，不是旧版 ~17dp（UX-17）',
      (WidgetTester tester) async {
    await _pumpStatusBar(tester);

    final Size size =
        tester.getSize(find.widgetWithText(TextButton, '重试'));
    expect(size.height, greaterThanOrEqualTo(40));
  });

  testWidgets('对照组：同样内容塞进裸 Row 在 360dp 下会溢出（证明本文件能判溢出）',
      (WidgetTester tester) async {
    // 这个用例是**测量**而不是回归：它把修复前的布局（无 Flexible 的裸 Row）复刻出来，
    // 用来证明「溢出确实会发生、且本文件的断言能看见它」。若这里不再报溢出，
    // 说明宽度估算有误，UX-17 的其余用例就只是防回归，台账里会如实降级。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 360,
              child: Row(
                children: <Widget>[
                  Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: Colors.orange,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text('主播未开播 · 自动复检中'),
                  const SizedBox(width: 4),
                  TextButton.icon(
                    onPressed: () {},
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重试'),
                  ),
                  const SizedBox(width: 12),
                  const Text('已收 12345 条'),
                  const SizedBox(width: 12),
                  const Text('在线 123456'),
                  const SizedBox(width: 12),
                  const Text('连接: 重连中'),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNotNull);
  });
}
