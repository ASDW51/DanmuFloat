// 主 App 主题偏好（prd F20）：序列化、坏数据回落与落盘往返。
import 'dart:io';

import 'package:danmu_float/storage/theme_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('encodeThemeMode / decodeThemeMode', () {
    test('三种主题模式都能往返', () {
      for (final ThemeMode mode in ThemeMode.values) {
        expect(decodeThemeMode(encodeThemeMode(mode)), mode);
      }
    });

    test('空串、坏 JSON、非 Map、未知取值都回落「跟随系统」', () {
      expect(decodeThemeMode(''), ThemeMode.system);
      expect(decodeThemeMode('   '), ThemeMode.system);
      expect(decodeThemeMode('{oops'), ThemeMode.system);
      expect(decodeThemeMode('[]'), ThemeMode.system);
      expect(decodeThemeMode('{"themeMode":123}'), ThemeMode.system);
      expect(decodeThemeMode('{"themeMode":"sepia"}'), ThemeMode.system);
      expect(decodeThemeMode('{}'), ThemeMode.system);
    });
  });

  group('ThemeStore', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('theme_store_test');
    });

    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    ThemeStore store() => ThemeStore(directoryResolver: () async => directory);

    test('文件不存在时返回「跟随系统」', () async {
      expect(await store().load(), ThemeMode.system);
    });

    test('保存后可重新读出，覆盖写不会残留旧值', () async {
      final ThemeStore themeStore = store();
      await themeStore.save(ThemeMode.dark);
      expect(await themeStore.load(), ThemeMode.dark);

      await themeStore.save(ThemeMode.light);
      expect(await themeStore.load(), ThemeMode.light);
    });

    test('文件内容损坏时按「跟随系统」处理，不抛异常', () async {
      final File file = File(
        '${directory.path}${Platform.pathSeparator}$themePrefsFileName',
      );
      await file.writeAsString('{broken');
      expect(await store().load(), ThemeMode.system);
    });

    test('clear 删除文件后回到默认；文件本来不存在也不报错', () async {
      final ThemeStore themeStore = store();
      await themeStore.save(ThemeMode.dark);
      await themeStore.clear();
      expect(await themeStore.load(), ThemeMode.system);

      await themeStore.clear();
      expect(await themeStore.load(), ThemeMode.system);
    });

    test('落盘目录不存在时会自动建立', () async {
      final Directory nested =
          Directory('${directory.path}${Platform.pathSeparator}sub');
      final ThemeStore themeStore =
          ThemeStore(directoryResolver: () async => nested);
      await themeStore.save(ThemeMode.light);
      expect(await themeStore.load(), ThemeMode.light);
    });
  });
}
