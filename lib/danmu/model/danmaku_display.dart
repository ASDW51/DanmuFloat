// 弹幕展示口径：悬浮窗与 App 内弹幕页共用，避免两处过滤/文案各写一份后走样。
//
// 口径来源（design.md 11.7 与 prd F6）：
// - 列表只保留聊天类（普通 / 飘屏 / 特权），礼物、点赞、关注、榜单入列无意义
// - 进场消息固定在底部单行
// - 房间统计只贡献在线人数，不进列表
import 'package:danmu_float/danmu/model/danmaku_event.dart';

/// 是否属于列表展示的聊天类弹幕。
bool isChatKind(DanmakuKind kind) =>
    kind == DanmakuKind.chat ||
    kind == DanmakuKind.screenChat ||
    kind == DanmakuKind.privilegeScreenChat;

/// 弹幕流是否与本会话相关。
///
/// 除累计在线人数（[DanmakuKind.roomUserSeq]，推送滞后且只用于在线人数）外，
/// 所有已登记类型都放行：是否入列由界面按 [FilterPrefs.visibleKinds] 决定
/// （prd F13）。若在这里提前挡掉礼物 / 点赞 / 关注 / 榜单，设置里勾选这些
/// 类型后将永远收不到数据，表现为「勾了也不生效」。
///
/// 房间统计必须放行：它不进列表，但在线人数只看它
/// （`DanmakuEvent.onlineCount`），挡掉会让人数一直为 0。
bool isStreamRelevant(DanmakuKind kind) =>
    kind != DanmakuKind.roomUserSeq && kind != DanmakuKind.other;

/// 弹幕类型前缀：普通弹幕无前缀，其余带前缀（prd F6 / F13）。
///
/// 前缀与正文同色（见各页面配色），类型由 [danmakuKindLabel] 给出中文名。
String? danmakuTypeLabel(DanmakuKind kind) => switch (kind) {
      DanmakuKind.screenChat => '飘屏',
      DanmakuKind.privilegeScreenChat => '特权',
      DanmakuKind.gift => '礼物',
      DanmakuKind.member => '进场',
      DanmakuKind.like => '点赞',
      DanmakuKind.social => '关注',
      DanmakuKind.roomRank => '榜单',
      _ => null,
    };

/// 列表默认可入列的类型：聊天类（普通 / 飘屏 / 特权）。
const Set<DanmakuKind> defaultListKinds = <DanmakuKind>{
  DanmakuKind.chat,
  DanmakuKind.screenChat,
  DanmakuKind.privilegeScreenChat,
};

/// 设置里可勾选「入列」的类型（prd F13「只看特定类型」）。
///
/// 房间统计 / 在线人数不列：它们只贡献在线人数，入列无意义（见文件头口径）。
const List<DanmakuKind> selectableListKinds = <DanmakuKind>[
  DanmakuKind.chat,
  DanmakuKind.screenChat,
  DanmakuKind.privilegeScreenChat,
  DanmakuKind.gift,
  DanmakuKind.member,
  DanmakuKind.like,
  DanmakuKind.social,
  DanmakuKind.roomRank,
];

/// 类型的中文名，设置页的类型多选项用。
String danmakuKindLabel(DanmakuKind kind) => switch (kind) {
      DanmakuKind.chat => '普通弹幕',
      DanmakuKind.screenChat => '飘屏弹幕',
      DanmakuKind.privilegeScreenChat => '特权弹幕',
      DanmakuKind.gift => '礼物',
      DanmakuKind.member => '进场',
      DanmakuKind.like => '点赞',
      DanmakuKind.social => '关注/分享',
      DanmakuKind.roomRank => '榜单',
      DanmakuKind.roomStats => '房间统计',
      DanmakuKind.roomUserSeq => '在线人数',
      DanmakuKind.other => '其它',
    };

/// 弹幕过滤偏好（prd F10 屏蔽 / F11 高亮 / F13 只看特定类型）。
///
/// 全局生效：悬浮窗各栏与 App 内弹幕页共用同一份。屏蔽与筛选都只在本地 UI 生效，
/// WebSocket 消息照收（prd F10）。
class FilterPrefs {
  const FilterPrefs({
    this.blockedKeywords = const <String>[],
    this.blockedUsers = const <String>[],
    this.highlightKeywords = const <String>[],
    this.visibleKinds = defaultListKinds,
  });

