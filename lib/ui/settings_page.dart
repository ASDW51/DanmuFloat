// 设置二级页（prd F2 / F5 / F6 / F7 / F10 / F11 / F13 / F20 / F25 / F26 / F27）：
// 分「悬浮窗样式 / 主题与皮肤 / 屏蔽与高亮 / 悬浮窗尺寸 / 按栏独立配置 /
// 栏位与手势 / 连接与凭证 / 数据与隐私 / 合规 / 诊断」几个分区，用分割线隔开。
//
// 拖动滑杆过程只做实时预览（persist: false，只推给悬浮窗），松手才落盘，
// 免得一次拖动写几十次文件。
import 'dart:async';

import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/app/overlay_launcher.dart';
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/credential/credential_store.dart';
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/storage/filter_store.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/storage/theme_store.dart';
import 'package:danmu_float/ui/disclaimer_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.prefs,
    required this.onChanged,
    this.onResetAll,
    this.credentialStore,
    this.filter = const FilterPrefs(),
    this.filterStore,
    this.onFilterChanged,
    this.themeStore,
  });

  /// 进入页面时的偏好快照。
  final OverlayPrefs prefs;

  /// 偏好变化回调；[persist] 为真时调用方负责落盘。
  final void Function(OverlayPrefs prefs, {required bool persist}) onChanged;

  /// 「清除所有本地数据」的完整动作：断开连接、清空全部持久化数据、
  /// 把入口切回免责声明页（prd F26 硬要求）。为 null 时该项禁用。
  final Future<void> Function()? onResetAll;

  /// 凭证存储；单测可注入内存后端。
  final CredentialStore? credentialStore;

  /// 进入页面时的过滤偏好快照（prd F10 / F11 / F13）。
  final FilterPrefs filter;

  /// 过滤偏好存储；单测可注入内存后端。
  final FilterStore? filterStore;

  /// 过滤偏好变化回调：调用方负责同步给悬浮窗引擎（本页负责落盘）。
  final void Function(FilterPrefs prefs)? onFilterChanged;

  /// 主 App 主题偏好存储；单测可注入内存后端。
  final ThemeStore? themeStore;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late OverlayPrefs _prefs = widget.prefs;
  late final CredentialStore _credentialStore =
      widget.credentialStore ?? CredentialStore();
  late final FilterStore _filterStore = widget.filterStore ?? FilterStore();
  late final ThemeStore _themeStore = widget.themeStore ?? ThemeStore();

  void _apply(OverlayPrefs next, {required bool persist}) {
    setState(() => _prefs = next);
    widget.onChanged(next, persist: persist);
  }

  /// 切换主 App 主题（prd F20）：先改全局通知量让界面立刻换肤，再落盘。
  ///
  /// 落盘失败不回滚：本次会话内主题已生效，下次启动回落到上次成功保存的值。
  Future<void> _setThemeMode(ThemeMode mode) async {
    appThemeMode.value = mode;
    if (mounted) setState(() {});
    try {
      await _themeStore.save(mode);
    } on Object catch (exception) {
      debugPrint('保存主题偏好失败: $exception');
    }
  }

  @override
  Widget build(BuildContext context) {
    // 窗口不能大于屏幕，滑杆上限按当前设备收紧；存量偏好超出时显示值也一并收敛。
    final Size screen = MediaQuery.sizeOf(context);
    final double widthLimit = overlayWidthLimit(screen.width);
    final double heightLimit = overlayHeightLimit(screen.height);
    final double widthValue =
        _prefs.windowWidth.clamp(minOverlayWidth, widthLimit);
    final double heightValue =
        _prefs.windowHeight.clamp(minOverlayHeight, heightLimit);
    final ({double width, double height}) recommended = fitOverlaySize(
      recommendedOverlaySize(_prefs.webRids.length),
      screenWidth: screen.width,
      screenHeight: screen.height,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: <Widget>[
          const _SectionTitle('悬浮窗样式'),
          _SliderGroup(
            title: '弹幕背景透明度　${_prefs.opacity.toStringAsFixed(2)}',
            hint: '越低越透。只影响弹幕背景蒙版，不改变悬浮窗整体与文字。',
            value: _prefs.opacity,
            min: minOverlayOpacity,
            max: maxOverlayOpacity,
            divisions: 12,
            onChanged: (double value) => _apply(
              _prefs.copyWith(opacity: value),
              persist: false,
            ),
            onChangeEnd: (double value) => _apply(
              _prefs.copyWith(opacity: value),
              persist: true,
            ),
          ),
          const Divider(height: 1),
          const _SectionTitle('弹幕字号'),
          _SliderGroup(
            title: '弹幕字号　${_prefs.fontSize.toStringAsFixed(0)}',
            hint: '悬浮窗与 App 内弹幕页都按此字号显示；多栏时按栏数自动缩小。',
            value: _prefs.fontSize,
            min: minDanmuFontSize,
            max: maxDanmuFontSize,
            divisions: (maxDanmuFontSize - minDanmuFontSize).round(),
            onChanged: (double value) => _apply(
              _prefs.copyWith(fontSize: value),
              persist: false,
            ),
            onChangeEnd: (double value) => _apply(
              _prefs.copyWith(fontSize: value),
              persist: true,
            ),
          ),
          const Divider(height: 1),
          const _SectionTitle('弹幕滚动速度'),
          _SliderGroup(
            title: '滚动速度　${_prefs.scrollSpeed.toStringAsFixed(2)}x',
            hint: '越小滚得越慢、越好读；突发大量弹幕时列表按此速度平滑滚动，不再一帧跳到底。',
            value: _prefs.scrollSpeed,
            min: minDanmuScrollSpeed,
            max: maxDanmuScrollSpeed,
            divisions: ((maxDanmuScrollSpeed - minDanmuScrollSpeed) / 0.25).round(),
            onChanged: (double value) => _apply(
              _prefs.copyWith(scrollSpeed: value),
              persist: false,
            ),
            onChangeEnd: (double value) => _apply(
              _prefs.copyWith(scrollSpeed: value),
              persist: true,
            ),
          ),
          const Divider(height: 1),
          const _SectionTitle('主题与皮肤'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              '主 App 的深浅色；悬浮窗皮肤单独设置（prd F20）。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Wrap(
              spacing: 8,
              children: <Widget>[
                for (final ({String label, ThemeMode mode}) choice
                    in _themeChoices)
                  ChoiceChip(
                    label: Text(choice.label),
                    selected: appThemeMode.value == choice.mode,
                    onSelected: (_) => _setThemeMode(choice.mode),
                  ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.contrast_outlined),
            title: const Text('悬浮窗浅色皮肤'),
            subtitle: const Text(
              '深色直播画面上建议关闭；浅色画面下开启更清晰',
              style: TextStyle(fontSize: 12),
            ),
            trailing: Switch(
              value: _prefs.lightTheme,
              onChanged: (bool value) => _apply(
                _prefs.copyWith(lightTheme: value),
                persist: true,
              ),
            ),
          ),
          const Divider(height: 1),
          const _SectionTitle('屏蔽与高亮'),
          _FilterSection(
            prefs: widget.filter,
            store: _filterStore,
            onChanged: widget.onFilterChanged,
          ),
          const Divider(height: 1),
          const _SectionTitle('悬浮窗尺寸（整体）'),
          _SliderGroup(
            title: '整体宽度　${widthValue.toStringAsFixed(0)}',
            hint: '整个悬浮窗的宽度，多栏时各栏在内部自动平分，不需要按栏设置。',
            value: widthValue,
            min: minOverlayWidth,
            max: widthLimit,
            divisions: ((widthLimit - minOverlayWidth) / 20).round(),
            onChanged: (double value) => _apply(
              _prefs.copyWith(windowWidth: value),
              persist: false,
            ),
            onChangeEnd: (double value) => _apply(
              _prefs.copyWith(windowWidth: value),
              persist: true,
            ),
          ),
          _SliderGroup(
            title: '整体高度　${heightValue.toStringAsFixed(0)}',
            hint: '整个悬浮窗的高度，各栏等分；高度只影响可见弹幕条数，不影响连接。',
            value: heightValue,
            min: minOverlayHeight,
            max: heightLimit,
            divisions: ((heightLimit - minOverlayHeight) / 20).round(),
            onChanged: (double value) => _apply(
              _prefs.copyWith(windowHeight: value),
              persist: false,
            ),
            onChangeEnd: (double value) => _apply(
              _prefs.copyWith(windowHeight: value),
              persist: true,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: <Widget>[
                OutlinedButton.icon(
                  icon: const Icon(Icons.fit_screen_outlined),
                  label: const Text('按栏数推荐尺寸'),
                  onPressed: () => _applyRecommendedSize(recommended),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '按上次勾选的 ${_prefs.webRids.length} 栏推荐，'
                    '${recommended.width.toStringAsFixed(0)}'
                    '×'
                    '${recommended.height.toStringAsFixed(0)}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          const _SectionTitle('按栏独立配置'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              '逐栏覆盖字号 / 透明度 / 颜色；不调整的栏全部跟随上面的全局样式。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          _PaneStyleSection(
            webRids: _prefs.webRids,
            styles: _prefs.paneStyles,
            onChanged: (Map<String, PaneStyle> styles) => _apply(
              _prefs.copyWith(paneStyles: styles),
              persist: true,
            ),
          ),
          const Divider(height: 1),
          const _SectionTitle('栏位与手势'),
          ListTile(
            leading: const Icon(Icons.label_outline),
            title: const Text('显示栏目标识'),
            subtitle: const Text(
              '每栏顶部的状态灯、主播名与在线人数；关闭后弹幕占满整栏（prd F6）',
              style: TextStyle(fontSize: 12),
            ),
            trailing: Switch(
              value: _prefs.showTitleBar,
              onChanged: (bool value) => _apply(
                _prefs.copyWith(showTitleBar: value),
                persist: true,
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text('焦点模式（prd F7）：点某栏标题行的全屏图标放大该栏，其余栏按下面方式处理'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Wrap(
              spacing: 8,
              children: <Widget>[
                ChoiceChip(
                  label: const Text('其余栏缩小'),
                  selected: _prefs.focusBehavior == focusBehaviorShrink,
                  onSelected: (_) => _apply(
                    _prefs.copyWith(focusBehavior: focusBehaviorShrink),
                    persist: true,
                  ),
                ),
                ChoiceChip(
                  label: const Text('其余栏隐藏'),
                  selected: _prefs.focusBehavior == focusBehaviorHide,
                  onSelected: (_) => _apply(
                    _prefs.copyWith(focusBehavior: focusBehaviorHide),
                    persist: true,
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              '手势（prd F21）：双击弹幕区暂停 / 继续；长按后上下滑动调节本栏透明度',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          const Divider(height: 1),
          const _SectionTitle('连接与凭证'),
          _CredentialSection(store: _credentialStore),
          const Divider(height: 1),
          const _SectionTitle('数据与隐私'),
          ListTile(
            leading: const Icon(Icons.key_off_outlined),
            title: const Text('清除本地凭证'),
            subtitle: const Text('删除已加密保存的手动凭证，回到匿名自动获取；不影响其他配置'),
            onTap: _clearCredential,
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined),
            title: const Text('清除所有本地数据'),
            subtitle: const Text('断开连接并重置全部本地数据（含凭证密文），等同恢复初始状态'),
            onTap: widget.onResetAll == null ? null : _clearAllData,
          ),
          const Divider(height: 1),
          const _SectionTitle('合规'),
          ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: const Text('查看免责声明'),
            subtitle: const Text('首次启动需勾选同意，此处可随时重看'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openDisclaimer,
          ),
          const Divider(height: 1),
          const _SectionTitle('诊断'),
          ListTile(
            leading: const Icon(Icons.content_copy_outlined),
            title: const Text('复制诊断信息'),
            subtitle: const Text('当前样式与凭证来源摘要，反馈问题时一并提供'),
            onTap: _copyDiagnostics,
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }

  /// 从设置页重进免责声明（prd F25）；已同意过，同意动作只做幂等写回。
  void _openDisclaimer() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => DisclaimerPage(onAgree: _noopAgree),
      ),
    );
  }

  Future<void> _noopAgree() async {}

  /// 按上次勾选的栏数套用推荐尺寸；没勾过任何栏位时按单栏推荐。
  void _applyRecommendedSize(({double width, double height}) size) {
    _apply(
      _prefs.copyWith(windowWidth: size.width, windowHeight: size.height),
      persist: true,
    );
  }

  /// 清除本地凭证（prd F26）：二次确认后删除密文并同步给悬浮窗引擎。
  Future<void> _clearCredential() async {
    final bool confirmed = await _confirm(
      title: '清除本地凭证',
      content: '将删除已加密保存的手动凭证，之后回退为匿名自动获取。'
          '已建立的连接不受影响，下次连接按新凭证取。',
      confirmText: '清除',
    );
    if (!confirmed || !mounted) return;

    await _credentialStore.clearManual();
    await shareOverlayCredential(null);
    if (!mounted) return;
    setState(() {});
    _snack('已清除本地凭证');
  }

  /// 清除所有本地数据（prd F26 硬要求）：二次确认后交给外层依次完成
  /// 「断开连接 → 清空数据 → 切回免责声明页」。
  Future<void> _clearAllData() async {
    final Future<void> Function()? reset = widget.onResetAll;
    if (reset == null) return;
    final bool confirmed = await _confirm(
      title: '清除所有本地数据',
      content: '将断开全部连接、关闭悬浮窗，并删除主播列表、样式偏好、'
          '合规状态与凭证密文，等同恢复初始状态。此操作不可撤销。',
      confirmText: '清除并重置',
    );
    if (!confirmed || !mounted) return;

    final NavigatorState navigator = Navigator.of(context);
    await reset();
    if (!mounted) return;
    // 清完回到入口页：把设置页从栈里弹掉，露出重置后的首页/免责声明页。
    navigator.popUntil((Route<dynamic> route) => route.isFirst);
  }

  Future<bool> _confirm({
    required String title,
    required String content,
    required String confirmText,
  }) async {
    final bool? result = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// 诊断摘要：只放样式与来源，不含任何凭证明文（prd 3.2）。
  Future<void> _copyDiagnostics() async {
    final String summary = <String>[
      '透明度：${_prefs.opacity.toStringAsFixed(2)}',
      '字号：${_prefs.fontSize.toStringAsFixed(0)}',
      '滚动速度：${_prefs.scrollSpeed.toStringAsFixed(2)}x',
      '窗口：${_prefs.windowWidth.toStringAsFixed(0)}'
          '×${_prefs.windowHeight.toStringAsFixed(0)}',
      '栏位：${_prefs.webRids.length}',
      '主题：${_themeModeLabel(appThemeMode.value)}'
          '（悬浮窗${_prefs.lightTheme ? '浅色' : '深色'}皮肤）',
      '栏目标识：${_prefs.showTitleBar ? '显示' : '隐藏'}'
          '；焦点模式其余栏${_prefs.focusBehavior == focusBehaviorHide ? '隐藏' : '缩小'}',
      '凭证来源：'
          '${_credentialStore.isManual ? '手动粘贴（已加密保存）' : '匿名自动获取（仅内存）'}',
      '悬浮窗：${overlayShown ? '已开启' : '未开启'}',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: summary));
    if (!mounted) return;
    _snack('已复制诊断信息');
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 「连接与凭证」分区：状态行 + 手动粘贴兜底（prd F27）。
///
/// 粘贴框用 obscure，已保存的凭证不回显，只展示来源状态。
class _CredentialSection extends StatefulWidget {
  const _CredentialSection({required this.store});

  final CredentialStore store;

  @override
  State<_CredentialSection> createState() => _CredentialSectionState();
}

class _CredentialSectionState extends State<_CredentialSection> {
  final TextEditingController _controller = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 读一次已保存的凭证，保证状态行与实际一致（明文不落到界面）。
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    await widget.store.load();
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _save() async {
    final String raw = _controller.text;
    setState(() {
      _saving = true;
      _error = null;
    });
    final String? error = await widget.store.saveManual(raw);
    if (!mounted) return;
    setState(() => _saving = false);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    // 立刻把新凭证同步给悬浮窗引擎，之后新建的栏位按它取。
    await shareOverlayCredential(manualCookies);
    if (!mounted) return;
    _controller.clear();
    setState(() {});
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('凭证已加密保存')));
  }

  @override
  Widget build(BuildContext context) {
    final CredentialStore store = widget.store;
    final bool manual = store.isManual;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ListTile(
          dense: true,
          leading: Icon(
            manual ? Icons.key_outlined : Icons.public_outlined,
            color: manual ? Colors.orange : Colors.blueGrey,
          ),
          title: Text(manual ? '手动粘贴' : '匿名自动获取（仅内存）'),
          subtitle: Text(
            manual
                ? '使用你粘贴的凭证，已加密保存在本机；可随时清除'
                : '启动时自动获取 ttwid，仅在内存中持有，App 关闭即失效',
            style: const TextStyle(fontSize: 12),
          ),
        ),
        if (store.decryptFailed)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              '已保存的凭证解密失败，请在下方重新粘贴',
              style: TextStyle(fontSize: 12, color: Colors.redAccent),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            controller: _controller,
            // 凭证明文不回显（prd F27）。
            obscureText: true,
            maxLines: 1,
            decoration: InputDecoration(
              labelText: '手动粘贴凭证（兜底）',
              hintText: '仅在自动获取失败时使用，形如 ttwid=xxx; ...',
              errorText: _error,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: <Widget>[
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('加密保存'),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  '仅做本地格式校验后加密保存；不上传、不明文打印',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          text,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      );
}

/// 一条带说明文字的滑杆。
///
/// 不用 ListTile 包 Slider：subtitle 的高度约束会把滑杆压扁。
class _SliderGroup extends StatelessWidget {
  const _SliderGroup({
    required this.title,
    required this.hint,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final String title;
  final String hint;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SizedBox(height: 8),
            Text(title),
            Slider(
              value: value,
              min: min,
              max: max,
              divisions: divisions,
              label: value.toStringAsFixed(0),
              // 拖动中实时预览，松手才落盘。
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
            Text(
              hint,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 8),
          ],
        ),
      );
}

/// 「屏蔽与高亮」分区（prd F10 / F11 / F13）。
///
/// 三类关键词（屏蔽词 / 屏蔽用户 / 高亮词）各一行一个词；类型为多选。
/// 任一改动都会立即落盘并回调外层，外层再把过滤偏好推给悬浮窗引擎。
class _FilterSection extends StatefulWidget {
  const _FilterSection({
    required this.prefs,
    required this.store,
    this.onChanged,
  });

  final FilterPrefs prefs;
  final FilterStore store;
  final void Function(FilterPrefs prefs)? onChanged;

  @override
  State<_FilterSection> createState() => _FilterSectionState();
}

class _FilterSectionState extends State<_FilterSection> {
  late FilterPrefs _prefs = widget.prefs;

  void _apply(FilterPrefs next) {
    setState(() => _prefs = next);
    widget.onChanged?.call(next);
    unawaited(widget.store.save(next));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _KeywordListEditor(
          title: '屏蔽关键词',
          hint: '弹幕内容包含任一关键词即不展示（不区分大小写）',
          values: _prefs.blockedKeywords,
          onChanged: (List<String> values) =>
              _apply(_prefs.copyWith(blockedKeywords: values)),
        ),
        const Divider(height: 1),
        _KeywordListEditor(
          title: '屏蔽用户',
          hint: '填写用户昵称或用户 ID，命中即不展示其弹幕与进场',
          values: _prefs.blockedUsers,
          onChanged: (List<String> values) =>
              _apply(_prefs.copyWith(blockedUsers: values)),
        ),
        const Divider(height: 1),
        _KeywordListEditor(
          title: '高亮词',
          hint: '命中片段会以高亮色显示',
          values: _prefs.highlightKeywords,
          onChanged: (List<String> values) =>
              _apply(_prefs.copyWith(highlightKeywords: values)),
        ),
        const Divider(height: 1),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('列表显示的类型'),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 2, 16, 4),
          child: Text(
            '默认只显示聊天类弹幕；勾选后可把礼物 / 进场 / 点赞等一并列入',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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
      ],
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

/// 一行一个词的编辑控件：已添加的以 Chip 展示，可单个删除。
class _KeywordListEditor extends StatefulWidget {
  const _KeywordListEditor({
    required this.title,
    required this.hint,
    required this.values,
    required this.onChanged,
  });

  final String title;
  final String hint;
  final List<String> values;
  final ValueChanged<List<String>> onChanged;

  @override
  State<_KeywordListEditor> createState() => _KeywordListEditorState();
}

class _KeywordListEditorState extends State<_KeywordListEditor> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _add() {
    final List<String> next = normalizeKeywordList(<Object?>[
      ...widget.values,
      _controller.text,
    ]);
    _controller.clear();
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
          Text(widget.title),
          const SizedBox(height: 4),
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
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              hintText: '输入后点右侧「添加」',
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

/// 主 App 主题模式选项（prd F20）。
const List<({String label, ThemeMode mode})> _themeChoices =
    <({String label, ThemeMode mode})>[
  (label: '跟随系统', mode: ThemeMode.system),
  (label: '浅色', mode: ThemeMode.light),
  (label: '深色', mode: ThemeMode.dark),
];

/// 主题模式的中文短名（诊断摘要用）。
String _themeModeLabel(ThemeMode mode) => switch (mode) {
      ThemeMode.light => '浅色',
      ThemeMode.dark => '深色',
      ThemeMode.system => '跟随系统',
    };

/// 单栏可选的正文颜色（深色悬浮窗上足够醒目，prd F5）。
const List<({String label, int value})> _paneColorChoices =
    <({String label, int value})>[
  (label: '白', value: 0xFFFFFFFF),
  (label: '黄', value: 0xFFFFEB3B),
  (label: '橙', value: 0xFFFF9800),
  (label: '绿', value: 0xFF69F0AE),
  (label: '蓝', value: 0xFF40C4FF),
  (label: '粉', value: 0xFFFF80AB),
];

/// 「按栏独立配置」分区（prd F5）：逐栏覆盖字号 / 透明度 / 颜色。
///
/// 覆盖按 webRid 保存，换绑栏位后样式仍跟着房间走；未覆盖的栏跟全局。
class _PaneStyleSection extends StatelessWidget {
  const _PaneStyleSection({
    required this.webRids,
    required this.styles,
    required this.onChanged,
  });

  final List<String> webRids;
  final Map<String, PaneStyle> styles;
  final ValueChanged<Map<String, PaneStyle>> onChanged;

  @override
  Widget build(BuildContext context) {
    if (webRids.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Text(
          '暂无已选主播：先在首页勾选多栏主播，再回来逐栏调整。',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      );
    }
    return Column(
      children: <Widget>[
        for (final String webRid in webRids)
          ListTile(
            dense: true,
            title: Text(webRid),
            subtitle: Text(
              _summary(styles[webRid]),
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            trailing: TextButton(
              onPressed: () => _edit(context, webRid),
              child: const Text('调整'),
            ),
          ),
      ],
    );
  }

  String _summary(PaneStyle? style) {
    if (style == null || style.isEmpty) return '跟随全局';
    return <String>[
      if (style.fontSize != null) '字号 ${style.fontSize!.toStringAsFixed(0)}',
      if (style.opacity != null) '透明度 ${style.opacity!.toStringAsFixed(2)}',
      if (style.textColor != null) '自定义颜色',
    ].join(' · ');
  }

  Future<void> _edit(BuildContext context, String webRid) async {
    final PaneStyle? result = await showDialog<PaneStyle>(
      context: context,
      builder: (BuildContext context) => _PaneStyleDialog(
        roomId: webRid,
        style: styles[webRid] ?? const PaneStyle(),
      ),
    );
    // 取消（null）不改动；「恢复默认」会回传空的 PaneStyle，据此删除覆盖。
    if (result == null) return;
    final Map<String, PaneStyle> next = Map<String, PaneStyle>.of(styles);
    if (result.isEmpty) {
      next.remove(webRid);
    } else {
      next[webRid] = result;
    }
    onChanged(next);
  }
}

/// 单栏样式调整弹窗：三个覆盖项各自可开关，关闭即跟随全局。
class _PaneStyleDialog extends StatefulWidget {
  const _PaneStyleDialog({required this.roomId, required this.style});

  final String roomId;
  final PaneStyle style;

  @override
  State<_PaneStyleDialog> createState() => _PaneStyleDialogState();
}

class _PaneStyleDialogState extends State<_PaneStyleDialog> {
  late double _fontSize = widget.style.fontSize ?? defaultDanmuFontSize;
  late double _opacity = widget.style.opacity ?? defaultOverlayOpacity;
  late bool _useFontSize = widget.style.fontSize != null;
  late bool _useOpacity = widget.style.opacity != null;
  late int? _textColor = widget.style.textColor;

  PaneStyle _build() => PaneStyle(
        fontSize: _useFontSize ? _fontSize : null,
        opacity: _useOpacity ? _opacity : null,
        textColor: _textColor,
      );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('栏样式 · ${widget.roomId}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _toggleRow(
              label: _useFontSize
                  ? '字号　${_fontSize.toStringAsFixed(0)}'
                  : '字号　跟随全局',
              value: _useFontSize,
              onChanged: (bool value) => setState(() => _useFontSize = value),
            ),
            Slider(
              value: _fontSize,
              min: minDanmuFontSize,
              max: maxDanmuFontSize,
              divisions: (maxDanmuFontSize - minDanmuFontSize).round(),
              onChanged:
                  _useFontSize ? (double value) => setState(() => _fontSize = value) : null,
            ),
            _toggleRow(
              label: _useOpacity
                  ? '透明度　${_opacity.toStringAsFixed(2)}'
                  : '透明度　跟随全局',
              value: _useOpacity,
              onChanged: (bool value) => setState(() => _useOpacity = value),
            ),
            Slider(
              value: _opacity,
              min: minOverlayOpacity,
              max: maxOverlayOpacity,
              divisions: 12,
              onChanged:
                  _useOpacity ? (double value) => setState(() => _opacity = value) : null,
            ),
            const SizedBox(height: 8),
            const Text('正文字色'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                ChoiceChip(
                  label: const Text('默认'),
                  selected: _textColor == null,
                  onSelected: (_) => setState(() => _textColor = null),
                ),
                for (final ({String label, int value}) choice in _paneColorChoices)
                  ChoiceChip(
                    label: Text(choice.label),
                    selected: _textColor == choice.value,
                    onSelected: (_) => setState(() => _textColor = choice.value),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => setState(() {
            _useFontSize = false;
            _useOpacity = false;
            _textColor = null;
          }),
          child: const Text('恢复默认'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_build()),
          child: const Text('保存'),
        ),
      ],
    );
  }

  Widget _toggleRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      Row(
        children: <Widget>[
          Expanded(child: Text(label)),
          Switch(value: value, onChanged: onChanged),
        ],
      );
}
