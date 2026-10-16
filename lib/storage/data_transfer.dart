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

/// 各分区的用户可读名：导入失败与回滚结果都要写给用户看，不能只报内部字段名（#84）。
const String dataSectionRooms = '主播列表';
const String dataSectionPrefs = '悬浮窗偏好';
const String dataSectionFilter = '过滤设置';
const String dataSectionTheme = '主题';
const String dataSectionCompliance = '合规状态';

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
/// 分区**缺失**时退回默认值，不整份拒绝：备份来自旧版本时更可能局部缺字段。
/// 但分区**存在却解析不出来**时必须整份拒绝（#84）——静默回落默认值等于把现有样式 /
/// 主题 / 栏位整体清成默认，而摘要还写着「导入成功」，用户不会重试也不会察觉。
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

  final List<String> unreadable = unreadableDataSections(decoded);
  if (unreadable.isNotEmpty) {
    throw DataTransferException(
      '备份里有 ${unreadable.length} 个分区无法解析（${unreadable.join('、')}），'
      '为避免把现有数据覆盖成默认值，已中止导入',
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

/// 找出备份里「存在但读不出来」的分区名（#84）。
///
/// 判定分两层：分区在备份里一律是 JSON 对象，**不是对象**（字符串 / 数组 / 数字）时各解析器
/// 只会回落默认值；是对象时再看该分区的解析器有没有明确说「读不出来」（`rooms` 的
/// [tryDecodeRooms]、`overlayPrefs` 的 [decodeOverlayPrefs]、合规状态的
/// `ComplianceState.tryParse` 都会返回 null；过滤与主题没有这种信号，只能做字段级检查）。
///
/// 缺失的分区**不算**损坏：老备份局部缺字段是正常的，取默认值即可。
List<String> unreadableDataSections(Object? decoded) {
  if (decoded is! Map) return const <String>[];
  final List<String> unreadable = <String>[];
  void check(String key, String label, bool Function(Map<dynamic, dynamic>) readable) {
    if (!decoded.containsKey(key)) return;
    final Object? value = decoded[key];
    if (value is! Map) {
      unreadable.add(label);
      return;
    }
    if (!readable(value)) unreadable.add(label);
  }

  check(
    'rooms',
    dataSectionRooms,
    (Map<dynamic, dynamic> value) => tryDecodeRooms(jsonEncode(value)) != null,
  );
  check(
    'overlayPrefs',
    dataSectionPrefs,
    (Map<dynamic, dynamic> value) => decodeOverlayPrefs(jsonEncode(value)) != null,
  );
  check('filter', dataSectionFilter, _filterSectionReadable);
  check('theme', dataSectionTheme, _themeSectionReadable);
  check(
    'compliance',
    dataSectionCompliance,
    (Map<dynamic, dynamic> value) => ComplianceState.tryParse(value) != null,
  );
  return unreadable;
}

/// 过滤分区没有「整体解析失败」的信号（[decodeFilterPrefs] 逐字段回落），因此只做字段级
/// 类型检查：已知字段存在却不是列表，说明这份备份被改坏过，不能当成「导入成功」。
bool _filterSectionReadable(Map<dynamic, dynamic> value) {
  for (final String key in <String>[
    'blockedKeywords',
    'blockedUsers',
    'highlightKeywords',
    'visibleKinds',
  ]) {
    final Object? item = value[key];
    if (item != null && item is! List) return false;
  }
  return true;
}

/// 主题分区同理：`themeMode` 字段存在但不是合法枚举名时判为损坏（缺字段仍取默认值）。
bool _themeSectionReadable(Map<dynamic, dynamic> value) {
  final Object? mode = value['themeMode'];
  if (mode == null) return true;
  return mode is String &&
      ThemeMode.values.any((ThemeMode item) => item.name == mode);
}

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

  /// 应用一份备份：先解析校验，再逐个分区覆盖；某一步失败就把已写入的分区回滚回旧值。
  ///
  /// 覆盖前由调用方负责二次确认——导入是破坏性操作。
  /// 逐个覆盖而不管失败（#84）会留下半套数据：rooms 已换成备份内容、prefs 还是旧的，
  /// 用户看到「导入失败」通常不会重试，重启后才发现两边对不上。所以这里做成一个小事务：
  /// 校验前置、失败回滚，并在异常里说清回滚结果。
  Future<DataImportSummary> importJson(String raw) async {
    // 解析、版本与分区损坏的校验都在这里完成：抛错时一个字节都还没写。
    final DataBundle bundle = decodeDataBundle(raw);

    // 回滚基线：覆盖前先把现有值读进内存。读不出来（文件损坏）不阻断导入，但那个分区
    // 就没有可回滚的旧值，失败提示里会写明。
    final List<ManagedRoom>? roomsBefore =
        await _readBefore(dataSectionRooms, _roomStore.load);
    final OverlayPrefs? prefsBefore =
        await _readBefore(dataSectionPrefs, _prefsStore.load);
    final FilterPrefs? filterBefore =
        await _readBefore(dataSectionFilter, _filterStore.load);
    final ThemeMode? themeBefore =
        await _readBefore(dataSectionTheme, _themeStore.load);
    final ComplianceState? complianceBefore =
        await _readBefore(dataSectionCompliance, _complianceStore.load);

    final List<_ImportStep> steps = <_ImportStep>[
      _ImportStep(
        dataSectionRooms,
        () => _roomStore.save(bundle.rooms),
        roomsBefore == null ? null : () => _roomStore.save(roomsBefore),
      ),
      _ImportStep(
        dataSectionPrefs,
        () => _prefsStore.save(bundle.prefs),
        prefsBefore == null ? null : () => _prefsStore.save(prefsBefore),
      ),
      _ImportStep(
        dataSectionFilter,
        () => _filterStore.save(bundle.filter),
        filterBefore == null ? null : () => _filterStore.save(filterBefore),
      ),
      _ImportStep(
        dataSectionTheme,
        () => _themeStore.save(bundle.themeMode),
        themeBefore == null ? null : () => _themeStore.save(themeBefore),
      ),
      _ImportStep(
        dataSectionCompliance,
        () => _complianceStore.save(bundle.compliance),
        complianceBefore == null
            ? null
            : () => _complianceStore.save(complianceBefore),
      ),
    ];

    final List<_ImportStep> applied = <_ImportStep>[];
    for (final _ImportStep step in steps) {
      try {
        await step.apply();
        applied.add(step);
      } on Object catch (error) {
        debugPrint('导入「${step.name}」失败：$error');
        final String rollback = await _rollback(applied);
        throw DataTransferException('导入「${step.name}」失败（$error）：$rollback');
      }
    }

    return DataImportSummary(
      rooms: bundle.rooms.length,
      blockedKeywords: bundle.filter.blockedKeywords.length,
      highlightKeywords: bundle.filter.highlightKeywords.length,
      regexEnabled: bundle.filter.regexEnabled,
    );
  }

  /// 覆盖前读一次旧值；读不出来时返回 null（该分区不可回滚，但不阻断导入）。
  Future<T?> _readBefore<T>(String label, Future<T> Function() read) async {
    try {
      return await read();
    } on Object catch (error) {
      debugPrint('导入前读取「$label」失败，该分区将无法回滚：$error');
      return null;
    }
  }

  /// 把已写入的分区按**逆序**还原；返回一句可直接拼进异常提示的中文结果。
  Future<String> _rollback(List<_ImportStep> applied) async {
    if (applied.isEmpty) return '未写入任何分区，现有数据未被改动';
    final List<String> failed = <String>[];
    for (final _ImportStep step in applied.reversed) {
      final Future<void> Function()? restore = step.restore;
      if (restore == null) {
        failed.add('${step.name}（导入前就没能读出旧值）');
        continue;
      }
      try {
        await restore();
      } on Object catch (error) {
        debugPrint('回滚「${step.name}」失败：$error');
        failed.add(step.name);
      }
    }
    if (failed.isEmpty) {
      return '已回滚 ${applied.length} 个分区到导入前的数据';
    }
    return '回滚失败：${failed.join('、')}，这些分区可能停留在备份内容上，请重新导入或重启 App';
  }
}

/// 导入事务里的一步：写入动作 + 回滚动作（回滚为 null 表示覆盖前读不出旧值）。
class _ImportStep {
  const _ImportStep(this.name, this.apply, this.restore);

  final String name;
  final Future<void> Function() apply;
  final Future<void> Function()? restore;
}