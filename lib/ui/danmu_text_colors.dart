import 'package:danmu_float/app/live_danmu_session.dart';
import 'package:flutter/material.dart';

/// 主 App 的文字取色收敛点（UX-19）。
///
/// 为什么需要它：`danmu_page.dart` 里的次要文字长期写死 `Colors.black54` /
/// `Colors.grey`，而设置页明确提供「跟随系统 / 浅色 / 深色」——黑 54% 的文字铺在
/// 深色 `surfaceContainerHighest` 上等于看不见；浅色下 `Colors.grey` 对白底只有
/// 约 2.9:1，低于 WCAG AA 要求的 4.5:1。悬浮窗侧早有 `OverlayPalette` 按皮肤取色，
/// 主 App 一直没有对应收敛点，所以这里集中一份。
///
/// 约定：本文件返回的颜色必须对**对应主题的底色**达到 4.5:1 以上，由
/// `test/danmu_text_colors_test.dart` 用 `computeLuminance()` 直接算并钉住。
/// 取值参照 Material 3 的 `onSurfaceVariant`（浅 #49454F / 深 #CAC4D0）。

/// 次要文字：时间戳、弹幕引用原文、说明性文字。
Color secondaryTextColor(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFFCAC4D0)
    : const Color(0xFF49454F);

/// 进场横幅里的「欢迎」：它的底色是 `surfaceContainerHighest`（不是纯 surface），
/// 深色主题下必须提亮——旧版写死的 `Colors.black54` 在深底上等于看不见。
Color entryBannerWelcomeColor(Brightness brightness) =>
    brightness == Brightness.dark
    ? const Color(0xFFCAC4D0)
    : const Color(0xFF49454F);

/// 会话状态色（状态点与状态词共用）。
///
/// 状态词是**中文文本**，不能只靠旁边那个 10dp 的圆点传达，所以浅色主题下不能
/// 沿用 `Colors.green / orange / grey` 原色（对白底约 2.2~2.9:1），统一换成深色
/// 变体；深色主题下换成亮色变体。
Color stageTextColor(LiveSessionStage stage, Brightness brightness) {
  final bool dark = brightness == Brightness.dark;
  return switch (stage) {
    LiveSessionStage.live => dark
        ? const Color(0xFFA5D6A7)
        : const Color(0xFF1B5E20),
    LiveSessionStage.offline => dark
        ? const Color(0xFFFFCC80)
        : const Color(0xFFBF360C),
    LiveSessionStage.error => dark
        ? const Color(0xFFEF9A9A)
        : const Color(0xFFB71C1C),
    LiveSessionStage.idle => dark
        ? const Color(0xFFBDBDBD)
        : const Color(0xFF424242),
    _ => dark ? const Color(0xFF90CAF9) : const Color(0xFF0D47A1),
  };
}

/// 常驻提示条（悬浮窗权限被拒 / 主播列表损坏）的成对取色（#137）。
///
/// 返回记录而不是三个独立函数：底色与前景必须成对使用——分开写就容易重演旧问题
/// 「底色换了、文字仍继承 onSurface」，深色主题下浅字压浅底实测只有 1.13~1.18:1。
/// 浅色沿用原有底色（`orange.shade50` / `red.shade50`），只把前景压深到 ≥4.5:1；
/// 深色改成深底浅字，避免近白底直接压在深色界面上。
({Color background, Color foreground}) bannerColors({
  required Brightness brightness,
  required bool danger,
}) {
  if (brightness == Brightness.dark) {
    return danger
        ? (
            background: const Color(0xFF4A1C1C),
            foreground: const Color(0xFFFFDAD6),
          )
        : (
            background: const Color(0xFF4A2800),
            foreground: const Color(0xFFFFD5B0),
          );
  }
  return danger
      ? (
          background: const Color(0xFFFFEBEE),
          foreground: const Color(0xFFB71C1C),
        )
      : (
          background: const Color(0xFFFFF3E0),
          foreground: const Color(0xFFB33A00),
        );
}
