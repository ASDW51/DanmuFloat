// 合规状态持久化（prd F25 / 4.10 / design.md 2.1 的「免责声明状态」）：
// 记住用户是否已勾选过免责声明、是否走过首次启动引导，
// 冷启动据此决定直接进主界面、进引导页还是先回免责声明页。
//
// 与主播列表、分栏配置一样存私有目录下的 JSON 文件；目录解析做成可注入，
// 单测换成临时目录即可跑，不依赖 path_provider 插件通道。
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 合规状态文件名。
const String complianceStoreFileName = 'compliance.json';

/// 合规状态（免责声明 + 首次启动引导，后续合规开关都挂这里）。
class ComplianceState {
  const ComplianceState({
    this.disclaimerAccepted = false,
    this.onboardingDone = false,
  });

  /// 是否已勾选并同意免责声明。
  final bool disclaimerAccepted;

  /// 是否已走完首次启动引导（prd 4.10）；未走过时同意声明后先进引导页。
  final bool onboardingDone;

  ComplianceState copyWith({bool? disclaimerAccepted, bool? onboardingDone}) =>
      ComplianceState(
        disclaimerAccepted: disclaimerAccepted ?? this.disclaimerAccepted,
        onboardingDone: onboardingDone ?? this.onboardingDone,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'disclaimerAccepted': disclaimerAccepted,
        'onboardingDone': onboardingDone,
      };

  /// 解析一份状态；结构对不上时返回 null，由调用方回落默认值。
  static ComplianceState? tryParse(Object? raw) {
    if (raw is! Map) return null;
    return ComplianceState(
      disclaimerAccepted: raw['disclaimerAccepted'] == true,
      onboardingDone: raw['onboardingDone'] == true,
    );
  }
}

/// 解析合规状态文件内容；损坏一律按「未同意」处理（宁可多问一次）。
ComplianceState decodeComplianceState(String raw) {
  if (raw.trim().isEmpty) return const ComplianceState();
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const ComplianceState();
  }
  return ComplianceState.tryParse(decoded) ?? const ComplianceState();
}

/// 序列化合规状态。
String encodeComplianceState(ComplianceState state) =>
    const JsonEncoder.withIndent('  ').convert(state.toJson());

class ComplianceStore {
  ComplianceStore({
    Future<Directory> Function()? directoryResolver,
    this.fileName = complianceStoreFileName,
  }) : _directoryResolver = directoryResolver ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directoryResolver;
  final String fileName;

  Future<File> _file() async {
    final Directory directory = await _directoryResolver();
    return File('${directory.path}${Platform.pathSeparator}$fileName');
  }

  /// 读取合规状态；文件缺失或损坏时返回未同意。
  Future<ComplianceState> load() async {
    final File file = await _file();
    if (!await file.exists()) return const ComplianceState();
    return decodeComplianceState(await file.readAsString());
  }

  /// 覆盖写入合规状态。
  Future<void> save(ComplianceState state) async {
    final File file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(encodeComplianceState(state), flush: true);
  }

  /// 清除合规状态文件（「清除所有本地数据」用，见 prd F26）。
  Future<void> clear() async {
    final File file = await _file();
    if (await file.exists()) await file.delete();
  }
}
