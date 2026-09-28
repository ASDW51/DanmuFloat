// 过滤设置二级页（prd F10 屏蔽 / F11 高亮 / F13 只看特定类型）。
//
// 从设置页「屏蔽与高亮」分区进入：设置页只留一个入口，具体编辑与教程都放这里，
// 免得设置页越堆越长。页面内自带「使用教程」折叠区，讲清普通匹配与正则匹配的差别。
//
// 落盘策略与设置页一致：任一改动立即落盘并回调外层，外层再把过滤偏好推给悬浮窗引擎。
import 'dart:async';

import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/storage/filter_store.dart';
import 'package:flutter/material.dart';

class FilterSettingsPage extends StatefulWidget {
  const FilterSettingsPage({
    super.key,
    required this.prefs,
    this.store,
    this.onChanged,
  });

  /// 进入页面时的过滤偏好快照。
  final FilterPrefs prefs;

  /// 过滤偏好存储；单测可注入内存后端。
  final FilterStore? store;

  /// 每次改动后的回调：外层负责同步给悬浮窗引擎（本页负责落盘）。
  final void Function(FilterPrefs prefs)? onChanged;

  @override
  State<FilterSettingsPage> createState() => _FilterSettingsPageState();
}

class _FilterSettingsPageState extends State<FilterSettingsPage> {
  late FilterPrefs _prefs = widget.prefs;
  late final FilterStore _store = widget.store ?? FilterStore();

  void _apply(FilterPrefs next) {
    setState(() => _prefs = next);
    widget.onChanged?.call(next);
    unawaited(_store.save(next));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('屏蔽与高亮')),
      body: ListView(
        children: <Widget>[
          const _SectionTitle('匹配方式'),
          SwitchListTile(
            title: const Text('使用正则表达式'),
            subtitle: const Text(
              '开启后「屏蔽关键词」与「高亮词」按正则解析，可匹配数字、开头结尾、多个候选等；'
              '关闭时按「内容包含该子串」匹配。「屏蔽用户」始终精确匹配，不受此开关影响。',
              style: TextStyle(fontSize: 12),
            ),
            value: _prefs.regexEnabled,
            onChanged: (bool value) =>
                _apply(_prefs.copyWith(regexEnabled: value)),
          ),
          if (_prefs.regexEnabled) _buildRuleWarnings(),
          const Divider(height: 1),
          _TutorialCard(regexEnabled: _prefs.regexEnabled),
          const Divider(height: 1),
          const _SectionTitle('屏蔽关键词'),
          _RuleListEditor(
            hint: _prefs.regexEnabled
                ? '每行一条正则，命中即不展示该条弹幕（不区分大小写）'
                : '弹幕内容包含任一关键词即不展示（不区分大小写）',
            placeholder: _prefs.regexEnabled ? r'如 ^6{3,}$' : '如 加群',
            values: _prefs.blockedKeywords,
            regexEnabled: _prefs.regexEnabled,
            validateRegex: true,
            onChanged: (List<String> values) =>
                _apply(_prefs.copyWith(blockedKeywords: values)),
          ),
          const Divider(height: 1),
          const _SectionTitle('屏蔽用户'),
          _RuleListEditor(
            hint: '填写用户昵称或用户 ID，命中即不展示其弹幕与进场（精确匹配）',
            placeholder: '如 张三',
            values: _prefs.blockedUsers,
            regexEnabled: false,
            validateRegex: false,
            onChanged: (List<String> values) =>
                _apply(_prefs.copyWith(blockedUsers: values)),
          ),
          const Divider(height: 1),
          const _SectionTitle('高亮词'),
          _RuleListEditor(
            hint: _prefs.regexEnabled
                ? '每行一条正则，命中的片段会以高亮色显示'
                : '命中的片段会以高亮色显示（不区分大小写）',
            placeholder: _prefs.regexEnabled ? '如 (抽奖|福利)' : '如 抽奖',
            values: _prefs.highlightKeywords,
            regexEnabled: _prefs.regexEnabled,
            validateRegex: true,
            onChanged: (List<String> values) =>
                _apply(_prefs.copyWith(highlightKeywords: values)),
          ),
          const Divider(height: 1),
          const _SectionTitle('列表显示的类型'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              '默认只显示聊天类弹幕；勾选后可把礼物 / 进场 / 点赞 / 关注 / 榜单一并列入',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                for (final DanmakuKind kind in selectableListKinds)
                  FilterChip(
                    label: Text(danmakuKindLabel(kind)),
                    selected: _prefs.visibleKinds.contains(kind),
                    onSelected: (bool selected) => _apply(
                      _prefs.copyWith(
                        visibleKinds: _toggleKind(kind, selected),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }

  /// 正则模式下提示哪些规则写法非法（非法规则会被跳过，不参与匹配）。
  Widget _buildRuleWarnings() {
    final List<String> invalid = <String>[
      ...invalidFilterRules(_prefs.blockedKeywords),
      ...invalidFilterRules(_prefs.highlightKeywords),
    ];
    if (invalid.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0x22FF5252),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '以下规则不是合法正则，已跳过（不影响其它规则）：',
              style: TextStyle(fontSize: 12, color: Color(0xFFD32F2F)),
            ),
            const SizedBox(height: 4),
            for (final String rule in invalid)
              Text(
                '• $rule',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFFD32F2F),
                  fontFamily: 'monospace',
                ),
              ),
          ],
        ),
      ),
    );
  }

  Set<DanmakuKind> _toggleKind(DanmakuKind kind, bool selected) {
    final Set<DanmakuKind> next = <DanmakuKind>{..._prefs.visibleKinds};
    if (selected) {
      next.add(kind);
    } else {
      next.remove(kind);
    }
    return next;
  }
}

