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
    this.regexEnabled = false,
  });

  /// 屏蔽关键词：内容包含任一即整条不展示（不区分大小写）。
  final List<String> blockedKeywords;

  /// 屏蔽用户：命中昵称或用户 ID 即不展示。
  final List<String> blockedUsers;

  /// 高亮关键词：命中片段以高亮色显示（不区分大小写）。
  final List<String> highlightKeywords;

  /// 列表展示哪些类型；默认只聊天类。
  final Set<DanmakuKind> visibleKinds;

  /// 是否把屏蔽词 / 高亮词按正则表达式解析（prd F10 / F11）。
  ///
  /// 关闭时按「内容包含该子串」匹配；开启后每条规则都是一个正则表达式，
  /// 支持 `\d+`、`^开头`、`(a|b)` 等写法。单条规则非法（如括号不闭合）
  /// 只跳过该条，不影响其它规则。屏蔽用户列表始终按精确匹配，不受此开关影响。
  final bool regexEnabled;

  /// 是否为空偏好（三项都为默认）——用于跳过无谓的重算。
  bool get isDefault =>
      blockedKeywords.isEmpty &&
      blockedUsers.isEmpty &&
      highlightKeywords.isEmpty &&
      !regexEnabled &&
      _sameKinds(visibleKinds, defaultListKinds);

  FilterPrefs copyWith({
    List<String>? blockedKeywords,
    List<String>? blockedUsers,
    List<String>? highlightKeywords,
    Set<DanmakuKind>? visibleKinds,
    bool? regexEnabled,
  }) => FilterPrefs(
    blockedKeywords: blockedKeywords ?? this.blockedKeywords,
    blockedUsers: blockedUsers ?? this.blockedUsers,
    highlightKeywords: highlightKeywords ?? this.highlightKeywords,
    visibleKinds: visibleKinds ?? this.visibleKinds,
    regexEnabled: regexEnabled ?? this.regexEnabled,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'blockedKeywords': blockedKeywords,
    'blockedUsers': blockedUsers,
    'highlightKeywords': highlightKeywords,
    'visibleKinds': <String>[
      for (final DanmakuKind kind in selectableListKinds)
        if (visibleKinds.contains(kind)) kind.name,
    ],
    'regexEnabled': regexEnabled,
  };

  @override
  String toString() =>
      'FilterPrefs(blocked: ${blockedKeywords.length}, '
      'users: ${blockedUsers.length}, highlight: ${highlightKeywords.length}, '
      'kinds: ${visibleKinds.length}, regex: $regexEnabled)';
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

/// 把一段文本加进屏蔽词（prd F10）：去空白、已在名单里则不重复添加。
///
/// 列表项点击菜单的「加入屏蔽词」与设置页手输共用同一套去重口径。
FilterPrefs withBlockedKeyword(FilterPrefs prefs, String keyword) =>
    prefs.copyWith(
      blockedKeywords: normalizeKeywordList(<Object?>[
        ...prefs.blockedKeywords,
        keyword,
      ]),
    );

/// 把某个用户加进屏蔽名单（prd F10）：按 userId 精确匹配，已在名单里不重复添加。
///
/// userId 为空时（部分消息不带用户标识）原样返回，避免写进一条匹配不到任何人的空规则。
FilterPrefs withBlockedUser(FilterPrefs prefs, String userId) {
  final String value = userId.trim();
  if (value.isEmpty) return prefs;
  return prefs.copyWith(
    blockedUsers: normalizeKeywordList(<Object?>[...prefs.blockedUsers, value]),
  );
}

/// 一条规则的编译结果（#79）。
class _CompiledRule {
  const _CompiledRule(this.pattern, {required this.risky});

  /// 编译出的正则；null 表示写法非法（如括号不闭合）。
  final RegExp? pattern;

  /// 是否存在灾难性回溯风险；有风险的规则不参与匹配。
  final bool risky;
}

/// 已编译规则缓存（#79）。
///
/// 规则会被反复编译，而且是在**渲染热路径**上：`isBlockedBy` 对每条弹幕 × 每条规则、
/// [splitHighlights] 对每个可见行 × 每条规则，而两个页面（悬浮窗各栏、App 内弹幕页）
/// 的可见列表都是 `build` 里现算的 —— 等于每次重建都把全部规则重新构造一遍 RegExp。
/// 规则原文由用户手输，进程内数量有限，按原文memo 就能把构造次数降到「改设置时一次」。
final Map<String, _CompiledRule> _ruleCache = <String, _CompiledRule>{};

