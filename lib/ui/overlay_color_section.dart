import 'package:danmu_float/ui/danmu_text_colors.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
import 'package:flutter/material.dart';

/// 主题展示名（顺序即 chips 顺序）。
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
  });

  /// 当前主题标识（未知值由 [OverlayTheme.preset] 回落深色）。
  final String themeId;

  /// 角色级覆盖：角色名 → 不透明 ARGB；缺键即「跟随主题」。
  final Map<String, int> overrides;

  final ValueChanged<String> onThemeChanged;

  /// 角色色变化回调；[argb] 为 null 表示恢复「跟随主题」。
  final void Function(String role, int? argb) onOverrideChanged;

  @override
  Widget build(BuildContext context) {
    final OverlayTheme theme = OverlayTheme.preset(themeId).resolve(overrides);
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
        const Divider(height: 1),
        for (final String role in OverlayTheme.colorKeys)
          _roleTile(context, theme, role),
      ],
    );
  }

  Widget _roleTile(BuildContext context, OverlayTheme theme, String role) {
    final bool followed = !overrides.containsKey(role);
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
          _OverlayColorPickerDialog(role: role, current: current),
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
  const _OverlayColorPickerDialog({required this.role, required this.current});

  final String role;
  final Color current;

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
  });

  final String themeId;

  /// 是否要求「全部跟随主题」——即清空主 App 里设过的角色级覆盖。
  final bool resetOverrides;
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
}) => showDialog<OverlayColorChoice>(
  context: context,
  builder: (BuildContext context) => _OverlayColorChoiceDialog(
    themeId: themeId,
    overrideCount: overrideCount,
  ),
);

class _OverlayColorChoiceDialog extends StatefulWidget {
  const _OverlayColorChoiceDialog({
    required this.themeId,
    required this.overrideCount,
  });

  final String themeId;
  final int overrideCount;

  @override
  State<_OverlayColorChoiceDialog> createState() =>
      _OverlayColorChoiceDialogState();
}

class _OverlayColorChoiceDialogState extends State<_OverlayColorChoiceDialog> {
  late String _themeId = OverlayTheme.preset(widget.themeId).id;
  late bool _reset = false;

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
                  onSelected: (_) => setState(() => _themeId = preset.id),
                ),
            ],
          ),
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
          onPressed: () => Navigator.of(context).pop(
            OverlayColorChoice(themeId: _themeId, resetOverrides: _reset),
          ),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
