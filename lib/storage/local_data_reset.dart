// 「清除所有本地数据」（prd F26 / 3.3）：一键重置全部持久化配置，等同于恢复初始状态。
//
// 覆盖范围：主播列表、悬浮窗样式与分栏偏好、主题偏好、合规状态（免责声明）、凭证密文。
// 断开连接与关闭悬浮窗由调用方在清除前完成（见 settings_page）。
//
// 失败必须可见（#92）：原先六项全部套在一个空体 `_ignoreErrors` 里，任一项删不掉
// 都没有日志、没有返回值，调用方照常宣布「已恢复初始状态」——磁盘数据与用户认知
// 分裂，合规状态的残留更会让下次冷启动直接跳过免责声明页。
import 'package:danmu_float/compliance/compliance_store.dart';
import 'package:danmu_float/credential/credential_store.dart';
import 'package:danmu_float/storage/filter_store.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/storage/room_store.dart';
import 'package:danmu_float/storage/theme_store.dart';
import 'package:flutter/foundation.dart';

/// 一项没能清除的本地数据。
class LocalDataResetFailure {
  const LocalDataResetFailure({required this.target, required this.error});

  /// 用户看得懂的中文项名（主播列表 / 悬浮窗偏好 / …），直接用于提示文案。
  final String target;

  /// 原始错误，供日志与排查。
  final Object error;
}

/// 「清除所有本地数据」的结果：哪几项没清掉、合规门禁是否已经安全。
class LocalDataResetResult {
  const LocalDataResetResult({
    required this.failures,
    required this.complianceRemains,
  });

  /// 未能清除的项（按清除顺序）。
  final List<LocalDataResetFailure> failures;

  /// 合规状态没能回到「未同意」：为真时不得对用户宣布重置完成（#92）。
  ///
  /// 单独成字段是因为后果最重：`compliance.json` 里残留的
  /// `disclaimerAccepted: true` 会让下次冷启动直接进主界面，
  /// 静默击穿「清除后必须回到免责声明页」这条硬边界。
  final bool complianceRemains;

  /// 是否全部清干净。
  bool get clean => failures.isEmpty;

  /// 失败项的中文清单，用于 SnackBar 文案。
  String get targets =>
      failures.map((LocalDataResetFailure f) => f.target).join('、');
}

/// 把所有本地持久化数据清成初始状态。
class LocalDataReset {
  LocalDataReset({
    RoomStore? roomStore,
    OverlayPrefsStore? prefsStore,
    ComplianceStore? complianceStore,
    CredentialStore? credentialStore,
    FilterStore? filterStore,
    ThemeStore? themeStore,
  })  : _roomStore = roomStore ?? RoomStore(),
        _prefsStore = prefsStore ?? OverlayPrefsStore(),
        _complianceStore = complianceStore ?? ComplianceStore(),
        _credentialStore = credentialStore ?? CredentialStore(),
        _filterStore = filterStore ?? FilterStore(),
        _themeStore = themeStore ?? ThemeStore();

  final RoomStore _roomStore;
  final OverlayPrefsStore _prefsStore;
  final ComplianceStore _complianceStore;
  final CredentialStore _credentialStore;
  final FilterStore _filterStore;
  final ThemeStore _themeStore;

  /// 合规状态在提示里的项名。
  static const String complianceTarget = '合规状态';

  /// 逐项清除，返回失败清单。单项失败不阻断其余项：清数据是「尽量清干净」，
  /// 因一个文件删不掉就整体停在中途，反而会留下一半数据的空档状态；
  /// 但每一项的失败都会记日志并汇总给调用方（#92）。
  Future<LocalDataResetResult> clearAll() async {
    final List<LocalDataResetFailure> failures = <LocalDataResetFailure>[];
    await _attempt(failures, '主播列表', _roomStore.clear);
    await _attempt(failures, '悬浮窗偏好', _prefsStore.clear);
    final bool complianceRemains = await _clearCompliance(failures);
    await _attempt(failures, '过滤偏好', _filterStore.clear);
    await _attempt(failures, '主题偏好', _themeStore.clear);
    await _clearCredential(failures);
    return LocalDataResetResult(
      failures: failures,
      complianceRemains: complianceRemains,
    );
  }

  /// 单项清除：失败不阻断其余项，但必须留痕（AGENTS.md 第 4 节）。
  Future<void> _attempt(
    List<LocalDataResetFailure> failures,
    String target,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } on Object catch (error) {
      debugPrint('清除本地数据失败($target): $error');
      failures.add(LocalDataResetFailure(target: target, error: error));
    }
  }

  /// 合规状态单独处理：它是唯一「没清掉就会静默绕过门禁」的一项（#92）。
  ///
  /// 删除失败时用「未同意」覆写兜底——读取侧对未同意是 fail-safe 的，
  /// 门禁因此仍然成立；只有连兜底都做不到才报「合规状态未清除」。
  Future<bool> _clearCompliance(List<LocalDataResetFailure> failures) async {
    Object? clearError;
    try {
      await _complianceStore.clear();
    } on Object catch (error) {
      debugPrint('清除本地数据失败($complianceTarget): $error');
      clearError = error;
    }
    // 删除返回成功不代表文件真没了，必须复核（不然门禁绕过是静默的）。
    if (await _complianceGateSafe()) return false;
    try {
      await _complianceStore.save(const ComplianceState());
      if (await _complianceGateSafe()) {
        debugPrint('$complianceTarget 删除未生效，已覆写为未同意兜底');
        return false;
      }
    } on Object catch (error) {
      debugPrint('$complianceTarget 覆写未同意兜底失败: $error');
      clearError ??= error;
    }
    debugPrint('清除本地数据失败($complianceTarget): 状态仍残留为已同意');
    failures.add(
      LocalDataResetFailure(
        target: complianceTarget,
        error: clearError ?? '状态文件未能删除，也未能覆写',
      ),
    );
    return true;
  }

  /// 门禁是否已经安全：状态文件不存在，或存在但内容是「未同意」。
  Future<bool> _complianceGateSafe() async {
    try {
      if (!await _complianceStore.exists()) return true;
      return !(await _complianceStore.load()).disclaimerAccepted;
    } on Object catch (error) {
      debugPrint('复核$complianceTarget失败: $error');
      return false;
    }
  }

  /// 凭证密文：store 内部把失败的删除转成错误提示（#92），在这里汇总并留痕。
  Future<void> _clearCredential(List<LocalDataResetFailure> failures) async {
    const String target = '凭证密文';
    try {
      final String? error = await _credentialStore.clearAll();
      if (error == null) return;
      debugPrint('清除本地数据失败($target): $error');
      failures.add(LocalDataResetFailure(target: target, error: error));
    } on Object catch (error) {
      debugPrint('清除本地数据失败($target): $error');
      failures.add(LocalDataResetFailure(target: target, error: error));
    }
  }
}