/// 缓存上限：超出后整体清空。正常规则只有个位数到几十条，这里只是给
/// 「异常输入 / 长期运行」兜个内存上界，清空的代价仅是一轮重编译。
const int _ruleCacheLimit = 256;

/// 取一条规则的编译结果（带缓存）。
_CompiledRule _compiledRule(String rule) {
  final String value = rule.trim();
  final _CompiledRule? cached = _ruleCache[value];
  if (cached != null) return cached;
  RegExp? pattern;
  try {
    pattern = RegExp(value, caseSensitive: false);
  } on FormatException {
    pattern = null;
  }
  final _CompiledRule compiled = _CompiledRule(
    pattern,
    risky: pattern != null && hasBacktrackingRisk(value),
  );
  if (_ruleCache.length >= _ruleCacheLimit) _ruleCache.clear();
  _ruleCache[value] = compiled;
  return compiled;
}

/// 把一条过滤规则编译成正则（不区分大小写），结果按原文缓存（#79）。
///
/// 空规则或写法非法（如括号不闭合、`[` 未配对）时返回 null，由调用方跳过；
/// 不抛出，避免用户输错一条正则就让整条弹幕流水线报错。
/// 只校验写法，不看回溯风险 —— 后者用 [compileMatchableFilterRule]。
RegExp? compileFilterRule(String rule) {
  if (rule.trim().isEmpty) return null;
  return _compiledRule(rule).pattern;
}

/// 编译一条**可用于匹配**的规则（#79）：写法非法或存在灾难性回溯风险时返回 null。
///
/// 匹配路径（[isBlockedBy]、[splitHighlights] 的正则分支）必须用这个而不是
/// [compileFilterRule]：Dart 的 `RegExp` 没有超时，一条 `(a+)+$` 配一条构造过的远端
/// 弹幕就能长时间占住 UI 线程，宁可让这条规则不生效。
RegExp? compileMatchableFilterRule(String rule) {
  if (rule.trim().isEmpty) return null;
  final _CompiledRule compiled = _compiledRule(rule);
  return compiled.risky ? null : compiled.pattern;
}

/// 规则列表里是否有写法非法的正则（设置页提示用，prd F10）。
List<String> invalidFilterRules(List<String> rules) => <String>[
  for (final String rule in rules)
    if (rule.trim().isNotEmpty && compileFilterRule(rule) == null) rule,
];

/// 写法合法、但会因灾难性回溯被停用匹配的规则（设置页提示用，#79）。
///
/// 与 [invalidFilterRules] 严格互斥：写法非法的只归前者，别把两条提示混成一条。
List<String> riskyFilterRules(List<String> rules) => <String>[
  for (final String rule in rules)
    if (rule.trim().isNotEmpty &&
        compileFilterRule(rule) != null &&
        compileMatchableFilterRule(rule) == null)
      rule,
];

/// 规则是否存在灾难性回溯（ReDoS）风险（#79）。
///
/// 只否定**明确危险**的形状：被量词修饰的组，其内部又含量词，或含首字符可能重叠的
/// 分支 —— `(a+)+$`、`(a|aa)+$`、`([a-z]+)*`、`(a?)+` 都属这一类。反向的
/// `(?:abc)+`、`(抽奖|福利)+`（分支首字符各不相同、不会互相回溯）不在此列。
///
/// 这是静态筛查而非形式化证明：**漏报**仍可能出现（复杂的前后文重叠不可判定），
/// 而**误报**会让用户的规则直接失效，所以只筛查上述确定的形状，不做更激进的推断。
/// 彻底方案是把过滤整体搬到 isolate 上设超时，那需要把过滤链路改成异步，属独立改动。
bool hasBacktrackingRisk(String rule) {
  final String pattern = rule.trim();
  if (pattern.isEmpty) return false;
  // 与括号栈同步的三个栈：组起始下标、组内是否出现过量词、组内是否出现过分支。
  final List<int> groupStarts = <int>[];
  final List<bool> groupHasQuantifier = <bool>[];
  final List<bool> groupHasAlternation = <bool>[];
  bool inCharClass = false;
  for (int i = 0; i < pattern.length; i++) {
    final String ch = pattern[i];
    if (ch == '\\') {
      // 转义序列整体跳过，避免把 `\(` `\+` 当成结构。
      i++;
      continue;
    }
    if (inCharClass) {
      if (ch == ']') inCharClass = false;
      continue;
    }
    if (ch == '[') {
      inCharClass = true;
      continue;
    }
    if (ch == '(') {
      groupStarts.add(i);
      groupHasQuantifier.add(false);
      groupHasAlternation.add(false);
      // 跳过 `?:` `?=` `?!` `?<=` `?<!` `?<name>` 这些组前缀：它们不是量词。
      i = _skipGroupPrefix(pattern, i);
      continue;
    }
    if (ch == ')') {
      if (groupStarts.isEmpty) continue;
      final int start = groupStarts.removeLast();
      final bool hasQuantifier = groupHasQuantifier.removeLast();
      final bool hasAlternation = groupHasAlternation.removeLast();
      final bool quantified = _quantifierEnd(pattern, i + 1) != null;
      if (quantified) {
        final String body = pattern.substring(start + 1, i);
        if (hasQuantifier) return true;
        if (hasAlternation && _alternativesMayOverlap(body)) return true;
      }
      // 向上传播：外层组再被量词修饰时，同样构成嵌套量词。
      if (groupStarts.isNotEmpty) {
        if (hasQuantifier || quantified) {
          groupHasQuantifier[groupHasQuantifier.length - 1] = true;
        }
        if (hasAlternation) {
          groupHasAlternation[groupHasAlternation.length - 1] = true;
        }
      }
      continue;
    }
    if (groupStarts.isNotEmpty) {
      if (ch == '|') {
        groupHasAlternation[groupHasAlternation.length - 1] = true;
      } else if (_quantifierEnd(pattern, i) != null) {
        groupHasQuantifier[groupHasQuantifier.length - 1] = true;
      }
    }
  }
  return false;
}

