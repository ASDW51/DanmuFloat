import 'dart:async';

import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/ui/danmu_text_colors.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter/material.dart';

/// 主题展示名（顺序即 chips 顺序）。
/// 对比度策略的可选项与展示名（顺序即 UI 顺序）。
const List<String> overlayContrastPolicyIds = <String>[
  overlayStyleAdjustPolicy,
  overlayStyleWarnPolicy,
  overlayStyleAllowPolicy,
];

const Map<String, String> overlayContrastPolicyLabels = <String, String>{
  overlayStyleAdjustPolicy: '自动校正',
  overlayStyleWarnPolicy: '仅提示',
  overlayStyleAllowPolicy: '原样显示',
};

/// 三态的一句话解释。'自动校正'只调明度、不改色相；参照底色是面板底色（maskColor），
/// 未计入窗口不透明度、也未与直播画面合成，保证的是相对面板底色的可读性。
const String overlayContrastPolicyHint =
    '自动校正只调明度、不改色相；参照色是面板底色，未计入窗口不透明度与直播画面。';

const Map<String, String> overlayThemeLabels = <String, String>{
  'dark': '深邃',
  'light': '清爽',
  'contrast': '高对比',
  'sepia': '护眼',
};

/// 角色展示名：键与 [OverlayTheme.colorKeys] 一一对应，顺序即展示顺序。
const Map<String, String> overlayColorRoleLabels = <String, String>{
  'body': '弹幕正文',
  'secondary': '次要文字（状态、占位提示）',
  'chrome': '主播名与按钮文字',
  'userAccent': '用户昵称',
  'levelColor': '荣誉等级',
  'fanLevelColor': '粉丝灯牌等级',
  'divider': '分隔线',
  'bannerBg': '进场横幅底色',
  'border': '窗口边框',
  'maskColor': '窗口底色',
  'activeColor': '生效状态（暂停 / 焦点）',
  'chromeBg': '悬浮球/胶囊底色',
  'menuBg': '菜单面板底色',
  'typeScreenChat': '类型·普通弹幕',
  'typePrivilegeScreenChat': '类型·特权弹幕',
  'typeGift': '类型·礼物',
  'typeMember': '类型·上舰',
  'typeLike': '类型·点赞',
  'typeSocial': '类型·关注分享',
  'typeRoomRank': '类型·排行榜',
};

/// 取色候选。
///
/// 为什么不做色环：色环的拖动手势会与悬浮窗「位移超过 5px 就搬窗口」的既有判定打架，
/// 而且纯 Dart 画色环要自绘 painter；16 个候选色 + 十六进制输入已经覆盖「挑一个顺眼
/// 的颜色」这个真实需求。
const List<int> overlayColorSwatches = <int>[
  0xFFFFFFFF, 0xFFE0E0E0, 0xFF9E9E9E, 0xFF424242,
  0xFFFFEB3B, 0xFFFF9800, 0xFFFF5722, 0xFFF44336,
  0xFF69F0AE, 0xFF4CAF50, 0xFF00BCD4, 0xFF40C4FF,
  0xFF2196F3, 0xFF7C4DFF, 0xFFFF80AB, 0xFF8D6E63,
];

/// 取色对话框「恢复默认」的哨兵返回值。
///
/// 用 0 而不是 null：null 已经被 [showDialog] 的「用户取消」占用，若两者同值，取消
/// 就会被误当成恢复默认。
const int overlayColorResetSentinel = 0;

/// 设置/清除某个角色的颜色覆盖。[argb] 为 null 表示回到「跟随主题」。
Map<String, int> withColorOverride(
  Map<String, int> overrides,
  String role,
  int? argb,
) {
  final Map<String, int> next = Map<String, int>.of(overrides);
  if (argb == null) {
    next.remove(role);
  } else {
    next[role] = argb;
  }
  return next;
}

