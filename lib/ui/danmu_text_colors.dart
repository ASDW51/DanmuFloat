import 'package:danmu_float/app/overlay_bridge.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/ui/overlay_theme.dart';
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

/// 弹幕行 / 主播行的语义色（#138）。
///
/// 为什么放在这里：UX-19 已把本文件定为主 App 文字色的唯一口径，而弹幕行此前
/// 直接写死 Material 色板——浅色下 4 处、深色下 6 处跌破 4.5:1，同一类弹幕在
/// 窗内与 App 内还是两个色系。这里按 Brightness 成对取值，由
/// `test/danmu_semantic_colors_test.dart` 对真实底色用 computeLuminance() 钉住。

/// 7 类类型前缀色：**直接复用**悬浮窗已下沉的 `OverlayTheme` 角色表（#138）。
///
/// 不在这里维护第二份 switch：主 App 深色主题取 `dark` 预设、浅色主题取 `light`
/// 预设，与窗内完全同源（`sepia` / 对比度修正的取值也一并跟着走）。
Color danmuTypeColor(DanmakuKind kind, Brightness brightness) {
  final OverlayTheme theme = OverlayTheme.preset(
    brightness == Brightness.dark
        ? overlayStyleDarkThemeId
        : overlayStyleLightThemeId,
  );
  return switch (kind) {
    DanmakuKind.screenChat => theme.typeScreenChat,
    DanmakuKind.privilegeScreenChat => theme.typePrivilegeScreenChat,
    DanmakuKind.gift => theme.typeGift,
    DanmakuKind.member => theme.typeMember,
    DanmakuKind.like => theme.typeLike,
    DanmakuKind.social => theme.typeSocial,
    DanmakuKind.roomRank => theme.typeRoomRank,
    // 其余类型本来就不显示前缀（danmakuTypeLabel 返回 null），走到这里只是兜底。
    _ => secondaryTextColor(brightness),
  };
}

/// 昵称（加粗显示）：浅色下 `indigo.shade400` 对白底 4.86:1 勉强及格、深色下
/// 只有 3.82:1，所以两套都重新取。
Color nicknameColor(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFFB4A7FF)
    : const Color(0xFF3949AB);

/// 等级 `Lv.N`：原来两处都写死 `orange.shade800`（白底 3.08:1）。
Color levelTextColor(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFFFFB74D)
    : const Color(0xFFB33A00);

/// 粉丝灯牌 `灯牌N`：`purple.shade400` 深色下只有 3.86:1。
Color fanBadgeColor(Brightness brightness) => brightness == Brightness.dark
    ? const Color(0xFFE0B3FF)
    : const Color(0xFF7B1FA2);

/// 首页行内的「凭证：xxx」：`Colors.orange` 对白底只有 2.16:1。
Color credentialTextColor(Brightness brightness) =>
    brightness == Brightness.dark ? const Color(0xFFFFB68C) : const Color(0xFFB33A00);

/// 首页开播头像的底色与前景（白字是文字，按 4.5:1 要求）。
///
/// 深浅两套共用同一组底色：这两个底色本身就是深色，白字在浅色 / 深色主题下
/// 分别有 5.1:1 与 5.0:1，无需再分叉。`living == null` 是「未知」，按离线处理。
Color roomAvatarBackgroundColor({required bool? living}) =>
    living == true ? const Color(0xFF2E7D32) : const Color(0xFF757575);

/// 头像里的首字：两组底色都够深，白字恒达标。
Color roomAvatarForegroundColor() => Colors.white;
