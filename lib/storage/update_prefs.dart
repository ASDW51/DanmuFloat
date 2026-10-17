// 检查更新的偏好（#166）：自动检查开关、上次检查时间、已提示过的版本。
//
// 单独一个文件而不是塞进 overlay_prefs.json：这些是「App 自身」的状态，
// 与悬浮窗样式无关，混在一起会让「清除所有本地数据」的清理范围更难说清。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 检查更新偏好的文件名。
const String updatePrefsFileName = 'update_prefs.json';

/// 检查更新偏好。
@immutable
class UpdatePrefs {
  const UpdatePrefs({
    this.autoCheck = false,
    this.lastCheckedAt,
    this.lastNotifiedVersion = '',
  });

  /// 是否开启自动检查（默认关闭：会访问 github.com，属于对外请求）。
  final bool autoCheck;

  /// 上次检查时间（毫秒）；从没查过为 null。失败也会写。
  final int? lastCheckedAt;

  /// 上次弹过提醒的版本号：同一版本只提醒一次，用户忽略后不再打扰。
  final String lastNotifiedVersion;

  UpdatePrefs copyWith({
    bool? autoCheck,
    int? lastCheckedAt,
    String? lastNotifiedVersion,
  }) => UpdatePrefs(
    autoCheck: autoCheck ?? this.autoCheck,
    lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    lastNotifiedVersion: lastNotifiedVersion ?? this.lastNotifiedVersion,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'autoCheck': autoCheck,
    'lastCheckedAt': lastCheckedAt,
    'lastNotifiedVersion': lastNotifiedVersion,
  };

  /// 解析：坏文件一律回落默认（自动检查关闭），不让一个手改的文件把设置页卡住。
  static UpdatePrefs tryParse(Object? raw) {
    if (raw is! Map) return const UpdatePrefs();
    final Object? checked = raw['lastCheckedAt'];
    final Object? notified = raw['lastNotifiedVersion'];
    return UpdatePrefs(
      autoCheck: raw['autoCheck'] == true,
      lastCheckedAt: checked is int ? checked : null,
      lastNotifiedVersion: notified is String ? notified : '',
    );
  }
}

/// 检查更新偏好的落盘存储。
class UpdatePrefsStore {
  UpdatePrefsStore({
    Future<Directory> Function()? directoryResolver,
    this.fileName = updatePrefsFileName,
  }) : _directoryResolver = directoryResolver ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryResolver;
  final String fileName;

  Future<File> _file() async {
    final Directory directory = await _directoryResolver();
    return File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  Future<UpdatePrefs> load() async {
    try {
      final File file = await _file();
      if (!await file.exists()) return const UpdatePrefs();
      return UpdatePrefs.tryParse(jsonDecode(await file.readAsString()));
    } on Object catch (exception) {
      debugPrint('读取检查更新偏好失败: $exception');
      return const UpdatePrefs();
    }
  }

  Future<void> save(UpdatePrefs prefs) async {
    try {
      final File file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(prefs.toJson()));
    } on Object catch (exception) {
      debugPrint('保存检查更新偏好失败: $exception');
    }
  }
}