/// 把 `#RRGGBB` / `RRGGBB` 解析成不透明 ARGB；其余一律返回 null。
///
/// 只收 6 位：8 位在「AARRGGBB 还是 RRGGBBAA」上歧义太大，而这个功能的角色色一律
/// 不透明（半透明会让「选的颜色」与屏幕上看到的不一致，对比度守卫也失去意义）。
int? parseHexColor(String text) {
  final String raw = text.trim().replaceFirst('#', '');
  if (raw.length != 6) return null;
  final int? rgb = int.tryParse(raw, radix: 16);
  if (rgb == null) return null;
  return 0xFF000000 | rgb;
}

/// 把不透明 ARGB 格式化成 `#RRGGBB`（供输入框回填与副标题展示）。
String formatHexColor(int argb) {
  final int rgb = argb & 0xFFFFFF;
  return '#${rgb.toRadixString(16).toUpperCase().padLeft(6, '0')}';
}

/// 悬浮窗配色设置区：主题预设 + 逐角色「跟随主题 / 自定义」。
///
/// 独立成公开 widget 而不是塞进 settings_page 的私有小部件里：这样它能在 widget
/// 测试里被直接挂载断言，不必先搭起整个设置页的依赖。
class OverlayColorSection extends StatelessWidget {
  const OverlayColorSection({
    super.key,
    required this.themeId,
    required this.overrides,
    required this.onThemeChanged,
    required this.onOverrideChanged,
    required this.contrastPolicy,
    required this.onContrastPolicyChanged,
    this.recentColors = const <int>[],
    this.myThemes = const <MyTheme>[],
    this.onSaveMyTheme,
    this.onApplyMyTheme,
    this.onRenameMyTheme,
    this.onUpdateMyTheme,
    this.onRemoveMyTheme,
  });

  /// 当前主题标识（未知值由 [OverlayTheme.preset] 回落深色）。
  final String themeId;

  /// 角色级覆盖：角色名 → 不透明 ARGB；缺键即「跟随主题」。
  final Map<String, int> overrides;

  final ValueChanged<String> onThemeChanged;

  /// 角色色变化回调；[argb] 为 null 表示恢复「跟随主题」。
  final void Function(String role, int? argb) onOverrideChanged;

  /// 当前对比度策略（adjust / warn / allow）。
  final String contrastPolicy;

  /// 切换对比度策略。
  final ValueChanged<String> onContrastPolicyChanged;

  /// 「最近使用」的颜色（新色在前）。跨主题共用一份，由偏好层维护。
  final List<int> recentColors;

  /// 用户另存的具名主题（#147）。为空时区块只显示一句引导文案。
  final List<MyTheme> myThemes;

  /// 下面五个回调由设置页注入：保存 / 重命名 / 更新会先在偏好层校验（重名、超上限、
  /// 覆盖表为空），失败原因由设置页弹 SnackBar——本组件不重复实现业务规则。
  /// `onSaveMyTheme` 为 null 表示不显示「我的主题」区块（既有 widget 用例不受影响）。
  final ValueChanged<String>? onSaveMyTheme;
  final ValueChanged<String>? onApplyMyTheme;
  final void Function(String id, String name)? onRenameMyTheme;
  final ValueChanged<String>? onUpdateMyTheme;
  final ValueChanged<String>? onRemoveMyTheme;

