// 「清除所有本地数据」（prd F26 / 3.3）：一键重置全部持久化配置，等同于恢复初始状态。
//
// 覆盖范围：主播列表、悬浮窗样式与分栏偏好、主题偏好、合规状态（免责声明）、凭证密文。
// 断开连接与关闭悬浮窗由调用方在清除前完成（见 settings_page）。
import 'package:danmu_float/compliance/compliance_store.dart';
import 'package:danmu_float/credential/credential_store.dart';
import 'package:danmu_float/storage/filter_store.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/storage/room_store.dart';
import 'package:danmu_float/storage/theme_store.dart';

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

  /// 逐项清除。单项失败不阻断其余项：清数据是「尽量清干净」，
  /// 因一个文件删不掉就整体失败，反而会留下一半数据的空档状态。
  Future<void> clearAll() async {
    await _ignoreErrors(_roomStore.clear);
    await _ignoreErrors(_prefsStore.clear);
    await _ignoreErrors(_complianceStore.clear);
    await _ignoreErrors(_filterStore.clear);
    await _ignoreErrors(_themeStore.clear);
    // 凭证清除同时会把内存里的凭证列表清空，回到匿名自动获取。
    await _ignoreErrors(_credentialStore.clearAll);
  }

  Future<void> _ignoreErrors(Future<void> Function() action) async {
    try {
      await action();
    } on Object {
      // 忽略：详见 clearAll 注释。
    }
  }
}
