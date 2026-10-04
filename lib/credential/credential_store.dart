// 凭证管理（prd F27 / 3.2 / design.md 2.2）。
//
// 产品级策略：
// - 默认匿名自动获取 ttwid，仅内存、不落盘（见 cookie_provider.dart）
// - 用户可全局配置多份凭证，每份可命名，供不同主播分别指定使用
// - 只有用户手动配置的凭证才加密持久化：Android Keystore 派生密钥托管在
//   flutter_secure_storage 内，密文存 App 私有存储
// - 提供「清除本地凭证」入口，清除后回到匿名自动获取
// - 不展示完整凭证明文（设置页输入框用 obscure，不回显）
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

/// 一份用户配置的凭证：可全局配置多份，主播按 [CredentialProfile.id] 指定使用哪一份。
class CredentialProfile {
  const CredentialProfile({
    required this.id,
    required this.name,
    required this.cookies,
    required this.createdAt,
  });

  /// 稳定标识，用于主播绑定与增删改。
  final String id;

  /// 用户起的名字，便于在主播上指定时辨认。
  final String name;

  /// Cookie 请求头串；明文只在内存与设置页输入时存在，落盘的是加密密文。
  final String cookies;

  /// 创建时间（epoch 毫秒）。
  final int createdAt;

  CredentialProfile copyWith({String? name, String? cookies}) => CredentialProfile(
        id: id,
        name: name ?? this.name,
        cookies: cookies ?? this.cookies,
        createdAt: createdAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'cookies': cookies,
        'created_at': createdAt,
      };

  /// 解析单份凭证；缺 id 或内容时返回 null（按坏数据跳过）。
  static CredentialProfile? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? cookies = raw['cookies'];
    if (id is! String || id.trim().isEmpty) return null;
    if (cookies is! String || cookies.trim().isEmpty) return null;
    final String value = cookies.trim();
    if (validateManualCookies(value) != null) return null;
    return CredentialProfile(
      id: id.trim(),
      name: _asString(raw['name']).trim(),
      cookies: value,
      createdAt: _asInt(raw['created_at']),
    );
  }

  static String _asString(Object? value) => value is String ? value : '';

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }
}

/// 序列化凭证列表（写入加密后端前的内容）。
String encodeCredentialProfiles(List<CredentialProfile> profiles) =>
    jsonEncode(
      profiles.map((CredentialProfile profile) => profile.toJson()).toList(),
    );