  @override
  Widget build(BuildContext context) {
    final OverlayTheme base = OverlayTheme.preset(themeId).resolve(overrides);
    // 显示值必须等于运行时真正渲染的值：adjust 下窗内会先过一遍对比度守卫，
    // 设置页若照原样显示用户的选色，就会出现「我选的色怎么变了」。除了
    // enforceTextContrast 这一处，本组件与窗内 _palette 用的是同一套调用。
    final OverlayTheme theme = contrastPolicy == overlayStyleAdjustPolicy
        ? base.enforceTextContrast(4.5)
        : base;
    final Brightness brightness = Theme.of(context).brightness;
    // 默认折叠：11 个角色铺开会把设置页后面几项挤出懒加载窗口（那会让既有用例
    // 找不到「导出数据」这类条目），而且一次列 11 行本身也不好挑。
    final String summary = overrides.isEmpty
        ? '全部元素跟随主题'
        : '已自定义 ${overrides.length} 个元素';
    return ExpansionTile(
      key: const ValueKey<String>('overlayColorSection'),
      title: const Text('逐元素取色'),
      subtitle: Text(
        summary,
        style: TextStyle(fontSize: 12, color: secondaryTextColor(brightness)),
      ),
      children: <Widget>[
        // 三态放在预设 chips 之前：它决定「用户选的颜色要不要被救回来」，是这组
        // 设置的前置语义。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final String policy in overlayContrastPolicyIds)
                ChoiceChip(
                  key: ValueKey<String>('overlayContrastPolicy_$policy'),
                  label: Text(overlayContrastPolicyLabels[policy] ?? policy),
                  selected: policy == contrastPolicy,
                  onSelected: (_) => onContrastPolicyChanged(policy),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            overlayContrastPolicyHint,
            style: TextStyle(
              fontSize: 12,
              color: secondaryTextColor(brightness),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final OverlayTheme preset in OverlayTheme.presets)
                ChoiceChip(
                  key: ValueKey<String>('overlayTheme_${preset.id}'),
                  label: Text(overlayThemeLabels[preset.id] ?? preset.id),
                  selected: preset.id == theme.id,
                  onSelected: (_) => onThemeChanged(preset.id),
                ),
            ],
          ),
        ),
        if (onSaveMyTheme != null) ...<Widget>[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('我的主题', style: Theme.of(context).textTheme.titleSmall),
          ),
          if (myThemes.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                '调好颜色后点「保存为新主题」，就能在四个预设之外留住这一套（#147）',
                style: TextStyle(
                  fontSize: 12,
                  color: secondaryTextColor(brightness),
                ),
              ),
            ),
          for (final MyTheme saved in myThemes)
            ListTile(
              key: ValueKey<String>('myTheme_${saved.id}'),
              dense: true,
              title: Text(
                saved.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '基于${overlayThemeLabels[saved.baseThemeId] ?? saved.baseThemeId}'
                ' · 自定义 ${saved.overrides.length} 个元素',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextButton(
                    key: ValueKey<String>('myThemeApply_${saved.id}'),
                    onPressed: () => onApplyMyTheme?.call(saved.id),
                    child: const Text('应用'),
                  ),
                  PopupMenuButton<String>(
                    key: ValueKey<String>('myThemeMenu_${saved.id}'),
                    tooltip: '主题操作',
                    onSelected: (String action) {
                      if (action == 'rename') {
                        unawaited(_renameSavedTheme(context, saved));
                      } else if (action == 'update') {
                        onUpdateMyTheme?.call(saved.id);
                      } else if (action == 'remove') {
                        unawaited(_confirmRemoveTheme(context, saved));
                      }
                    },
                    itemBuilder: (BuildContext context) =>
                        const <PopupMenuEntry<String>>[
                          PopupMenuItem<String>(
                            value: 'rename',
                            child: Text('重命名'),
                          ),
                          PopupMenuItem<String>(
                            value: 'update',
                            child: Text('用当前配色更新'),
                          ),
                          PopupMenuItem<String>(
                            value: 'remove',
                            child: Text('删除'),
                          ),
                        ],
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey<String>('myThemeSave'),
                onPressed: () => unawaited(_saveCurrentAsTheme(context)),
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('保存为新主题'),
              ),
            ),
          ),
        ],
        const Divider(height: 1),
        for (final String role in OverlayTheme.colorKeys)
          _roleTile(context, theme, role),
      ],
    );
  }

  /// 把当前配色另存为具名主题：先问名称，再交给设置页落盘（#147）。
  Future<void> _saveCurrentAsTheme(BuildContext context) async {
    final String? name = await _askThemeName(context);
    if (name == null) return;
    onSaveMyTheme?.call(name);
  }

  Future<void> _renameSavedTheme(BuildContext context, MyTheme theme) async {
    final String? name = await _askThemeName(context, initial: theme.name);
    if (name == null) return;
    onRenameMyTheme?.call(theme.id, name);
  }

  /// 删除前二次确认（#147）：删除不可恢复，但**不影响当前配色**——当前颜色是
  /// `colorOverrides` 的那份快照，删掉主题只是删掉「以后还能找回」的入口。
  Future<void> _confirmRemoveTheme(BuildContext context, MyTheme theme) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除这个主题？'),
        content: Text('「${theme.name}」删除后无法恢复；当前正在使用的颜色不受影响。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    onRemoveMyTheme?.call(theme.id);
  }

  /// 主题命名弹窗：返回去掉首尾空白的名称；取消返回 null。
  Future<String?> _askThemeName(BuildContext context, {String? initial}) {
    return showDialog<String>(
      context: context,
      builder: (BuildContext context) => _MyThemeNameDialog(initial: initial),
    );
  }

  Widget _roleTile(BuildContext context, OverlayTheme theme, String role) {    final bool followed = !overrides.containsKey(role);
    final Color color = theme.colorOf(role);
    return ListTile(
      key: ValueKey<String>('overlayRole_$role'),
      leading: _ColorSwatch(color: color),
      title: Text(
        overlayColorRoleLabels[role] ?? role,
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text(
        followed ? '跟随主题' : formatHexColor(color.toARGB32()),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // ListTile 的行高本就 ≥56dp，已满足 UX-21 的触控口径；这里不要再套
          // SizedBox 限高——Switch 自身约 48dp 高，被裁掉后点击会落到整行的 onTap 上，
          // 于是「开自定义」变成了弹出取色对话框（用例里表现为回调一次都没触发）。
          Switch(
            key: ValueKey<String>('overlayRoleFollow_$role'),
            value: !followed,
            onChanged: (bool value) =>
                onOverrideChanged(role, value ? color.toARGB32() : null),
          ),
          IconButton(
            key: ValueKey<String>('overlayRolePick_$role'),
            tooltip: '选择颜色',
            icon: const Icon(Icons.palette_outlined, size: 20),
            onPressed: () => _pickColor(context, role, color),
          ),
        ],
      ),
      onTap: () => _pickColor(context, role, color),
    );
  }

  Future<void> _pickColor(
    BuildContext context,
    String role,
    Color current,
  ) async {
    final int? picked = await showDialog<int>(
      context: context,
      builder: (BuildContext context) =>
          _OverlayColorPickerDialog(
            role: role,
            current: current,
            recentColors: recentColors,
          ),
    );
    if (picked == null) return;
    onOverrideChanged(
      role,
      picked == overlayColorResetSentinel ? null : picked,
    );
  }
}

