import 'dart:typed_data';

import 'package:danmu_float/danmu/proto/im_decoder.dart';
import 'package:danmu_float/danmu/proto/schema.dart';

/// 归一化后的弹幕事件类型（design.md 11.7 显式覆盖的 10 类 + 其它）。
enum DanmakuKind {
  chat,
  gift,
  member,
  like,
  social,
  roomUserSeq,
  roomStats,
  roomRank,
  privilegeScreenChat,
  screenChat,
  other,
}

class DanmakuUser {
  const DanmakuUser({
    required this.userId,
    required this.nickName,
    required this.avatarUrl,
    required this.level,
    required this.fanLevel,
  });

  static const DanmakuUser empty = DanmakuUser(
    userId: '',
    nickName: '',
    avatarUrl: '',
    level: 0,
    fanLevel: 0,
  );

  final String userId;
  final String nickName;
  final String avatarUrl;

  /// 荣誉等级（user.pay_grade.level），即抖音弹幕昵称旁展示的等级。
  ///
  /// 不能用 user.level（字段 6）：抓包样本中该用户 user.level=1，
  /// 而 pay_grade.level=35 且勋章文案为「荣誉等级35级勋章」。
  final int level;

  /// 粉丝团（灯牌）等级，0 表示未加入粉丝团
  final int fanLevel;
}

class DanmakuEvent {
  const DanmakuEvent({
    required this.kind,
    required this.method,
    required this.msgId,
    required this.roomId,
    required this.timeMs,
    required this.text,
    required this.user,
    this.count = 0,
    this.total = 0,
    this.amount = 0,
  });

  final DanmakuKind kind;

  /// 原始 method，未显式覆盖的类型用于调试与埋点归类
  final String method;

  /// 去重键：优先 common.msg_id，缺失时退化为壳层 msg_id，均为 0 时不参与去重
  final int msgId;
  final int roomId;

  /// 事件时间，统一毫秒（源字段为秒）
  final int timeMs;

  /// 展示文本
  final String text;
  final DanmakuUser user;

  /// 礼物数量 / 本次点赞数
  final int count;

  /// 累计点赞数 / 在线人数
  final int total;

  /// 礼物钻石价值
  final int amount;

  /// 是否适合在弹幕列表里展示。
  ///
  /// 未登记 method 会落到 [DanmakuKind.other]，其 [text] 是 method 名占位
  /// （真实抓包里约 38 种 method，本链路只覆盖 prd 第 125 行列出的类型），
  /// 只用于埋点归类，不应出现在展示列表里。
  bool get isDisplayable => kind != DanmakuKind.other;

  /// 在线观众数，只取「xxx在线观众」房间统计消息（`WebcastRoomStatsMessage`）。
  ///
  /// 抓包：`displayLong="1927在线观众"`，`display_value` / `total` 均为 1927，
  /// 与抖音客户端口径一致且推送及时。
  /// 房间用户序列（`WebcastRoomUserSeqMessage`）虽也带在线人数，但更新滞后
  /// （表现为右上角「慢一拍」），故不再作为在线人数来源。
  int get onlineCount {
    if (kind != DanmakuKind.roomStats) return 0;
    // 只在文案确实是「在线观众」时取值，避免把点赞数等其它统计当成在线人数。
    if (!text.contains('在线观众')) return 0;
    if (total > 0) return total;
    // 兜底：从「1927在线观众」文案里取数字
    final match = RegExp(r'\d+').firstMatch(text);
    return match == null ? 0 : (int.tryParse(match.group(0)!) ?? 0);
  }
}

/// 时间戳统一为毫秒：源字段 source 为秒，按 1e11 阈值区分秒与毫秒。
int toMillis(int value) {
  if (value <= 0) return 0;
  return value < 100000000000 ? value * 1000 : value;
}

/// 按 method 二次解码并归一化为弹幕事件。
///
/// method 去掉 `Webcast` 前缀即为 proto 消息名；未登记 schema 的类型不报错，
/// 原样透传为 [DanmakuKind.other]（design.md 第 5 章兜底规则）。
DanmakuEvent? buildDanmakuEvent({
  required String method,
  required Uint8List payload,
  required int envelopeMsgId,
}) {
  final schemaName = method.startsWith('Webcast') ? method.substring(7) : method;
  if (!imSchemas.containsKey(schemaName)) {
    return DanmakuEvent(
      kind: DanmakuKind.other,
      method: method,
      msgId: envelopeMsgId,
      roomId: 0,
      timeMs: 0,
      text: method,
      user: DanmakuUser.empty,
    );
  }

  final Map<String, Object?> body;
  try {
    body = decodeSchema(payload, schemaName);
  } on Object {
    return null;
  }

  final common = asMessage(body['common']);
  final roomId = asInt(common?['room_id']);
  final msgId = asInt(common?['msg_id']);
  final user = toDanmakuUser(asMessage(body['user']) ?? asMessage(common?['user']));
  final timeMs = toMillis(_firstPositive(
    asInt(body['event_time']),
    asInt(common?['create_time']),
  ));

  final kind = _kindOf(method);
  // text 为空表示该类型本次没有可展示内容（如不含 display_* 的房间统计），
  // 由流水线静默跳过，不计入解析失败。
  final text = _composeText(method, body, user);

  return DanmakuEvent(
    kind: kind,
    method: method,
    msgId: msgId != 0 ? msgId : envelopeMsgId,
    roomId: roomId,
    timeMs: timeMs,
    text: text,
    user: user,
    count: _countOf(method, body),
    total: _totalOf(method, body),
    amount: asInt(asMessage(body['gift'])?['diamond_count']),
  );
}