/// 解析已保存的凭证列表。
///
/// 兼容旧版本「只存一份明文 cookie 串」的格式：解析不出列表时按单份迁移，
/// 命名为「默认凭证」，避免升级后已保存的凭证被当成坏数据丢掉。
List<CredentialProfile> decodeCredentialProfiles(String? raw) {
  final String value = raw?.trim() ?? '';
  if (value.isEmpty) return const <CredentialProfile>[];

  Object? decoded;
  try {
    decoded = jsonDecode(value);
  } on FormatException {
    decoded = null;
  }
  if (decoded is List) {
    return decoded
        .map(CredentialProfile.tryParse)
        .whereType<CredentialProfile>()
        .toList(growable: false);
  }
  if (validateManualCookies(value) != null) return const <CredentialProfile>[];
  return <CredentialProfile>[
    CredentialProfile(id: 'legacy', name: '默认凭证', cookies: value, createdAt: 0),
  ];
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

  /// 存储键（design.md 2.3 的「凭证存储」）。内容为凭证列表的密文。
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

/// 多份凭证的加密持久化与内存同步。
class CredentialStore {
  CredentialStore({CredentialBackend? backend})
      : _backend = backend ?? SecureCredentialBackend();

  final CredentialBackend _backend;

  List<CredentialProfile> _profiles = const <CredentialProfile>[];
  bool _decryptFailed = false;

  /// 当前保存的凭证列表（只读快照）。
  List<CredentialProfile> get profiles => List<CredentialProfile>.unmodifiable(_profiles);

  /// 是否至少配置了一份凭证。
  bool get hasProfiles => _profiles.isNotEmpty;

  /// 上次加载是否解密失败：设置页据此提示用户重新配置。
  bool get decryptFailed => _decryptFailed;

  /// 按 id 取一份凭证；未命中返回 null（调用方按匿名自动获取处理）。
  CredentialProfile? profileOf(String? id) {
    if (id == null) return null;
    for (final CredentialProfile profile in _profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  /// 读取并解密本地保存的凭证列表。
  ///
  /// 读取或解密失败时按 prd 3.2 不静默降级：仅把状态标记出来，
  /// 由设置页提示用户重新配置。
  Future<bool> load() async {
    try {
      final String? saved = await _backend.read();
      _profiles = decodeCredentialProfiles(saved);
      _decryptFailed = false;
      return true;
    } on Object {
      _profiles = const <CredentialProfile>[];
      _decryptFailed = true;
      return false;
    }
  }

  /// 新增（[id] 为 null）或更新一份凭证；校验不通过时返回错误提示，不改动任何状态。
  ///
  /// [name] 留空时：新增用「凭证 N」占位，更新保留原名字。
  Future<String?> saveProfile({
    String? id,
    required String name,
    required String raw,
  }) async {
    final String? error = validateManualCookies(raw);
    if (error != null) return error;

    final String cookies = raw.trim();
    final String trimmedName = name.trim();
    final List<CredentialProfile> next = List<CredentialProfile>.of(_profiles);
    final int index =
        id == null ? -1 : next.indexWhere((CredentialProfile p) => p.id == id);
    if (index >= 0) {
      next[index] = next[index].copyWith(
        name: trimmedName.isEmpty ? next[index].name : trimmedName,
        cookies: cookies,
      );
    } else {
      next.add(
        CredentialProfile(
          id: _newProfileId(next),
          name: trimmedName.isEmpty ? '凭证 ${next.length + 1}' : trimmedName,
          cookies: cookies,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }

    final String? writeError = await _persist(next);
    if (writeError != null) return writeError;
    _profiles = next;
    _decryptFailed = false;
    return null;
  }

  /// 只改名字，不换内容；名字留空时保持原样。
  Future<String?> renameProfile(String id, String name) async {
    final String trimmedName = name.trim();
    if (trimmedName.isEmpty) return null;
    final List<CredentialProfile> next = List<CredentialProfile>.of(_profiles);
    final int index = next.indexWhere((CredentialProfile p) => p.id == id);
    if (index < 0) return null;
    next[index] = next[index].copyWith(name: trimmedName);
    final String? writeError = await _persist(next);
    if (writeError != null) return writeError;
    _profiles = next;
    return null;
  }

  /// 删除一份凭证；返回错误提示，成功返回 null。
  Future<String?> deleteProfile(String id) async {
    final List<CredentialProfile> next = _profiles
        .where((CredentialProfile profile) => profile.id != id)
        .toList(growable: false);
    if (next.length == _profiles.length) return null;
    final String? writeError = await _persist(next);
    if (writeError != null) return writeError;
    _profiles = next;
    return null;
  }

  /// 清除全部本地凭证（prd F26「清除本地凭证」）：删除密文，回到匿名自动获取。
  ///
  /// 只影响凭证，不动主播列表 / 样式偏好 / 合规状态。
  Future<void> clearAll() async {
    try {
      await _backend.delete();
    } on Object {
      // 密文可能本就不存在或设备已卸载过 Keystore 条目，清内存即可。
    }
    _profiles = const <CredentialProfile>[];
    _decryptFailed = false;
  }

  Future<String?> _persist(List<CredentialProfile> profiles) async {
    try {
      await _backend.write(encodeCredentialProfiles(profiles));
      return null;
    } on Object catch (exception) {
      // 加密写入失败：不接管取值，避免出现「界面显示已保存、实际没存」的假象。
      return '凭证保存失败：$exception';
    }
  }

  /// 生成不重复的凭证 id（创建时刻 + 必要时加序号）。
  static String _newProfileId(List<CredentialProfile> existing) {
    final String base = DateTime.now().microsecondsSinceEpoch.toString();
    if (existing.every((CredentialProfile p) => p.id != base)) return base;
    int suffix = 1;
    while (existing.any((CredentialProfile p) => p.id == '$base-$suffix')) {
      suffix++;
    }
    return '$base-$suffix';
  }
}