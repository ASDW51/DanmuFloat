// 凭证管理（prd F27 / 3.2 / design.md 2.2）。
//
// 产品级策略：
// - 默认匿名自动获取，仅内存、不落盘（见 cookie_provider.dart）
// - 仅用户手动粘贴的凭证才加密持久化：Android Keystore 派生密钥托管在
//   flutter_secure_storage 内，密文存 App 私有存储
// - 提供「清除本地凭证」入口，清除后回到匿名自动获取
// - 不展示完整凭证明文（设置页粘贴框用 obscure，不回显）
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 手动凭证的长度上限：防止用户误把整段网页 / 日志粘进来。
const int maxManualCookiesLength = 4096;

/// Cookie 名允许的字符集（RFC 6265 的 token）。
final RegExp cookieNamePattern = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

/// Cookie 值里不允许出现的控制字符（换行、NUL 等），防止请求头注入。
final RegExp invalidCookieValuePattern = RegExp(r'[\x00-\x08\x0a-\x1f\x7f]');

/// 校验手动粘贴的凭证：通过返回 null，否则返回给用户看的错误提示。
///
/// 只做本地格式校验（prd 风险表「用户粘贴畸形或恶意凭证」）：必须是分号分隔的
/// `name=value` 列表，拒绝换行与控制字符，避免把任意内容塞进 Cookie 请求头。
String? validateManualCookies(String raw) {
  final String value = raw.trim();
  if (value.isEmpty) return '凭证不能为空';
  if (value.length > maxManualCookiesLength) {
    return '凭证过长，请只粘贴 Cookie 内容';
  }
  if (value.contains('\n') || value.contains('\r')) return '凭证不能包含换行';
  for (final String segment in value.split(';')) {
    final String part = segment.trim();
    if (part.isEmpty) continue;
    final int separator = part.indexOf('=');
    if (separator <= 0) return '格式应为 name=value，段之间用分号分隔';
    final String name = part.substring(0, separator);
    final String val = part.substring(separator + 1);
    if (!cookieNamePattern.hasMatch(name)) return '凭证名不合法：$name';
    if (invalidCookieValuePattern.hasMatch(val)) return '凭证值含非法字符';
  }
  return null;
}

/// 凭证来源，供设置页状态行展示（prd F27）。
enum CredentialSource {
  /// 匿名自动获取（仅内存）。
  anonymous,

  /// 用户手动粘贴（加密落盘）。
  manual,
}

/// 启动时加载凭证的结果。
enum CredentialLoadResult {
  /// 没有手动凭证，走匿名自动获取。
  anonymous,

  /// 手动凭证已加载并生效。
  manual,

  /// 已保存的凭证解密失败：按 prd 3.2 不静默降级，需提示用户重新输入。
  decryptFailed,
}

/// 加密存储后端；单测注入内存实现，不依赖 Android 插件通道。
abstract class CredentialBackend {
  Future<String?> read();

  Future<void> write(String value);

  Future<void> delete();
}

/// 基于 flutter_secure_storage 的后端（design.md 3 章选型）。
///
/// 密钥由 Android Keystore 生成并托管，明文不出安全模块；别名固定在插件内部，
/// App 卸载时随 Keystore 一并清除。
class SecureCredentialBackend implements CredentialBackend {
  SecureCredentialBackend({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // resetOnError 改为 false：解密失败时抛出，交给上层提示「重新输入」，
              // 而不是让插件静默丢弃密文（prd 3.2 要求不静默降级）。
              aOptions: AndroidOptions(resetOnError: false),
            );

  /// 存储键（design.md 2.3 的「凭证存储」）。
  static const String storageKey = 'ttwid_encrypted';

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: storageKey);

  @override
  Future<void> write(String value) =>
      _storage.write(key: storageKey, value: value);

  @override
  Future<void> delete() => _storage.delete(key: storageKey);
}

/// 手动凭证的加密持久化与内存同步。
///
/// 生效路径：`load()` / `saveManual()` 成功后调用 [setManualCookies]，
/// 让所有 CookieProvider（主 App 与悬浮窗各自实例）统一优先读手动凭证。
class CredentialStore {
  CredentialStore({CredentialBackend? backend})
      : _backend = backend ?? SecureCredentialBackend();

  final CredentialBackend _backend;

  CredentialSource _source = CredentialSource.anonymous;
  bool _decryptFailed = false;

  /// 当前凭证来源。
  CredentialSource get source => _source;

  /// 上次加载是否解密失败：设置页据此提示用户重新粘贴。
  bool get decryptFailed => _decryptFailed;

  /// 是否处于手动粘贴模式。
  bool get isManual => _source == CredentialSource.manual;

  /// 读取已加密保存的手动凭证并接管取值。
  ///
  /// 读取或解密失败时按 prd 3.2 不静默降级：仅把状态标记出来，
  /// 由设置页提示用户重新输入。
  Future<CredentialLoadResult> load() async {
    try {
      final String? saved = await _backend.read();
      if (saved == null || saved.trim().isEmpty) {
        setManualCookies(null);
        _source = CredentialSource.anonymous;
        _decryptFailed = false;
        return CredentialLoadResult.anonymous;
      }
      setManualCookies(saved);
      _source = CredentialSource.manual;
      _decryptFailed = false;
      return CredentialLoadResult.manual;
    } on Object {
      setManualCookies(null);
      _source = CredentialSource.anonymous;
      _decryptFailed = true;
      return CredentialLoadResult.decryptFailed;
    }
  }

  /// 保存手动粘贴的凭证；校验不通过时返回错误提示，不改动任何状态。
  Future<String?> saveManual(String raw) async {
    final String? error = validateManualCookies(raw);
    if (error != null) return error;

    final String value = raw.trim();
    try {
      await _backend.write(value);
    } on Object catch (exception) {
      // 加密写入失败：不接管取值，避免出现「界面显示已保存、实际没存」的假象。
      return '凭证保存失败：$exception';
    }
    setManualCookies(value);
    _source = CredentialSource.manual;
    _decryptFailed = false;
    return null;
  }

  /// 清除本地凭证（prd F26「清除本地凭证」）：删除密文，回到匿名自动获取。
  ///
  /// 只影响凭证，不动主播列表 / 样式偏好 / 合规状态。
  Future<void> clearManual() async {
    try {
      await _backend.delete();
    } on Object {
      // 密文可能本就不存在或设备已卸载过 Keystore 条目，清内存即可。
    }
    setManualCookies(null);
    _source = CredentialSource.anonymous;
    _decryptFailed = false;
  }
}
