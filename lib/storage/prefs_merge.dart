// 偏好写回的差量合并（#97）。
//
// 背景：设置页与过滤二级页进页时各拍一份 `prefs` / `filter` 快照，之后只在这份快照上
// `copyWith` 并整份回传。但悬浮窗引擎是并发的偏好修改者——用户在窗里改透明度 / 字号，
// 或把某个用户加入屏蔽，主 App 会实时更新自己的权威值并落盘。此时设置页再动任何一个控件，
// 都会把「进页时的旧快照」整份写回：首页 setState 成旧值、推回悬浮窗、覆盖偏好文件，
// 窗内刚做的修改被静默撤销（屏了谁又冒出来、透明度跳回进页前的值）。
//
// 这里的做法：以调用方**当前**的权威值为基，只把「相对进页快照真正变过的字段」取过来。
// 这样用户在设置页里改的字段照常生效，而他在页内没碰过、只是被窗内改掉的字段保持新值。
//
// 为什么按 JSON 字段逐项比较，而不是手写一份字段清单：`OverlayPrefs` / `FilterPrefs` 有十余个
// 字段且会继续增加，手写 `copyWith` 分支一旦漏掉某个字段，那个设置就会**再也存不下去**，
// 而且不会有任何报错。按序列化结果比较则字段一进 `toJson` 就自动参与合并。
import 'dart:convert';

import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/storage/filter_store.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';

/// 以 [current] 为基，把 [previous] → [next] 之间变过的字段取过来（#97）。
///
/// [previous] 是编辑器（设置页）看到的快照，[next] 是它这次提交的整份值，
/// [current] 是权威聚合点（首页）此刻的真实值。没有任何字段变化时原样返回 [current]，
/// 便于调用方用 `identical` 判断「这次改动可以整个跳过」。
OverlayPrefs mergeOverlayPrefsChanges({
  required OverlayPrefs current,
  required OverlayPrefs previous,
  required OverlayPrefs next,
}) {
  final Map<String, Object?>? merged = _mergeJson(
    current.toJson(),
    previous.toJson(),
    next.toJson(),
  );
  if (merged == null) return current;
  // 合并结果仍走一遍已有的解析函数：字段级钳制（透明度 / 尺寸 / 字号范围）与校验
  // 只此一份口径，避免这里再写一套。
  return decodeOverlayPrefs(jsonEncode(merged)) ?? current;
}

/// 过滤偏好的同款差量合并（#97）；语义与 [mergeOverlayPrefsChanges] 完全一致。
FilterPrefs mergeFilterPrefsChanges({
  required FilterPrefs current,
  required FilterPrefs previous,
  required FilterPrefs next,
}) {
  final Map<String, Object?>? merged = _mergeJson(
    current.toJson(),
    previous.toJson(),
    next.toJson(),
  );
  if (merged == null) return current;
  return decodeFilterPrefs(jsonEncode(merged));
}

/// 返回合并后的分区 JSON；没有任何字段变化时返回 null（调用方据此跳过重建）。
Map<String, Object?>? _mergeJson(
  Map<String, Object?> current,
  Map<String, Object?> previous,
  Map<String, Object?> next,
) {
  final Map<String, Object?> merged = <String, Object?>{...current};
  bool changed = false;
  for (final MapEntry<String, Object?> entry in next.entries) {
    if (_sameJsonValue(previous[entry.key], entry.value)) continue;
    merged[entry.key] = entry.value;
    changed = true;
  }
  return changed ? merged : null;
}

/// 按 JSON 文本比较字段值。
///
/// 不能直接用 `==`：`visibleKinds` / `blockedKeywords` / `paneStyles` 这些集合与映射字段
/// 不重载 `==`，比引用会几乎永远判为「变过」，于是页内没碰过的集合字段照样被旧快照覆盖，
/// 合并就白做了。
bool _sameJsonValue(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
