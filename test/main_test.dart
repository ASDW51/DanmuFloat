// 启动分流：合规状态读不出来时必须还能走到免责声明页（#86），同意写盘失败时不能把用户
// 焊死在合规页、也不能装作已同意（#106）。
//
// 异常由注入的假 store 制造（真机上对应 path_provider 通道异常 / 文件不可读 / 目录不可写）：
// 启动链路对存储层零容错会让合规入口直接不可达，也无法自愈。
import 'dart:io';

import 'package:danmu_float/compliance/compliance_store.dart';
import 'package:danmu_float/main.dart';
import 'package:danmu_float/ui/disclaimer_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 读盘必失败的合规状态存储。
class _ThrowingComplianceStore extends ComplianceStore {
  @override
  Future<ComplianceState> load() async =>
      throw const FileSystemException('存储不可用');
}

/// 读盘必失败的合规状态存储（非 FileSystemException，覆盖「任意异常」）。
class _ThrowingErrorComplianceStore extends ComplianceStore {
  @override
  Future<ComplianceState> load() async => throw StateError('通道未注册');
}

/// 读得出来、但**写盘必失败**的合规状态存储（#106）：真机上对应目录不可写 / 磁盘满 /
/// 瞬时 IO 错误。写路径原本零容错，异常会把页面的提交标志焊死（#106）。
class _FailingSaveComplianceStore extends ComplianceStore {
  int saveAttempts = 0;

  @override
  Future<ComplianceState> load() async => const ComplianceState();

  @override
  Future<void> save(ComplianceState state) async {
    saveAttempts++;
    throw const FileSystemException('磁盘已满');
  }
}

/// 第一次写盘失败、之后成功：验证用户能靠重试走出去，而不是被焊在合规页（#106）。
class _FlakySaveComplianceStore extends ComplianceStore {
  int saveAttempts = 0;
  ComplianceState? saved;

  @override
  Future<ComplianceState> load() async => const ComplianceState();

  @override
  Future<void> save(ComplianceState state) async {
    saveAttempts++;
    if (saveAttempts == 1) throw const FileSystemException('磁盘已满');
    saved = state;
  }
}

/// 勾选同意并点「同意并继续」，等到落盘那一步结束。
Future<void> _tapAgree(WidgetTester tester) async {
  await tester.tap(find.text('我已阅读并同意上述声明'));
  await tester.pump();
  await tester.tap(find.text('同意并继续'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('合规状态读不出来时仍结束加载态并进入免责声明页（#86 回归）',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: AppEntry(store: _ThrowingComplianceStore())),
    );
    // 读盘是异步的：等这一跳落地，旧实现会在这里抛未捕获异常。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: '读盘失败也必须结束加载态，否则界面永久停在加载圈',
    );
    expect(
      find.byType(DisclaimerPage),
      findsOneWidget,
      reason: '合规入口不可达等于击穿 AGENTS 第 1 节的硬边界；读不出来按未同意处理',
    );
  });

  testWidgets('任意异常类型都按未同意处理（#86）', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: AppEntry(store: _ThrowingErrorComplianceStore())),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(DisclaimerPage), findsOneWidget);
  });

  testWidgets('同意写盘失败：留在免责声明页、按钮恢复可点并提示重试（#106）',
      (WidgetTester tester) async {
    final _FailingSaveComplianceStore store = _FailingSaveComplianceStore();
    await tester.pumpWidget(MaterialApp(home: AppEntry(store: store)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await _tapAgree(tester);

    expect(store.saveAttempts, 1);
    expect(
      find.byType(DisclaimerPage),
      findsOneWidget,
      reason: '同意没写进磁盘就不能放行：否则重启后又回到本页，用户不知道发生了什么',
    );
    expect(find.text('保存失败，请重试'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '同意并继续'))
          .onPressed,
      isNotNull,
      reason: '提交标志必须异常安全复位，否则按钮永久禁用 + 挂转圈（首启时本页无返回栈）',
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('写盘恢复后重试即通过合规门禁（#106）', (WidgetTester tester) async {
    final _FlakySaveComplianceStore store = _FlakySaveComplianceStore();
    await tester.pumpWidget(MaterialApp(home: AppEntry(store: store)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await _tapAgree(tester);
    expect(find.text('保存失败，请重试'), findsOneWidget);

    // 手动收起 SnackBar：它停在底部，正好压在「同意并继续」上，重试的点击会落在提示上。
    ScaffoldMessenger.of(tester.element(find.byType(DisclaimerPage)))
        .removeCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(find.text('保存失败，请重试'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '同意并继续'))
          .onPressed,
      isNotNull,
      reason: '失败后按钮必须恢复可点，否则重试无从谈起',
    );

    // 再点一次：这次写盘成功，应当放行到引导页。
    await tester.tap(find.text('同意并继续'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(store.saveAttempts, 2);
    expect(store.saved?.disclaimerAccepted, isTrue);
    expect(
      find.byType(DisclaimerPage),
      findsNothing,
      reason: '写盘成功后必须放行，不能让用户被一次瞬时故障挡在门外',
    );
  });
}