/// 「使用教程」折叠区：讲清三种规则的作用与正则写法。
class _TutorialCard extends StatelessWidget {
  const _TutorialCard({required this.regexEnabled});

  final bool regexEnabled;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: const Icon(Icons.help_outline),
      title: const Text('使用教程'),
      subtitle: Text(
        regexEnabled ? '当前：正则匹配' : '当前：包含匹配',
        style: const TextStyle(fontSize: 12),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text('1. 屏蔽关键词', style: TextStyle(fontWeight: FontWeight.bold)),
        const Text(
          '弹幕正文命中任一规则就整条不展示。适合屏蔽广告、刷屏、加群引流等内容。',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 12),
        const Text('2. 屏蔽用户', style: TextStyle(fontWeight: FontWeight.bold)),
        const Text(
          '按用户昵称或用户 ID 精确匹配（完全相等才算命中），命中后该用户的弹幕与进场都不展示。'
          '这一项不支持正则，也不区分开关状态。',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 12),
        const Text('3. 高亮词', style: TextStyle(fontWeight: FontWeight.bold)),
        const Text(
          '命中的片段用高亮色显示，其余内容照常展示；不影响屏蔽逻辑，可与屏蔽词同时使用。',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 12),
        const Text('4. 正则匹配怎么用', style: TextStyle(fontWeight: FontWeight.bold)),
        const Text(
          '打开上面的「使用正则表达式」开关后，屏蔽关键词与高亮词的每一条都会被当作正则解析。'
          '不区分大小写。下面是最常用的写法：',
          style: TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 8),
        const _RegexCheatSheet(),
        const SizedBox(height: 12),
        const Text('5. 常见示例', style: TextStyle(fontWeight: FontWeight.bold)),
        const _ExampleList(),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0x1A2196F3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            '提示：写法非法的规则会被自动跳过，不会影响其它规则，页面顶部也会列出是哪几条。'
            '不确定写法是否正确时，可以先用一条规则单独试。',
            style: TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
  }
}

/// 正则语法速查表。
class _RegexCheatSheet extends StatelessWidget {
  const _RegexCheatSheet();

  /// (写法, 含义, 示例说明)
  static const List<(String, String, String)> _rows = <(String, String, String)>[
    (r'\d', '任意数字', r'\d+ 匹配一段连续数字'),
    (r'\w', '字母、数字或下划线', r'\w+ 匹配一个词'),
    (r'\s', '空白字符', r'加\s*群 中间可含空格'),
    (r'^', '文本开头', r'^6 只匹配以 6 开头的内容'),
    (r'$', '文本结尾', r'6$ 只匹配以 6 结尾的内容'),
    ('|', '或者', '(抽奖|福利) 命中其一'),
    ('[]', '字符集中任一', '[abc] 匹配 a、b 或 c'),
    ('*', '前面的内容出现 0 次或多次', 'ab*c 匹配 ac、abc、abbc'),
    ('+', '前面的内容出现 1 次或多次', '6+ 匹配 6、66、666'),
    ('{n,m}', '前面的内容出现 n~m 次', r'\d{3,6} 匹配 3~6 位数字'),
    ('.', '任意单个字符', 'a.c 匹配 abc、a1c'),
  ];