  /// 屏蔽关键词：内容包含任一即整条不展示（不区分大小写）。
  final List<String> blockedKeywords;

  /// 屏蔽用户：命中昵称或用户 ID 即不展示。
  final List<String> blockedUsers;

  /// 高亮关键词：命中片段以高亮色显示（不区分大小写）。
  final List<String> highlightKeywords;

  /// 列表展示哪些类型；默认只聊天类。
  final Set<DanmakuKind> visibleKinds;

  /// 是否为空偏好（三项都为默认）——用于跳过无谓的重算。
  bool get isDefault =>
      blockedKeywords.isEmpty &&
      blockedUsers.isEmpty &&
      highlightKeywords.isEmpty &&
      _sameKinds(visibleKinds, defaultListKinds);

  FilterPrefs copyWith({
    List<String>? blockedKeywords,
    List<String>? blockedUsers,
    List<String>? highlightKeywords,
    Set<DanmakuKind>? visibleKinds,
  }) =>
      FilterPrefs(
        blockedKeywords: blockedKeywords ?? this.blockedKeywords,
        blockedUsers: blockedUsers ?? this.blockedUsers,
        highlightKeywords: highlightKeywords ?? this.highlightKeywords,
        visibleKinds: visibleKinds ?? this.visibleKinds,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'blockedKeywords': blockedKeywords,
        'blockedUsers': blockedUsers,
        'highlightKeywords': highlightKeywords,
        'visibleKinds': <String>[
          for (final DanmakuKind kind in selectableListKinds)
            if (visibleKinds.contains(kind)) kind.name,
        ],
      };

  @override
  String toString() => 'FilterPrefs(blocked: ${blockedKeywords.length}, '
      'users: ${blockedUsers.length}, highlight: ${highlightKeywords.length}, '
      'kinds: ${visibleKinds.length})';
}

bool _sameKinds(Set<DanmakuKind> a, Set<DanmakuKind> b) =>
    a.length == b.length && a.every(b.contains);

/// 清洗一份字符串列表：去空白、去空项、去重（保持原顺序）。
List<String> normalizeKeywordList(List<Object?> raw) {
  final List<String> result = <String>[];
  final Set<String> seen = <String>{};
  for (final Object? item in raw) {
    if (item is! String) continue;
    final String value = item.trim();
    if (value.isEmpty || !seen.add(value)) continue;
    result.add(value);
  }
  return List<String>.unmodifiable(result);
}

/// 该类型是否应出现在弹幕列表里（prd F13）。
bool isListKind(DanmakuKind kind, FilterPrefs prefs) =>
    prefs.visibleKinds.contains(kind);

/// 是否被屏蔽（prd F10）：命中屏蔽词或屏蔽用户。
///
/// 只做本地 UI 过滤，WebSocket 消息仍照收、仍在缓存之外被丢弃。
bool isBlockedBy(DanmakuEvent event, FilterPrefs prefs) {
  if (prefs.blockedKeywords.isNotEmpty) {
    final String content = event.text.toLowerCase();
    if (content.isNotEmpty) {
      for (final String keyword in prefs.blockedKeywords) {
        if (keyword.isEmpty) continue;
        if (content.contains(keyword.toLowerCase())) return true;
      }
    }
  }
  if (prefs.blockedUsers.isNotEmpty) {
    final String userId = event.user.userId;
    final String nickname = event.user.nickName.toLowerCase();
    for (final String user in prefs.blockedUsers) {
      if (user.isEmpty) continue;
      if (userId.isNotEmpty && userId == user) return true;
      if (nickname.isNotEmpty && nickname == user.toLowerCase()) return true;
    }
  }
  return false;
}

/// 高亮切分后的一段文本。
class HighlightSegment {
  const HighlightSegment(this.text, {required this.highlighted});

  final String text;
  final bool highlighted;

  @override
  String toString() => '${highlighted ? '*' : ''}$text';
}

