// 设置页的视图偏好（#143）：记住哪些分区被折叠。
//
// 为什么单独一个文件而不是塞进 theme.json：ThemeStore 的 save(ThemeMode) 是整份
// 覆盖写，把折叠状态混进去会出现「改主题把折叠状态冲掉、折叠又冲掉主题」的互相
// 覆盖。界面偏好与主题偏好各存一份，谁写谁的文件。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 设置页视图偏好文件名。
const String settingsViewPrefsFileName = 'settings_view.json';

/// 设置页视图偏好：折叠的分区标识集合。
///
/// 缺字段 / 损坏一律回落「全部展开」——这是改造前的样子，也是用户最不容易
/// 被卡住的状态（进来就看到全部内容，而不是面对一堆收起的标题）。
@immutable
class SettingsViewPrefs {
  const SettingsViewPrefs({this.collapsedSections = const <String>{}});

  final Set<String> collapsedSections;

  SettingsViewPrefs copyWith({Set<String>? collapsedSections}) =>
      SettingsViewPrefs(
        collapsedSections: collapsedSections ?? this.collapsedSections,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'collapsedSections': collapsedSections.toList()..sort(),
  };

  /// 解析：非对象回落空集；非字符串项逐条丢弃，不整份失效。
  static SettingsViewPrefs tryParse(Object? raw) {
    if (raw is! Map) return const SettingsViewPrefs();
    final Object? sections = raw['collapsedSections'];
    if (sections is! List) return const SettingsViewPrefs();
    return SettingsViewPrefs(
      collapsedSections: <String>{
        for (final Object? item in sections)
          if (item is String && item.isNotEmpty) item,
      },
    );
  }
}

/// 设置页视图偏好的落盘存储。
class SettingsViewPrefsStore {
  SettingsViewPrefsStore({
    Future<Directory> Function()? directoryResolver,
    this.fileName = settingsViewPrefsFileName,
  }) : _directoryResolver = directoryResolver ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryResolver;
  final String fileName;

  Future<File> _file() async {
    final Directory directory = await _directoryResolver();
    return File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  /// 读取；文件缺失、内容损坏或 IO 失败都回落「全部展开」并记日志（#143）。
  Future<SettingsViewPrefs> load() async {
    try {
      final File file = await _file();
      if (!await file.exists()) return const SettingsViewPrefs();
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) return const SettingsViewPrefs();
      return SettingsViewPrefs.tryParse(jsonDecode(raw));
    } on Object catch (exception) {
      debugPrint('读取设置页视图偏好失败，按全部展开处理: $exception');
      return const SettingsViewPrefs();
    }
  }

  Future<void> save(SettingsViewPrefs prefs) async {
    final File file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(prefs.toJson()), flush: true);
  }
}
