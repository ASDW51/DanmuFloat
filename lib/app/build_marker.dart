// 打包标识（#175）：把「这个 APK 是哪个产物」写进包里，更新时按它取包。
//
// 为什么需要：`dart:ffi` 的 `Abi.current()` 只能说明**这台设备**是什么 ABI，
// 说不出用户当初装的是「arm64 拆分包」还是「通用包」——同一个 arm64 手机上两者
// 都能跑。于是会出现「装的是通用包，更新时被推去下拆分包」这种对不上的情况。
//
// 办法是构建时就写死：release.yml 给两个产物分别注入
// `--dart-define=DANMU_BUILD_MARKER=danmufloat:arm64-v8a|danmufloat:universal`，
// 运行时读出来，更新就优先找同名产物。老版本（没有这个 define）读到空串，
// 退回「按设备 ABI → 通用包」的老规则，行为不会突变。
import 'package:flutter/foundation.dart';

/// 打包标识的 dart-define 键名（与 .github/workflows/release.yml 保持一致）。
const String buildMarkerDefineKey = 'DANMU_BUILD_MARKER';

/// 标识前缀：让 `strings libapp.so` 能唯一命中，不会撞上别处的 `arm64-v8a`。
const String buildMarkerPrefix = 'danmufloat:';

/// 当前构建的打包标识；本地运行 / 老版本未注入时为空串。
const String buildMarker = String.fromEnvironment(
  buildMarkerDefineKey,
  defaultValue: '',
);

/// 从标识里取出产物 ABI（`arm64-v8a` / `universal`）；没有标识时为空串。
///
/// 用可注入的 [marker] 而不是直接读 [buildMarker]，是为了让单测能覆盖各种写法。
String buildMarkerAbi([String marker = buildMarker]) {
  final String text = marker.trim();
  if (text.isEmpty) return '';
  if (!text.startsWith(buildMarkerPrefix)) return '';
  final String abi = text.substring(buildMarkerPrefix.length).trim();
  return abi;
}

/// 是否带打包标识（老版本与本地构建都没有）。
bool get hasBuildMarker => buildMarkerAbi().isNotEmpty;

/// 给用户看的标识文案：报障时能直接说出装的是哪个包。
String buildMarkerLabel([String marker = buildMarker]) {
  final String abi = buildMarkerAbi(marker);
  if (abi.isEmpty) return '未标记（本地构建或旧版本）';
  return abi;
}

/// 仅供测试：断言标识常量与流水线注入值一致时用。
@visibleForTesting
const String expectedArm64Marker = '${buildMarkerPrefix}arm64-v8a';

/// 仅供测试：断言标识常量与流水线注入值一致时用。
@visibleForTesting
const String expectedUniversalMarker = '${buildMarkerPrefix}universal';