/// 从 [index]（`(` 的下标）起跳过组前缀，返回前缀最后一个字符的下标。
int _skipGroupPrefix(String pattern, int index) {
  int i = index + 1;
  if (i >= pattern.length || pattern[i] != '?') return index;
  i++;
  if (i >= pattern.length) return i - 1;
  if (pattern[i] == '<') {
    // 命名组 `?<name>`，或后顾 `?<=` / `?<!`。
    if (i + 1 < pattern.length &&
        (pattern[i + 1] == '=' || pattern[i + 1] == '!')) {
      return i + 1;
    }
    final int close = pattern.indexOf('>', i);
    return close < 0 ? i : close;
  }
  if (pattern[i] == ':' || pattern[i] == '=' || pattern[i] == '!') return i;
  return i - 1;
}

/// 从 [index] 起是否是一个量词；是则返回其末尾下标，否则返回 null。
int? _quantifierEnd(String pattern, int index) {
  if (index >= pattern.length) return null;
  final String ch = pattern[index];
  if (ch == '*' || ch == '+' || ch == '?') return index;
  if (ch != '{') return null;
  final RegExpMatch? match =
      RegExp(r'^\{\d+(,\d*)?\}').firstMatch(pattern.substring(index));
  if (match == null) return null;
  return index + match.end - 1;
}

/// 量化组内的分支是否**可能重叠**（#79）：`(a|aa)`、`(a|a)`、`(a?)` 这类两个分支能以
/// 同一字符开头（或某个分支可能匹配空串）才会造成灾难性回溯；`(抽奖|福利)` 这种
/// 首字符互不相同的分支是线性的，不能误判成风险。
bool _alternativesMayOverlap(String groupBody) {
  final List<String> alternatives = <String>[];
  final StringBuffer current = StringBuffer();
  bool inCharClass = false;
  int depth = 0;
  for (int i = 0; i < groupBody.length; i++) {
    final String ch = groupBody[i];
    if (ch == '\\') {
      current.write(ch);
      if (i + 1 < groupBody.length) current.write(groupBody[++i]);
      continue;
    }
    if (inCharClass) {
      current.write(ch);
      if (ch == ']') inCharClass = false;
      continue;
    }
    if (ch == '[') {
      inCharClass = true;
      current.write(ch);
      continue;
    }
    if (ch == '(') {
      depth++;
      current.write(ch);
      continue;
    }
    if (ch == ')') {
      depth--;
      current.write(ch);
      continue;
    }
    if (ch == '|' && depth == 0) {
      alternatives.add(current.toString());
      current.clear();
      continue;
    }
    current.write(ch);
  }
  alternatives.add(current.toString());

  final Set<String> firstChars = <String>{};
  for (final String alternative in alternatives) {
    final String? first = _literalFirstChar(alternative);
    // 首字符不确定（空分支、字符类、通配、分组、转义类）时无法排除重叠：按风险处理。
    if (first == null) return true;
    if (!firstChars.add(first)) return true;
  }
  return false;
}