/// 按高亮词把文本切成若干片段（prd F11）：命中片段 [highlighted] 为真。
///
/// 不区分大小写；多个命中区间重叠时合并，保证片段首尾相接、无重复。
List<HighlightSegment> splitHighlights(String text, List<String> keywords) {
  if (text.isEmpty) return const <HighlightSegment>[];
  final List<String> usable = <String>[
    for (final String keyword in keywords)
      if (keyword.trim().isNotEmpty) keyword.trim().toLowerCase(),
  ];
  if (usable.isEmpty) {
    return <HighlightSegment>[HighlightSegment(text, highlighted: false)];
  }

  final String lower = text.toLowerCase();
  final List<({int start, int end})> ranges = <({int start, int end})>[];
  for (final String keyword in usable) {
    int from = 0;
    while (true) {
      final int index = lower.indexOf(keyword, from);
      if (index < 0) break;
      ranges.add((start: index, end: index + keyword.length));
      // 从命中末尾继续找，避免同一位置重复命中。
      from = index + keyword.length;
    }
  }
  if (ranges.isEmpty) {
    return <HighlightSegment>[HighlightSegment(text, highlighted: false)];
  }
  ranges.sort((({int start, int end}) a, ({int start, int end}) b) =>
      a.start.compareTo(b.start));

  // 合并重叠 / 相邻区间。
  final List<({int start, int end})> merged = <({int start, int end})>[];
  for (final ({int start, int end}) range in ranges) {
    if (merged.isEmpty || range.start > merged.last.end) {
      merged.add(range);
    } else if (range.end > merged.last.end) {
      merged[merged.length - 1] = (start: merged.last.start, end: range.end);
    }
  }

  final List<HighlightSegment> segments = <HighlightSegment>[];
  int cursor = 0;
  for (final ({int start, int end}) range in merged) {
    if (range.start > cursor) {
      segments.add(
        HighlightSegment(text.substring(cursor, range.start), highlighted: false),
      );
    }
    segments.add(
      HighlightSegment(text.substring(range.start, range.end), highlighted: true),
    );
    cursor = range.end;
  }
  if (cursor < text.length) {
    segments.add(HighlightSegment(text.substring(cursor), highlighted: false));
  }
  return segments;
}

/// 在线人数：过万折算为「x.x万」，与平台展示口径一致。
String formatOnlineCount(int value) =>
    value >= 10000 ? '${(value / 10000).toStringAsFixed(1)}万' : '$value';

/// 次要文字（时间、等级、灯牌、状态、类型标记）相对正文缩小的字号，
/// 并设 8 的下限，避免用户把基准字号调到很小后出现 0 或负数。
double smallerFontSize(double base, double delta) {
  final double value = base - delta;
  return value < 8 ? 8 : value;
}

/// 弹幕时间：毫秒时间戳 → HH:mm:ss，无效时间戳给占位。
String formatClock(int timeMs) {
  if (timeMs <= 0) return '--:--:--';
  final DateTime time = DateTime.fromMillisecondsSinceEpoch(timeMs);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
}

/// 弹幕自动滚动速度倍数（prd F2「滚动速度」）：
/// 1.0 为基准，小于 1 更慢更好读，大于 1 更快更贴合直播节奏。
const double minDanmuScrollSpeed = 0.5;
const double maxDanmuScrollSpeed = 3.0;
const double defaultDanmuScrollSpeed = 1.0;

/// 滚动速度收敛：NaN 回落默认值，越界收敛到上下限。
double clampDanmuScrollSpeed(double value) {
  if (value.isNaN) return defaultDanmuScrollSpeed;
  return value.clamp(minDanmuScrollSpeed, maxDanmuScrollSpeed);
}

/// 速度 1.0 时每秒滚过的逻辑像素；距离除以它得到动画时长。
const double _baseScrollPixelsPerSecond = 900;

/// 动画时长上下限：太短看不出动画效果，太长会明显落后于直播。
const int _minScrollDurationMs = 80;
const int _maxScrollDurationMs = 1200;

/// 按「距离 ÷ 速度」算滚动动画时长，并收敛到合理区间。
///
/// 时长与距离成正比，滚动视觉速度因此保持恒定：突发大量消息时列表是匀速滚过，
/// 而不是一帧直接跳到底，用户能看清滚过的内容（prd F2「滚动速度」）。
Duration danmuScrollDuration(double distance, double speed) {
  final double safeDistance = distance.isFinite && distance > 0 ? distance : 0;
  final double safeSpeed = clampDanmuScrollSpeed(speed);
  final double ms =
      safeDistance / (_baseScrollPixelsPerSecond * safeSpeed) * 1000;
  return Duration(
    milliseconds: ms.round().clamp(_minScrollDurationMs, _maxScrollDurationMs),
  );
}