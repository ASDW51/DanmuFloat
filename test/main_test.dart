// 启动分流（#86）：合规状态读不出来时必须还能走到免责声明页，而不是永久停在加载圈。
//
// 异常由注入的假 store 制造（真机上对应 path_provider 通道异常 / 文件不可读）：
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
}
