// App 版本号与版本比较（#166）。
//
// 版本真相源只有 pubspec.yaml 的 version（AGENTS 第 7 节）：发布构建用
// --dart-define=DANMU_APP_VERSION=<version_name> 注入，运行时用
// String.fromEnvironment 读。代码里**不写死**版本常量——写死必然与 tag 漂移，
// 那正是「规格与实现各说各话」的温床。

/// 注入版本号的 dart-define 键名（与 .github/workflows/release.yml 保持一致）。
const String appVersionDefineKey = 'DANMU_APP_VERSION';

/// 当前构建的版本号；未注入（本地运行 / 单测）时为 `dev`。
const String appVersion = String.fromEnvironment(
  appVersionDefineKey,
  defaultValue: 'dev',
);

/// 是否为带版本号的正式构建。
bool get hasBuildVersion => appVersion != 'dev';

/// 界面上显示的版本文案。
///
/// 开发构建直接说「未注入版本号」而不是显示一个 `dev`：报障者照着 `dev` 填进缺陷
/// 模板，等于没有信息（#166 的另一半问题就是模板要求必填版本）。
String appVersionLabel(String version) {
  final String text = version.trim();
  if (text.isEmpty || text == 'dev') return '开发版（未注入版本号）';
  return text.startsWith('v') || text.startsWith('V') ? text : 'v$text';
}

/// 比较两个版本号：<0 表示 [a] 更旧，0 表示同版本，>0 表示 [a] 更新。
///
/// 口径（#166）：
/// - 忽略前缀 `v` / `V`；
/// - 忽略 `+n` 构建号（AGENTS 第 7 节：tag 去掉 `+n`，构建号不参与比较）；
/// - 逐段数字比较，缺段按 0（`0.1` 与 `0.1.0` 同版本）；
/// - 预发布低于正式版（`1.0.0-beta` < `1.0.0`）；
/// - 垃圾输入不抛：非数字段按 0 处理——解析失败不该让设置页崩掉。
int compareAppVersions(String a, String b) {
  final _AppVersion left = _parseAppVersion(a);
  final _AppVersion right = _parseAppVersion(b);
  final int length = left.core.length > right.core.length
      ? left.core.length
      : right.core.length;
  for (int i = 0; i < length; i++) {
    final int x = i < left.core.length ? left.core[i] : 0;
    final int y = i < right.core.length ? right.core[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  // 核心段相同：正式版高于预发布（1.0.0 > 1.0.0-beta）。
  if (left.pre.isEmpty && right.pre.isEmpty) return 0;
  if (left.pre.isEmpty) return 1;
  if (right.pre.isEmpty) return -1;
  final int preLength = left.pre.length > right.pre.length
      ? left.pre.length
      : right.pre.length;
  for (int i = 0; i < preLength; i++) {
    if (i >= left.pre.length) return -1;
    if (i >= right.pre.length) return 1;
    final int? x = int.tryParse(left.pre[i]);
    final int? y = int.tryParse(right.pre[i]);
    if (x != null && y != null) {
      if (x != y) return x.compareTo(y);
      continue;
    }
    // SemVer：纯数字段低于字母数字段（1.0.0-1 < 1.0.0-alpha）。
    if (x != null) return -1;
    if (y != null) return 1;
    final int cmp = left.pre[i].compareTo(right.pre[i]);
    if (cmp != 0) return cmp;
  }
  return 0;
}

/// 解析后的版本：核心数字段 + 预发布标识段。
class _AppVersion {
  const _AppVersion(this.core, this.pre);

  final List<int> core;
  final List<String> pre;
}

_AppVersion _parseAppVersion(String raw) {
  String text = raw.trim();
  if (text.startsWith('v') || text.startsWith('V')) {
    text = text.substring(1);
  }
  final int plus = text.indexOf('+');
  if (plus >= 0) text = text.substring(0, plus);
  final int dash = text.indexOf('-');
  final String coreText = dash >= 0 ? text.substring(0, dash) : text;
  final String preText = dash >= 0 ? text.substring(dash + 1) : '';

  final List<int> core = <int>[
    for (final String part in coreText.split('.')) int.tryParse(part.trim()) ?? 0,
  ];
  // 去掉尾部多余的 0，让 0.1 与 0.1.0 走同一条比较路径。
  while (core.length > 1 && core.last == 0) {
    core.removeLast();
  }
  return _AppVersion(
    core,
    preText.trim().isEmpty
        ? const <String>[]
        : preText.trim().split('.'),
  );
}