/// 取色对话框：候选色块 + 十六进制输入 + 恢复默认。
class _OverlayColorPickerDialog extends StatefulWidget {
  const _OverlayColorPickerDialog({
    required this.role,
    required this.current,
    required this.recentColors,
  });

  final String role;
  final Color current;

  /// 「最近使用」的颜色；为空时整块不渲染。
  final List<int> recentColors;

  @override
  State<_OverlayColorPickerDialog> createState() =>
      _OverlayColorPickerDialogState();
}

class _OverlayColorPickerDialogState extends State<_OverlayColorPickerDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: formatHexColor(widget.current.toARGB32()),
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submitText() {
    final int? parsed = parseHexColor(_controller.text);
    if (parsed == null) {
      setState(() => _error = '请输入 6 位十六进制颜色，如 #FF9800');
      return;
    }
    Navigator.of(context).pop(parsed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // 与 UX-20 的三处弹窗同一口径：小窗下也放得下、内容可滚动。
      insetPadding: const EdgeInsets.all(8),
      scrollable: true,
      title: Text(overlayColorRoleLabels[widget.role] ?? widget.role),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // 最近使用放在候选色块之前：复用比重新挑更快，且它才是用户上次真正采纳的值。
          if (widget.recentColors.isNotEmpty) ...<Widget>[
            Text(
              '最近使用',
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final int argb in widget.recentColors)
                  InkWell(
                    key: ValueKey<String>('overlayRecent_$argb'),
                    onTap: () => Navigator.of(context).pop(argb),
                    child: _ColorSwatch(color: Color(argb), size: 28),
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final int argb in overlayColorSwatches)
                InkWell(
                  key: ValueKey<String>('overlaySwatch_$argb'),
                  onTap: () => Navigator.of(context).pop(argb),
                  child: _ColorSwatch(color: Color(argb), size: 32),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const ValueKey<String>('overlayColorHexField'),
                  controller: _controller,
                  decoration: InputDecoration(
                    labelText: '十六进制颜色',
                    hintText: '#FF9800',
                    errorText: _error,
                    isDense: true,
                  ),
                  onSubmitted: (_) => _submitText(),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(onPressed: _submitText, child: const Text('应用')),
            ],
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('overlayColorReset'),
          onPressed: () =>
              Navigator.of(context).pop(overlayColorResetSentinel),
          child: const Text('恢复默认'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

/// 色块：带一圈描边，避免浅色块在浅色底上「消失」。
/// 主题命名弹窗（#147）：只负责「不为空才允许确认」与长度提示，
/// 重名 / 超上限 / 同一套配色等规则统一在偏好层校验，避免两处口径漂移。
class _MyThemeNameDialog extends StatefulWidget {
  const _MyThemeNameDialog({this.initial});

  final String? initial;

  @override
  State<_MyThemeNameDialog> createState() => _MyThemeNameDialogState();
}

class _MyThemeNameDialogState extends State<_MyThemeNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final String trimmed = _controller.text.trim();
    if (trimmed.isEmpty) return;
    Navigator.of(context).pop(trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final bool canSubmit = _controller.text.trim().isNotEmpty;
    return AlertDialog(
      title: Text(widget.initial == null ? '保存为新主题' : '重命名主题'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: myThemeMaxNameLength,
        decoration: const InputDecoration(labelText: '主题名称'),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: canSubmit ? _submit : null,
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({required this.color, this.size = 28});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
    );
  }
}

/// 窗内配色入口的选择结果。
class OverlayColorChoice {
  const OverlayColorChoice({
    required this.themeId,
    required this.resetOverrides,
    this.overrides = const <String, int>{},
  });

  final String themeId;

  /// 是否要求「全部跟随主题」——即清空主 App 里设过的角色级覆盖。
  final bool resetOverrides;

  /// 选中「我的主题」时的整份覆盖表（#147）。非空表示这次选择来自自定义主题：
  /// 窗内按「基础预设 + 本表」渲染，主 App 落盘也按这两件事写回，与设置页
  /// 「应用」走同一条数据路径，不引入第二套口径。
  final Map<String, int> overrides;
}

/// 悬浮窗内的配色入口。
///
/// 窗内只给「换一套预设」与「全部跟随主题」：窗口本身是叠在直播画面上的小块区域，
/// 逐元素取色（11 行 + 取色盘）在这里既放不下也会挡视线，细调留在主 App 设置页。
///
/// 抽成公开函数而不是塞进页面私有方法：这样它可以被 widget 测试直接挂载断言，
/// 不必 mount 整个 `OverlayPage`（后者受「每个测试文件只能 mount 一次」限制）。
Future<OverlayColorChoice?> showOverlayColorDialog(
  BuildContext context, {
  required String themeId,
  required int overrideCount,
  List<MyTheme> myThemes = const <MyTheme>[],
}) => showDialog<OverlayColorChoice>(
  context: context,
  builder: (BuildContext context) => _OverlayColorChoiceDialog(
    themeId: themeId,
    overrideCount: overrideCount,
    myThemes: myThemes,
  ),
);

class _OverlayColorChoiceDialog extends StatefulWidget {
  const _OverlayColorChoiceDialog({
    required this.themeId,
    required this.overrideCount,
    required this.myThemes,
  });

  final String themeId;
  final int overrideCount;

  /// 用户在设置页另存的具名主题（#147）。为空时这一块整段不渲染，旧的调用方
  /// （只认四个预设）行为完全不变。
  final List<MyTheme> myThemes;

  @override
  State<_OverlayColorChoiceDialog> createState() =>
      _OverlayColorChoiceDialogState();
}

class _OverlayColorChoiceDialogState extends State<_OverlayColorChoiceDialog> {
  late String _themeId = OverlayTheme.preset(widget.themeId).id;
  late bool _reset = false;

  /// 选中的自定义主题 id（#147）；null 表示选的是预设。
  String? _myThemeId;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // 与 UX-20 的三处弹窗同一口径：窗内尺寸最小可到 200×150，必须放得下且可滚动。
      insetPadding: const EdgeInsets.all(8),
      scrollable: true,
      title: const Text('悬浮窗配色'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final OverlayTheme preset in OverlayTheme.presets)
                ChoiceChip(
                  key: ValueKey<String>('overlayColorChoice_${preset.id}'),
                  label: Text(overlayThemeLabels[preset.id] ?? preset.id),
                  selected: preset.id == _themeId,
                  onSelected: (_) => setState(() {
                    _themeId = preset.id;
                    // 选预设即放弃自定义主题的选择（两者互斥，避免「看着是预设、
                    // 确定后却是自定义配色」）。
                    _myThemeId = null;
                  }),
                ),
            ],
          ),
          if (widget.myThemes.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '我的主题',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final MyTheme saved in widget.myThemes)
                  ChoiceChip(
                    key: ValueKey<String>('overlayColorMyTheme_${saved.id}'),
                    label: Text(
                      saved.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: saved.id == _myThemeId,
                    onSelected: (_) => setState(() {
                      _myThemeId = saved.id;
                      _themeId = OverlayTheme.preset(saved.baseThemeId).id;
                    }),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          CheckboxListTile(
            key: const ValueKey<String>('overlayColorResetAll'),
            value: _reset,
            onChanged: (bool? value) => setState(() => _reset = value ?? false),
            title: const Text('全部跟随主题', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              widget.overrideCount == 0
                  ? '当前没有自定义颜色'
                  : '将清除 ${widget.overrideCount} 个自定义颜色',
              style: const TextStyle(fontSize: 12),
            ),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            dense: true,
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          key: const ValueKey<String>('overlayColorConfirm'),
          onPressed: () => Navigator.of(context).pop(_choice()),
          child: const Text('确定'),
        ),
      ],
    );
  }

  /// 把当前选择收敛成结果：选中自定义主题时返回「基础预设 + 覆盖表」，
  /// 选中预设时沿用原来的两种语义（换预设 / 全部跟随主题）（#147）。
  OverlayColorChoice _choice() {
    // 「全部跟随主题」优先：用户勾了它就是要清空覆盖，自定义主题不再生效。
    if (_reset) {
      return OverlayColorChoice(themeId: _themeId, resetOverrides: true);
    }
    final String? myThemeId = _myThemeId;
    if (myThemeId != null) {
      for (final MyTheme saved in widget.myThemes) {
        if (saved.id != myThemeId) continue;
        return OverlayColorChoice(
          themeId: OverlayTheme.preset(saved.baseThemeId).id,
          resetOverrides: false,
          overrides: saved.overrides,
        );
      }
    }
    return OverlayColorChoice(themeId: _themeId, resetOverrides: _reset);
  }
}
