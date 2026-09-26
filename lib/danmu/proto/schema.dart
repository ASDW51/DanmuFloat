/// 字段类型。只覆盖弹幕链路实际用到的类型；未列出的字段一律跳过。
enum FieldKind { varint, boolean, string, bytes, message, fixed32, fixed64, float, double }

class FieldSpec {
  const FieldSpec(this.name, this.kind, {this.messageType, this.repeated = false});

  final String name;
  final FieldKind kind;

  /// kind 为 message 时的目标 schema 名（间接引用，避免定义顺序耦合）。
  final String? messageType;
  final bool repeated;
}

class MessageSchema {
  const MessageSchema(this.name, this.fields);

  final String name;

  /// 字段号 → 字段定义
  final Map<int, FieldSpec> fields;
}

/// 弹幕链路字段号表。
///
/// 来源：packages/DouYinDanma/src/dy.proto（`Webcast.Im.*` 嵌套结构）逐条摘录，
/// 字段名保留 proto 原始 snake_case，与 proto 文件一一对应便于后续核对。
/// 仅登记本链路需要的字段，其余字段由 wire 层按 wire type 跳过。
final Map<String, MessageSchema> imSchemas = <String, MessageSchema>{
  // 一帧 WS 二进制报文
  'PushFrame': const MessageSchema('PushFrame', {
    1: FieldSpec('SeqID', FieldKind.varint),
    2: FieldSpec('LogID', FieldKind.varint),
    3: FieldSpec('service', FieldKind.varint),
    4: FieldSpec('method', FieldKind.varint),
    5: FieldSpec('headers', FieldKind.message, messageType: 'PushHeader', repeated: true),
    6: FieldSpec('payload_encoding', FieldKind.string),
    7: FieldSpec('payload_type', FieldKind.string),
    8: FieldSpec('payload', FieldKind.bytes),
    9: FieldSpec('LodIDNew', FieldKind.string),
  }),
  'PushHeader': const MessageSchema('PushHeader', {
    1: FieldSpec('key', FieldKind.string),
    2: FieldSpec('value', FieldKind.string),
  }),

  // PushFrame.payload 解压后的负载
  'Response': const MessageSchema('Response', {
    1: FieldSpec('messages', FieldKind.message, messageType: 'ImMessage', repeated: true),
    2: FieldSpec('cursor', FieldKind.string),
    3: FieldSpec('fetch_interval', FieldKind.varint),
    4: FieldSpec('now', FieldKind.varint),
    5: FieldSpec('internal_ext', FieldKind.string),
    6: FieldSpec('fetch_type', FieldKind.varint),
    8: FieldSpec('heartbeat_duration', FieldKind.varint),
    9: FieldSpec('need_ack', FieldKind.boolean),
    10: FieldSpec('push_server', FieldKind.string),
    11: FieldSpec('live_cursor', FieldKind.string),
    12: FieldSpec('history_no_more', FieldKind.boolean),
  }),

  // Response.messages[] 的壳，payload 再按 method 二次解码
  'ImMessage': const MessageSchema('ImMessage', {
    1: FieldSpec('method', FieldKind.string),
    2: FieldSpec('payload', FieldKind.bytes),
    3: FieldSpec('msg_id', FieldKind.varint),
    4: FieldSpec('msg_type', FieldKind.varint),
    5: FieldSpec('offset', FieldKind.varint),
  }),

  'Common': const MessageSchema('Common', {
    1: FieldSpec('method', FieldKind.string),
    2: FieldSpec('msg_id', FieldKind.varint),
    3: FieldSpec('room_id', FieldKind.varint),
    4: FieldSpec('create_time', FieldKind.varint),
    6: FieldSpec('is_show_msg', FieldKind.boolean),
    7: FieldSpec('describe', FieldKind.string),
    11: FieldSpec('priority_score', FieldKind.varint),
    12: FieldSpec('log_id', FieldKind.string),
    15: FieldSpec('user', FieldKind.message, messageType: 'User'),
    21: FieldSpec('channel_id', FieldKind.varint),
    24: FieldSpec('app_id', FieldKind.varint),
  }),

  'User': const MessageSchema('User', {
    1: FieldSpec('id', FieldKind.varint),
    2: FieldSpec('short_id', FieldKind.varint),
    3: FieldSpec('nickname', FieldKind.string),
    4: FieldSpec('gender', FieldKind.varint),
    6: FieldSpec('level', FieldKind.varint),
    9: FieldSpec('avatar_thumb', FieldKind.message, messageType: 'Image'),
    21: FieldSpec('badge_image_list', FieldKind.message, messageType: 'Image', repeated: true),
    23: FieldSpec('pay_grade', FieldKind.message, messageType: 'PayGrade'),
    24: FieldSpec('fans_club', FieldKind.message, messageType: 'FansClub'),
    38: FieldSpec('display_id', FieldKind.string),
    46: FieldSpec('sec_uid', FieldKind.string),
    67: FieldSpec('web_rid', FieldKind.string),
    72: FieldSpec('consume_diamond_level', FieldKind.varint),
    1028: FieldSpec('id_str', FieldKind.string),
  }),

  'Image': const MessageSchema('Image', {
    1: FieldSpec('url_list', FieldKind.string, repeated: true),
    2: FieldSpec('uri', FieldKind.string),
    3: FieldSpec('height', FieldKind.varint),
    4: FieldSpec('width', FieldKind.varint),
    5: FieldSpec('avg_color', FieldKind.string),
    6: FieldSpec('image_type', FieldKind.varint),
    8: FieldSpec('content', FieldKind.message, messageType: 'ImageContent'),
    9: FieldSpec('is_animated', FieldKind.boolean),
  }),
  'ImageContent': const MessageSchema('ImageContent', {
    1: FieldSpec('name', FieldKind.string),
    2: FieldSpec('font_color', FieldKind.string),
    3: FieldSpec('level', FieldKind.varint),
    4: FieldSpec('alternative_text', FieldKind.string),
  }),

  // 荣誉等级：抖音弹幕昵称旁的「等级」即此处的 level，
  // 依据 data/messages/messages_WebcastChatMessage.json：payGrade.level=35，
  // 对应勋章 image_type=1 的「荣誉等级35级勋章」。
  'PayGrade': const MessageSchema('PayGrade', {
    6: FieldSpec('level', FieldKind.varint),
  }),

  // 粉丝团（灯牌）：level 与 user_fans_club_status 是灯牌展示的权威来源，
  // badge_image_list 仅部分消息带 image_type 7/51 的灯牌勋章，故仅作兜底。
  'FansClub': const MessageSchema('FansClub', {
    1: FieldSpec('data', FieldKind.message, messageType: 'FansClubData'),
  }),
  'FansClubData': const MessageSchema('FansClubData', {
    1: FieldSpec('club_name', FieldKind.string),
    2: FieldSpec('level', FieldKind.varint),
    3: FieldSpec('user_fans_club_status', FieldKind.varint),
  }),

  'ChatMessage': const MessageSchema('ChatMessage', {
    1: FieldSpec('common', FieldKind.message, messageType: 'Common'),
    2: FieldSpec('user', FieldKind.message, messageType: 'User'),
    3: FieldSpec('content', FieldKind.string),
    11: FieldSpec('agree_msg_id', FieldKind.varint),
    15: FieldSpec('event_time', FieldKind.varint),
  }),

  'MemberMessage': const MessageSchema('MemberMessage', {
    1: FieldSpec('common', FieldKind.message, messageType: 'Common'),
    2: FieldSpec('user', FieldKind.message, messageType: 'User'),
    3: FieldSpec('member_count', FieldKind.varint),
    8: FieldSpec('top_user_no', FieldKind.varint),
    10: FieldSpec('action', FieldKind.varint),
    11: FieldSpec('action_description', FieldKind.string),
    12: FieldSpec('user_id', FieldKind.varint),
  }),

  'GiftMessage': const MessageSchema('GiftMessage', {
    1: FieldSpec('common', FieldKind.message, messageType: 'Common'),
    2: FieldSpec('gift_id', FieldKind.varint),
    5: FieldSpec('repeat_count', FieldKind.varint),
    6: FieldSpec('combo_count', FieldKind.varint),
    7: FieldSpec('user', FieldKind.message, messageType: 'User'),
    8: FieldSpec('to_user', FieldKind.message, messageType: 'User'),
    9: FieldSpec('repeat_end', FieldKind.varint),
    15: FieldSpec('gift', FieldKind.message, messageType: 'GiftStruct'),
    29: FieldSpec('total_count', FieldKind.varint),
    33: FieldSpec('send_time', FieldKind.varint),
    44: FieldSpec('count', FieldKind.varint),
  }),
  'GiftStruct': const MessageSchema('GiftStruct', {
    1: FieldSpec('image', FieldKind.message, messageType: 'Image'),
    2: FieldSpec('describe', FieldKind.string),
    5: FieldSpec('id', FieldKind.varint),
    11: FieldSpec('type', FieldKind.varint),
    12: FieldSpec('diamond_count', FieldKind.varint),
    16: FieldSpec('name', FieldKind.string),
  }),

  'LikeMessage': const MessageSchema('LikeMessage', {
    1: FieldSpec('common', FieldKind.message, messageType: 'Common'),
    2: FieldSpec('count', FieldKind.varint),
    3: FieldSpec('total', FieldKind.varint),
    4: FieldSpec('color', FieldKind.varint),
    5: FieldSpec('user', FieldKind.message, messageType: 'User'),
    6: FieldSpec('icon', FieldKind.string),
  }),

  'SocialMessage': const MessageSchema('SocialMessage', {
    1: FieldSpec('common', FieldKind.message, messageType: 'Common'),
    2: FieldSpec('user', FieldKind.message, messageType: 'User'),
    3: FieldSpec('share_type', FieldKind.varint),
    4: FieldSpec('action', FieldKind.varint),
    5: FieldSpec('share_target', FieldKind.string),
    6: FieldSpec('follow_count', FieldKind.varint),
    8: FieldSpec('share_total_count', FieldKind.varint),
  }),

  'RoomUserSeqMessage': const MessageSchema('RoomUserSeqMessage', {
    1: FieldSpec('common', FieldKind.message, messageType: 'Common'),
    2: FieldSpec('ranks', FieldKind.message, messageType: 'Contributor', repeated: true),
    3: FieldSpec('total', FieldKind.varint),
    6: FieldSpec('popularity', FieldKind.varint),
    7: FieldSpec('total_user', FieldKind.varint),
    8: FieldSpec('total_user_str', FieldKind.string),
    9: FieldSpec('total_str', FieldKind.string),
    10: FieldSpec('online_user_for_anchor', FieldKind.string),
  }),
  'Contributor': const MessageSchema('Contributor', {
    1: FieldSpec('score', FieldKind.varint),
    2: FieldSpec('user', FieldKind.message, messageType: 'User'),
    3: FieldSpec('rank', FieldKind.varint),
    4: FieldSpec('delta', FieldKind.varint),
    5: FieldSpec('is_hidden', FieldKind.boolean),
  }),

  'RoomStatsMessage': const MessageSchema('RoomStatsMessage', {
    1: FieldSpec('common', FieldKind.message, messageType: 'Common'),
    2: FieldSpec('display_short', FieldKind.string),
    3: FieldSpec('display_middle', FieldKind.string),
    4: FieldSpec('display_long', FieldKind.string),
    5: FieldSpec('display_value', FieldKind.varint),
    7: FieldSpec('incremental', FieldKind.boolean),
    9: FieldSpec('total', FieldKind.varint),
    10: FieldSpec('display_type', FieldKind.varint),
  }),

  'RoomRankMessage': const MessageSchema('RoomRankMessage', {
    1: FieldSpec('common', FieldKind.message, messageType: 'Common'),
    2: FieldSpec('ranks', FieldKind.message, messageType: 'RoomRank', repeated: true),
  }),
  'RoomRank': const MessageSchema('RoomRank', {
    1: FieldSpec('user', FieldKind.message, messageType: 'User'),
    2: FieldSpec('score_str', FieldKind.string),
    3: FieldSpec('profile_hidden', FieldKind.boolean),
  }),

  'PrivilegeScreenChatMessage': const MessageSchema('PrivilegeScreenChatMessage', {
    1: FieldSpec('common', FieldKind.message, messageType: 'Common'),
    2: FieldSpec('user', FieldKind.message, messageType: 'User'),
    3: FieldSpec('content', FieldKind.string),
    5: FieldSpec('style', FieldKind.varint),
  }),

  'ScreenChatMessage': const MessageSchema('ScreenChatMessage', {
    1: FieldSpec('common', FieldKind.message, messageType: 'Common'),
    2: FieldSpec('user', FieldKind.message, messageType: 'User'),
    3: FieldSpec('screen_chat_type', FieldKind.varint),
    4: FieldSpec('content', FieldKind.string),
    5: FieldSpec('priority', FieldKind.varint),
    12: FieldSpec('event_time', FieldKind.varint),
  }),
};