/// 分支的首个「确定字面字符」；无法确定时返回 null。
String? _literalFirstChar(String alternative) {
  if (alternative.isEmpty) return null;
  final String ch = alternative[0];
  // 位置锚点不消费字符，往后看一个。
  if (ch == '^') return _literalFirstChar(alternative.substring(1));
  if (ch == r'$' || ch == '\\' || ch == '[' || ch == '(' || ch == '.') {
    return null;
  }
  if (ch == '*' || ch == '+' || ch == '?' || ch == '{') return null;
  return ch.toLowerCase();
}

/// 是否被屏蔽（prd F10）：命中屏蔽词或屏蔽用户。
///
/// 屏蔽词在 [FilterPrefs.regexEnabled] 开启时按正则匹配，关闭时按子串包含；
/// 屏蔽用户始终按精确匹配（昵称或用户 ID 全等）。
/// 只做本地 UI 过滤，WebSocket 消息仍照收、仍在缓存之外被丢弃。
bool isBlockedBy(DanmakuEvent event, FilterPrefs prefs) {
  if (prefs.blockedKeywords.isNotEmpty) {
    final String content = event.text;
    if (content.isNotEmpty) {
      if (prefs.regexEnabled) {
        for (final String rule in prefs.blockedKeywords) {
          // 用可匹配版本：有回溯风险的规则在这里被跳过（#79）。
          final RegExp? pattern = compileMatchableFilterRule(rule);
          if (pattern != null && pattern.hasMatch(content)) return true;
        }
      } else {
        final String lower = content.toLowerCase();
        for (final String keyword in prefs.blockedKeywords) {
          if (keyword.isEmpty) continue;
          if (lower.contains(keyword.toLowerCase())) return true;
        }
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
/// 不区分大小写；[regex] 为真时每条规则按正则匹配（对应
/// [FilterPrefs.regexEnabled]），写法非法或有回溯风险的规则跳过不报错（#79）。
/// 多个命中区间重叠时合并，保证片段首尾相接、无重复。
List<HighlightSegment> splitHighlights(
  String text,
  List<String> keywords, {
  bool regex = false,
}) {
  if (text.isEmpty) return const <HighlightSegment>[];
  final List<({int start, int end})> ranges = regex
      ? _regexHighlightRanges(text, keywords)
      : _substringHighlightRanges(text, keywords);
  if (ranges.isEmpty) {
    return <HighlightSegment>[HighlightSegment(text, highlighted: false)];
  }
  ranges.sort(
    (({int start, int end}) a, ({int start, int end}) b) =>
        a.start.compareTo(b.start),
  );

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
        HighlightSegment(
          text.substring(cursor, range.start),
          highlighted: false,
        ),
      );
    }
    segments.add(
      HighlightSegment(
        text.substring(range.start, range.end),
        highlighted: true,
      ),
    );
    cursor = range.end;
  }
  if (cursor < text.length) {
    segments.add(HighlightSegment(text.substring(cursor), highlighted: false));
  }
  return segments;
}

/// 普通模式：按子串包含找所有命中区间。
List<({int start, int end})> _substringHighlightRanges(
  String text,
  List<String> keywords,
) {
  final List<String> usable = <String>[
    for (final String keyword in keywords)
      if (keyword.trim().isNotEmpty) keyword.trim().toLowerCase(),
  ];
  if (usable.isEmpty) return const <({int start, int end})>[];
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
  return ranges;
}

/// 正则模式：每条规则编译后取全部匹配区间；空匹配（如 `a*`）不产生区间。
List<({int start, int end})> _regexHighlightRanges(
  String text,
  List<String> keywords,
) {
  final List<({int start, int end})> ranges = <({int start, int end})>[];
  for (final String rule in keywords) {
    // 同上：有回溯风险的规则不参与高亮（#79）。
    final RegExp? pattern = compileMatchableFilterRule(rule);
    if (pattern == null) continue;
    for (final RegExpMatch match in pattern.allMatches(text)) {
      if (match.end > match.start) {
        ranges.add((start: match.start, end: match.end));
      }
    }
  }
  return ranges;
}

/// 在线人数：一律给完整数字（UX-12）。
///
/// 原先过万折算成「x.x万」：栏目标识行里这一行是多栏窄窗最该保住的信息，折算后
/// 用户拿不到准确人数，而省下的几个字符换成布局收益并不划算（人数据此裁定不可省略）。
String formatOnlineCount(int value) => '$value';

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
