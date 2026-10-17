// App 版本号与版本比较（#166）。
//
// 版本号是发布流程、缺陷模板、更新检查三处共用的口径，比较规则错一次就会把用户
// 引到「没有更新」或「一直提示更新」上，所以逐条钉住。
import 'dart:io';

import 'package:danmu_float/app/app_version.dart';
import 'package:flutter_test/flutter_test.dart';

/// 从 pubspec.yaml 读 version 字段（去掉 `+n` 构建号），与 release.yml 同口径。
String readPubspecVersionName() {
  final List<String> lines = File('pubspec.yaml').readAsLinesSync();
  for (final String line in lines) {
    if (line.startsWith('version:')) {
      final String raw = line.substring('version:'.length).trim();
      final int plus = raw.indexOf('+');
      return plus >= 0 ? raw.substring(0, plus) : raw;
    }
  }
  throw StateError('pubspec.yaml 里没有 version 字段');
}

void main() {
  group('compareAppVersions（#166）', () {
    test('补丁号与次版本号：0.1.0 < 0.1.1 < 0.2.0', () {
      expect(compareAppVersions('0.1.0', '0.1.1'), lessThan(0));
      expect(compareAppVersions('0.1.1', '0.2.0'), lessThan(0));
      expect(compareAppVersions('0.2.0', '0.1.1'), greaterThan(0));
    });

    test('前缀 v 与构建号不参与比较', () {
      expect(compareAppVersions('v0.1.0', '0.1.0'), 0);
      expect(compareAppVersions('V0.1.0', 'v0.1.0'), 0);
      expect(compareAppVersions('0.1.0+5', '0.1.0'), 0);
      expect(compareAppVersions('0.1.0+5', '0.1.1'), lessThan(0));
    });

    test('预发布低于正式版', () {
      expect(compareAppVersions('1.0.0-beta', '1.0.0'), lessThan(0));
      expect(compareAppVersions('1.0.0', '1.0.0-beta'), greaterThan(0));
      expect(compareAppVersions('1.0.0-alpha', '1.0.0-beta'), lessThan(0));
      expect(compareAppVersions('1.0.0-beta.2', '1.0.0-beta.10'), lessThan(0));
    });

    test('缺段按 0：0.1 与 0.1.0 同版本', () {
      expect(compareAppVersions('0.1', '0.1.0'), 0);
      expect(compareAppVersions('1', '1.0.0'), 0);
    });

    test('垃圾输入不抛，按 0 处理', () {
      expect(() => compareAppVersions('', 'abc'), returnsNormally);
      expect(compareAppVersions('', '0.0.0'), 0);
      expect(compareAppVersions('abc', '0.1.0'), lessThan(0));
      expect(compareAppVersions('...', '0.0.0'), 0);
    });
  });

  group('版本文案（#166）', () {
    test('未注入版本号时显示「开发版」，不显示 dev', () {
      expect(appVersionLabel('dev'), contains('开发版'));
      expect(appVersionLabel(''), contains('开发版'));
      expect(appVersionLabel('  '), contains('开发版'));
    });

    test('正式版本统一带 v 前缀，不重复加', () {
      expect(appVersionLabel('0.1.0'), 'v0.1.0');
      expect(appVersionLabel('v0.1.0'), 'v0.1.0');
    });
  });

  group('构建注入的版本号（#166）', () {
    test('注入了版本号时必须与 pubspec 一致（防漂移）', () {
      final String pubspec = readPubspecVersionName();
      if (!hasBuildVersion) {
        // 本地 / 普通 CI 跑测试时没有 --dart-define，注入值为 dev，跳过。
        expect(appVersion, 'dev');
        return;
      }
      expect(
        compareAppVersions(appVersion, pubspec),
        0,
        reason:
            '注入的版本号（$appVersion）与 pubspec.yaml（$pubspec）不一致：'
            'release.yml 的 dart-define 必须取 pubspec 的 version',
      );
    });
  });
}
