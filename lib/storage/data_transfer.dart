// 本地数据的备份与迁移：主播列表 + 各项设置（prd F26 侧能力）。
//
// 备份是一段 JSON 文本：可以复制到剪贴板发到另一台设备，也可以写成文件留档。
// 不含凭证密文——它是设备绑定的加密数据，换设备无法解密，且属敏感信息；
// 也不含弹幕缓存（那是运行期数据，没有迁移价值）。
//
// 各分区直接沿用已有存储的文件结构（rooms.json / overlay.json / filter.json /
// theme.json / compliance.json），导入时复用各自的解析函数，避免两套口径走样。
//
// 文件的系统级读写（写公共「下载」目录、从文件选择器读入）走原生通道，实现见
// android/app/src/main/kotlin/.../MainActivity.kt；两条路都不需要存储权限。
import 'dart:convert';
import 'dart:io';

import 'package:danmu_float/compliance/compliance_store.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/room/managed_room.dart';
import 'package:danmu_float/storage/filter_store.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/storage/room_store.dart';
import 'package:danmu_float/storage/theme_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 备份文件的标识与版本：导入时用来判断是不是本 App 的备份。
const String dataBundleAppId = 'danmu-float';
const int dataBundleVersion = 1;

/// 备份文件原生通道名（与 MainActivity 约定）。
const String dataFileChannelName = 'danmu_float/data_file';

const MethodChannel _dataFileChannel = MethodChannel(dataFileChannelName);

/// 写文件的后端签名；单测可注入内存实现，不依赖真机通道。
typedef SaveTextToDownloads = Future<String?> Function({
  required String fileName,
  required String content,
});