DanmakuKind _kindOf(String method) => switch (method) {
      'WebcastChatMessage' => DanmakuKind.chat,
      'WebcastGiftMessage' => DanmakuKind.gift,
      'WebcastMemberMessage' => DanmakuKind.member,
      'WebcastLikeMessage' => DanmakuKind.like,
      'WebcastSocialMessage' => DanmakuKind.social,
      'WebcastRoomUserSeqMessage' => DanmakuKind.roomUserSeq,
      'WebcastRoomStatsMessage' => DanmakuKind.roomStats,
      'WebcastRoomRankMessage' => DanmakuKind.roomRank,
      'WebcastPrivilegeScreenChatMessage' => DanmakuKind.privilegeScreenChat,
      'WebcastScreenChatMessage' => DanmakuKind.screenChat,
      _ => DanmakuKind.other,
    };

String _composeText(String method, Map<String, Object?> body, DanmakuUser user) {
  switch (method) {
    case 'WebcastChatMessage':
    case 'WebcastPrivilegeScreenChatMessage':
    case 'WebcastScreenChatMessage':
      return asString(body['content']);
    case 'WebcastGiftMessage':
      final gift = asMessage(body['gift']);
      final name = asString(gift?['name']);
      if (name.isEmpty) return '';
      final count = _countOf(method, body);
      return count > 1 ? '$name ×$count' : name;
    case 'WebcastMemberMessage':
      final description = asString(body['action_description']);
      return description.isNotEmpty ? description : '进入直播间';
    case 'WebcastLikeMessage':
      final count = asInt(body['count']);
      return count > 0 ? '点赞 ×$count' : '点赞';
    case 'WebcastSocialMessage':
      return asInt(body['action']) == 1 ? '关注了主播' : '分享了直播间';
    case 'WebcastRoomUserSeqMessage':
      // total/total_str 是在线人数；total_user/total_user_str 是累计观看人次（抓包为「3万+」）。
      final totalStr = asString(body['total_str']);
      if (totalStr.isNotEmpty) return '在线 $totalStr';
      final total = asInt(body['total']);
      return total > 0 ? '在线 $total' : '';
    case 'WebcastRoomStatsMessage':
      for (final key in const ['display_long', 'display_middle', 'display_short']) {
        final value = asString(body[key]);
        if (value.isNotEmpty) return value;
      }
      return '';
    case 'WebcastRoomRankMessage':
      return '榜单更新';
  }
  // 兜底：未显式处理但已在 schema 中登记的类型，用 method 名占位
  return method;
}

int _countOf(String method, Map<String, Object?> body) {
  switch (method) {
    case 'WebcastGiftMessage':
      for (final key in const ['repeat_count', 'combo_count', 'count', 'total_count']) {
        final value = asInt(body[key]);
        if (value > 0) return value;
      }
      return 1;
    case 'WebcastLikeMessage':
      return asInt(body['count']);
  }
  return 0;
}

int _totalOf(String method, Map<String, Object?> body) {
  switch (method) {
    case 'WebcastLikeMessage':
      return asInt(body['total']);
    case 'WebcastRoomUserSeqMessage':
      // total 为在线人数（抓包 1971，与 online_user_for_anchor 一致）；
      // total_user 为累计观看人次（抓包 39408 / 「3万+」），不能用于在线人数展示。
      return asInt(body['total']);
    case 'WebcastRoomStatsMessage':
      // display_value 是展示文案对应的数值（display_type=1 时即「在线观众」数，抓包 1927）
      final displayValue = asInt(body['display_value']);
      return displayValue > 0 ? displayValue : asInt(body['total']);
  }
  return 0;
}

/// 粉丝团勋章 image_type：7 为常规样式，51 为其 xmp 变体。
/// 依据：data/messages/messages_WebcastChatMessage.json 中两类勋章的 content.level 一致（均为 16），
/// 而 image_type 1 的勋章是「荣誉等级」而非粉丝团等级，故不能取首个带 level 的勋章。
const Set<int> _fansClubBadgeTypes = {7, 51};

/// 从 user.badge_image_list 提取粉丝团（灯牌）等级。
///
/// 仅作兜底：进场等消息的 badge_image_list 只带荣誉等级勋章（image_type=1），
/// 不含灯牌勋章，此时取值为 0。
int extractFanLevel(Object? badgeImageList) {
  if (badgeImageList is! List) return 0;
  for (final badge in badgeImageList) {
    final map = asMessage(badge);
    if (map == null) continue;
    if (!_fansClubBadgeTypes.contains(asInt(map['image_type']))) continue;
    final level = asInt(asMessage(map['content'])?['level']);
    if (level > 0) return level;
  }
  return 0;
}

/// 从 user.fans_club.data.level 提取灯牌等级（灯牌的权威来源，各类型消息都带）。
int extractFansClubLevel(Object? fansClub) =>
    asInt(asMessage(asMessage(fansClub)?['data'])?['level']);

/// 从 user.pay_grade.level 提取荣誉等级（弹幕昵称旁展示的等级）。
int extractHonorLevel(Object? payGrade) =>
    asInt(asMessage(payGrade)?['level']);

DanmakuUser toDanmakuUser(Map<String, Object?>? user) {
  if (user == null) return DanmakuUser.empty;
  final id = asInt(user['id']);
  final fansClubLevel = extractFansClubLevel(user['fans_club']);
  return DanmakuUser(
    userId: id != 0 ? '$id' : asString(user['id_str']),
    nickName: asString(user['nickname']),
    avatarUrl: firstImageUrl(user['avatar_thumb']),
    level: extractHonorLevel(user['pay_grade']),
    fanLevel:
        fansClubLevel > 0 ? fansClubLevel : extractFanLevel(user['badge_image_list']),
  );
}

int _firstPositive(int a, int b) => a > 0 ? a : b;