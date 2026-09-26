// 主 App 主题偏好（prd F20）：深色 / 浅色 / 跟随系统，落盘到独立文件。
//
// 与悬浮窗样式（overlay.json）分开存：主题要在首帧之前就读回，而悬浮窗样式
// 是进首页之后才用得上；混在一个文件里会让启动链路多等一次 IO。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// 主题偏好文件名。
const String themePrefsFileName = 'theme.json';

/// 全局主题模式：主 App 只有一个入口，用全局 ValueNotifier 让设置页的改动
/// 即时作用到 MaterialApp，不必把回调一层层从首页透传到设置页。
final ValueNotifier<ThemeMode> appThemeMode =
    ValueNotifier<ThemeMode>(ThemeMode.system);

/// 把主题模式序列化成 JSON 可存字符串；非法值回落「跟随系统」。
String encodeThemeMode(ThemeMode mode) => jsonEncode(<String, Object?>{
      'themeMode': mode.name,
    });

/// 解析主题偏好；内容损坏或取值不认识时返回 [ThemeMode.system]。
ThemeMode decodeThemeMode(String raw) {
  if (raw.trim().isEmpty) return ThemeMode.system;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return ThemeMode.system;
  }
  if (decoded is! Map) return ThemeMode.system;
  final Object? name = decoded['themeMode'];
  if (name is! String) return ThemeMode.system;
  for (final ThemeMode mode in ThemeMode.values) {
    if (mode.name == name) return mode;
  }
  return ThemeMode.system;
}

class ThemeStore {
  ThemeStore({
    Future<Directory> Function()? directoryResolver,
    this.fileName = themePrefsFileName,
  }) : _directoryResolver = directoryResolver ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryResolver;
  final String fileName;

  Future<File> _file() async {
    final Directory directory = await _directoryResolver();
    return File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  /// 读取主题偏好；文件缺失或内容损坏时回落「跟随系统」。
  Future<ThemeMode> load() async {
    final File file = await _file();
    if (!await file.exists()) return ThemeMode.system;
    return decodeThemeMode(await file.readAsString());
  }

  Future<void> save(ThemeMode mode) async {
    final File file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(encodeThemeMode(mode), flush: true);
  }

  /// 删除主题偏好文件（「清除所有本地数据」用，见 prd F26）。
  Future<void> clear() async {
    final File file = await _file();
    if (await file.exists()) await file.delete();
  }
}
