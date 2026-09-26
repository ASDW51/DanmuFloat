// 合规状态持久化（prd F25）：免责声明勾选状态的文件往返与损坏兜底。
import 'dart:io';

import 'package:danmu_float/compliance/compliance_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('decodeComplianceState', () {
    test('空内容、非 JSON、结构不符一律按未同意处理', () {
      expect(decodeComplianceState('').disclaimerAccepted, isFalse);
      expect(decodeComplianceState('{oops').disclaimerAccepted, isFalse);
      expect(decodeComplianceState('[]').disclaimerAccepted, isFalse);
    });

    test('经 JSON 往返后保留勾选状态', () {
      const ComplianceState state = ComplianceState(disclaimerAccepted: true);
      expect(decodeComplianceState(encodeComplianceState(state)).disclaimerAccepted,
          isTrue);
      const ComplianceState denied = ComplianceState();
      expect(
        decodeComplianceState(encodeComplianceState(denied)).disclaimerAccepted,
        isFalse,
      );
    });

    test('首次启动引导状态随文件往返；缺字段按未走过处理', () {
      const ComplianceState state =
          ComplianceState(disclaimerAccepted: true, onboardingDone: true);
      expect(decodeComplianceState(encodeComplianceState(state)).onboardingDone,
          isTrue);
      // 旧版本文件没有该字段，应回落到「未走过引导」。
      expect(
        decodeComplianceState('{"disclaimerAccepted": true}').onboardingDone,
        isFalse,
      );
    });
  });

  group('ComplianceStore', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('compliance_test');
    });

    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    ComplianceStore store() =>
        ComplianceStore(directoryResolver: () async => directory);

    test('文件不存在时按未同意处理', () async {
      expect((await store().load()).disclaimerAccepted, isFalse);
    });

    test('保存后可重新读出，清除后回到未同意', () async {
      final ComplianceStore complianceStore = store();
      await complianceStore
          .save(const ComplianceState(disclaimerAccepted: true));
      expect((await complianceStore.load()).disclaimerAccepted, isTrue);

      await complianceStore.clear();
      expect((await complianceStore.load()).disclaimerAccepted, isFalse);
    });

    test('文件内容损坏时按未同意处理，不抛异常', () async {
      final File file = File(
        '${directory.path}${Platform.pathSeparator}$complianceStoreFileName',
      );
      await file.writeAsString('{broken');
      expect((await store().load()).disclaimerAccepted, isFalse);
    });
  });
}
