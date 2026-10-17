// 「我的主题」的数据模型（#147）。
//
// 单独成文件、且不 import 偏好层与桥接层：主 App 与悬浮窗进程都要解析同一份主题表
// （桥接层解析 config / style 消息，偏好层解析落盘 JSON），而偏好层依赖桥接层的
// `OverlayPrefsPatch`。模型放在这里，两个方向都能引用它，不会形成循环依赖。
const int maxMyThemes = 8;

/// 自定义主题名的长度上限（字数，非字节）。
const int myThemeMaxNameLength = 20;

/// 用户另存的具名主题：一份「基础预设 + 整份角色覆盖表」的快照。
///
/// 为什么不把自定义主题的 id 塞进 `OverlayPrefs.themeId`：那条解析规则是「未知标识
/// 一律回落 dark」，于是旧版本代码、旧备份、任何笔误都会把一个自定义主题静默变成
/// dark。所以 themeId 继续只存预设 id，应用自定义主题时一次性写回「基础预设 +
/// 覆盖表」两件事。
class MyTheme {
  const MyTheme({
    required this.id,
    required this.name,
    required this.baseThemeId,
    required this.overrides,
  });

  /// 本地稳定标识（创建时的毫秒时间戳字符串）：重命名 / 用当前配色更新都不改它，
  /// 否则列表项会在用户眼皮底下换位置。
  final String id;
  final String name;

  /// 快照当时的基础预设 id（四个预设之一）。
  final String baseThemeId;

  /// 角色名 → ARGB 的整份覆盖表，取值口径与 `OverlayPrefs.colorOverrides` 一致。
  final Map<String, int> overrides;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'baseThemeId': baseThemeId,
    'overrides': overrides,
  };

  /// 解析单条自定义主题：任何一项不合法都返回 null，由调用方「逐条丢弃」，
  /// 而不是让整张表失效（沿用 colorOverrides / resolve() 的既有口径）。
  static MyTheme? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? name = raw['name'];
    final Object? baseThemeId = raw['baseThemeId'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.trim().isEmpty) return null;
    if (name.length > myThemeMaxNameLength) return null;
    if (baseThemeId is! String || baseThemeId.isEmpty) return null;
    return MyTheme(
      id: id,
      name: name.trim(),
      baseThemeId: baseThemeId,
      overrides: _parseOverrides(raw['overrides']),
    );
  }
}

/// 覆盖表解析：与桥接层 `parseColorOverrides` 同口径（key 非空 String、值为不透明的
/// 0x00~0xFFFFFFFF 整数），此处单独实现是为了让模型层不依赖桥接层（见文件头）。
Map<String, int> _parseOverrides(Object? raw) {
  if (raw is! Map) return const <String, int>{};
  final Map<String, int> result = <String, int>{};
  for (final MapEntry<Object?, Object?> entry in raw.entries) {
    final Object? key = entry.key;
    final Object? value = entry.value;
    if (key is! String || key.isEmpty) continue;
    if (value is! int) continue;
    if (value < 0 || value > 0xFFFFFFFF) continue;
    if (((value >> 24) & 0xFF) != 0xFF) continue;
    result[key] = value;
  }
  return result;
}

/// 解析自定义主题表：缺字段 → 空表（旧 JSON / 旧备份照常可读）；单条非法 → 丢掉
/// 那条、其余保留；同 id 只留第一条。偏好层与桥接层共用这一份口径。
List<MyTheme> parseMyThemes(Object? raw) {
  if (raw is! List) return const <MyTheme>[];
  final List<MyTheme> result = <MyTheme>[];
  for (final Object? item in raw) {
    final MyTheme? parsed = MyTheme.tryParse(item);
    if (parsed == null) continue;
    if (result.any((MyTheme theme) => theme.id == parsed.id)) continue;
    result.add(parsed);
  }
  return result;
}