  @override
  Widget build(BuildContext context) {
    return Table(
      border: TableBorder.all(color: const Color(0x22000000)),
      columnWidths: const <int, TableColumnWidth>{
        0: FixedColumnWidth(56),
        1: FlexColumnWidth(1.3),
        2: FlexColumnWidth(1.7),
      },
      children: <TableRow>[
        for (final (String token, String meaning, String example) in _rows)
          TableRow(
            children: <Widget>[
              _cell(token, mono: true),
              _cell(meaning),
              _cell(example, muted: true),
            ],
          ),
      ],
    );
  }

  Widget _cell(String text, {bool mono = false, bool muted = false}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontFamily: mono ? 'monospace' : null,
            color: muted ? Colors.grey[700] : null,
          ),
        ),
      );
}

/// 常见示例列表：(规则, 说明)
class _ExampleList extends StatelessWidget {
  const _ExampleList();

  static const List<(String, String)> _examples = <(String, String)>[
    (r'^6{3,}$', '屏蔽整条都是 666 的刷屏'),
    (r'^\d+$', '屏蔽整条只有数字的弹幕'),
    (r'https?://', '屏蔽带链接的内容'),
    (r'(加群|加v|私聊|微信)', '屏蔽引流关键词的多种写法'),
    (r'(抽奖|福利|红包)', '高亮抽奖类消息'),
    (r'(\S)\1{3,}', '高亮 / 屏蔽连续重复 4 次以上的字符'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final (String rule, String note) in _examples)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  flex: 4,
                  child: Text(
                    rule,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                Expanded(
                  flex: 6,
                  child: Text(
                    note,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 一行一条规则的编辑控件：已添加的以 Chip 展示，可单个删除。
class _RuleListEditor extends StatefulWidget {
  const _RuleListEditor({
    required this.hint,
    required this.placeholder,
    required this.values,
    required this.onChanged,
    this.regexEnabled = false,
    this.validateRegex = false,
  });

  final String hint;
  final String placeholder;
  final List<String> values;
  final ValueChanged<List<String>> onChanged;

  /// 当前是否处于正则模式，仅用于即时校验提示。
  final bool regexEnabled;

  /// 该列表是否支持正则（屏蔽用户为 false）。
  final bool validateRegex;

  @override
  State<_RuleListEditor> createState() => _RuleListEditorState();
}

class _RuleListEditorState extends State<_RuleListEditor> {
  final TextEditingController _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add() {
    final String raw = _controller.text;
    // 正则模式下先校验写法，非法就不让添加，避免存进去后被静默跳过。
    if (widget.regexEnabled &&
        widget.validateRegex &&
        compileFilterRule(raw) == null) {
      setState(() => _error = raw.trim().isEmpty
          ? '请输入内容'
          : '正则写法不合法，请检查括号、方括号是否配对');
      return;
    }
    final List<String> next = normalizeKeywordList(<Object?>[
      ...widget.values,
      raw,
    ]);
    _controller.clear();
    setState(() => _error = null);
    // 空输入或重复项不产生变化，跳过回调避免无谓落盘。
    if (next.length == widget.values.length) return;
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            widget.hint,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          if (widget.values.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 2,
              children: <Widget>[
                for (final String value in widget.values)
                  InputChip(
                    label: Text(value),
                    onDeleted: () => widget.onChanged(
                      normalizeKeywordList(<Object?>[
                        for (final String item in widget.values)
                          if (item != value) item,
                      ]),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            style: widget.regexEnabled
                ? const TextStyle(fontFamily: 'monospace')
                : null,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: widget.placeholder,
              errorText: _error,
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _add(),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('添加'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分区标题，与设置页保持同一样式。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
}