/// 把备份文本写进系统公共「下载」目录，返回展示给用户的位置；写不进去返回 null。
///
/// Android 10 起应用不能直接写公共目录，原生侧经 MediaStore 落盘，文件管理器
/// 能直接看到；更低的版本退回系统「另存为」。通道不可用时返回 null。
Future<String?> saveTextToDownloads({
  required String fileName,
  required String content,
}) async {
  try {
    return await _dataFileChannel.invokeMethod<String>(
      'saveToDownloads',
      <String, Object?>{'fileName': fileName, 'content': content},
    );
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// 从系统文件选择器读一份备份文本。
///
/// 返回 null 表示用户取消或通道不可用；读到了但内容读不出来时 [error] 带原因。
Future<({String? text, String? error})?> pickImportTextFile() async {
  final Map<Object?, Object?>? raw;
  try {
    raw = await _dataFileChannel.invokeMapMethod<Object?, Object?>('pickTextFile');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
  if (raw == null) return null;
  final Object? text = raw['text'];
  final Object? error = raw['error'];
  return (text: text is String ? text : null, error: error is String ? error : null);
}

/// 导入失败的原因，[message] 直接面向用户展示。
class DataTransferException implements Exception {
  const DataTransferException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一份备份的解析结果。
class DataBundle {
  const DataBundle({
    required this.rooms,
    required this.prefs,
    required this.filter,
    required this.themeMode,
    required this.compliance,
  });

  final List<ManagedRoom> rooms;
  final OverlayPrefs prefs;
  final FilterPrefs filter;
  final ThemeMode themeMode;
  final ComplianceState compliance;
}

/// 备份文件名：danmu_float_backup_年月日_时分秒.json。
String backupFileName(DateTime now) {
  String two(int value) => value.toString().padLeft(2, '0');
  return 'danmu_float_backup_'
      '${now.year}${two(now.month)}${two(now.day)}_'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
}

/// 组装备份 JSON 文本。
String encodeDataBundle({
  required List<ManagedRoom> rooms,
  required OverlayPrefs prefs,
  required FilterPrefs filter,
  required ThemeMode themeMode,
  required ComplianceState compliance,
  DateTime? exportedAt,
}) =>
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'app': dataBundleAppId,
      'version': dataBundleVersion,
      'exportedAt': (exportedAt ?? DateTime.now()).toIso8601String(),
      'rooms': <String, Object?>{
        'rooms': <Map<String, Object?>>[
          for (final ManagedRoom room in rooms) room.toJson(),
        ],
      },
      'overlayPrefs': prefs.toJson(),
      'filter': filter.toJson(),
      'theme': <String, Object?>{'themeMode': themeMode.name},
      'compliance': compliance.toJson(),
    });

/// 解析备份文本；不是本 App 的备份或结构对不上时抛 [DataTransferException]。
///
/// 单个分区损坏时该分区退回默认值，不整份拒绝：备份来自旧版本时更可能局部缺字段。
DataBundle decodeDataBundle(String raw) {
  if (raw.trim().isEmpty) {
    throw const DataTransferException('内容为空，请粘贴完整的备份 JSON');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    throw const DataTransferException('不是合法的 JSON，请检查是否复制完整');
  }
  if (decoded is! Map) {
    throw const DataTransferException('备份结构不认识：根节点应为对象');
  }
  if (decoded['app'] != dataBundleAppId) {
    throw const DataTransferException('这不是 DanmuFloat 的备份文件');
  }
  final Object? version = decoded['version'];
  if (version is! int || version <= 0) {
    throw const DataTransferException('备份缺少版本号，无法确认格式');
  }
  if (version > dataBundleVersion) {
    throw DataTransferException(
      '备份版本过新（文件 v$version，当前支持到 v$dataBundleVersion），请先升级 App',
    );
  }

  return DataBundle(
    rooms: decodeRooms(_section(decoded['rooms'])),
    prefs: decodeOverlayPrefs(_section(decoded['overlayPrefs'])) ??
        const OverlayPrefs(),
    filter: decodeFilterPrefs(_section(decoded['filter'])),
    themeMode: decodeThemeMode(_section(decoded['theme'])),
    compliance:
        ComplianceState.tryParse(decoded['compliance']) ?? const ComplianceState(),
  );
}

/// 把备份里的一个分区还原成「单文件原文」，好复用各存储已有的解析函数。
String _section(Object? value) => jsonEncode(value ?? const <String, Object?>{});

/// 导入结果摘要，用于给用户一句明确的反馈。
class DataImportSummary {
  const DataImportSummary({
    required this.rooms,
    required this.blockedKeywords,
    required this.highlightKeywords,
    required this.regexEnabled,
  });

  final int rooms;
  final int blockedKeywords;
  final int highlightKeywords;
  final bool regexEnabled;

  String get description => '已导入 $rooms 个主播 · '
      '屏蔽词 $blockedKeywords 条 · 高亮词 $highlightKeywords 条'
      '${regexEnabled ? ' · 已开启正则' : ''}';
}

/// 本地数据的备份与恢复。
class LocalDataTransfer {
  LocalDataTransfer({
    RoomStore? roomStore,
    OverlayPrefsStore? prefsStore,
    FilterStore? filterStore,
    ThemeStore? themeStore,
    ComplianceStore? complianceStore,
    Future<Directory> Function()? directoryResolver,
    SaveTextToDownloads? saveToDownloads,
  })  : _roomStore = roomStore ?? RoomStore(),
        _prefsStore = prefsStore ?? OverlayPrefsStore(),
        _filterStore = filterStore ?? FilterStore(),
        _themeStore = themeStore ?? ThemeStore(),
        _complianceStore = complianceStore ?? ComplianceStore(),
        _directoryResolver = directoryResolver ?? getApplicationSupportDirectory,
        _saveToDownloads = saveToDownloads ?? saveTextToDownloads;

  final RoomStore _roomStore;
  final OverlayPrefsStore _prefsStore;
  final FilterStore _filterStore;
  final ThemeStore _themeStore;
  final ComplianceStore _complianceStore;
  final Future<Directory> Function() _directoryResolver;
  final SaveTextToDownloads _saveToDownloads;

  /// 读回全部本地数据并组装成备份文本。
  Future<String> exportJson() async => encodeDataBundle(
        rooms: await _roomStore.load(),
        prefs: await _prefsStore.load(),
        filter: await _filterStore.load(),
        themeMode: await _themeStore.load(),
        compliance: await _complianceStore.load(),
      );

  /// 备份文本另存到系统公共「下载」目录，返回展示给用户的位置。
  ///
  /// 公共目录写不进去（旧系统上用户取消「另存为」、通道不可用）时退回 App 私有
  /// 外部目录，保证用户手上总有一份文件。
  Future<String?> exportToDownloads(String json) async {
    final String fileName = backupFileName(DateTime.now());
    try {
      final String? saved =
          await _saveToDownloads(fileName: fileName, content: json);
      if (saved != null) return saved;
    } on Object {
      // 通道不可用（非 Android 运行 / 单测没注入）：退回私有目录。
    }
    return exportToFile(json);
  }

  /// 备份文本另存一份到 App 私有目录，返回文件路径；写不进去时返回 null。
  ///
  /// 这是 [exportToDownloads] 的兜底：私有目录（Android 上是 Android/data/<包名>）
  /// 文件管理器一般看不到，只在公共「下载」目录写不进去时用。
  Future<String?> exportToFile(String json) async {
    final Directory directory = await _resolveWritableDirectory();
    try {
      final File file = File(
        '${directory.path}${Platform.pathSeparator}${backupFileName(DateTime.now())}',
      );
      await file.parent.create(recursive: true);
      await file.writeAsString(json, flush: true);
      return file.path;
    } on Object {
      return null;
    }
  }

  Future<Directory> _resolveWritableDirectory() async {
    try {
      final Directory? external = await getExternalStorageDirectory();
      if (external != null) return external;
    } on Object {
      // 通道不可用（非 Android 运行）：退回内置目录。
    }
    return _directoryResolver();
  }

  /// 应用一份备份：直接覆盖主播列表与各项设置。
  ///
  /// 覆盖前由调用方负责二次确认——导入是破坏性操作。
  Future<DataImportSummary> importJson(String raw) async {
    final DataBundle bundle = decodeDataBundle(raw);
    await _roomStore.save(bundle.rooms);
    await _prefsStore.save(bundle.prefs);
    await _filterStore.save(bundle.filter);
    await _themeStore.save(bundle.themeMode);
    await _complianceStore.save(bundle.compliance);
    return DataImportSummary(
      rooms: bundle.rooms.length,
      blockedKeywords: bundle.filter.blockedKeywords.length,
      highlightKeywords: bundle.filter.highlightKeywords.length,
      regexEnabled: bundle.filter.regexEnabled,
    );
  }
}