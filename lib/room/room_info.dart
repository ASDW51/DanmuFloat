// 房间信息模型。字段口径见 design.md 11.8 / 11.9。

/// 房间信息接口类型（本期仅实现 web，其余按 11.8 预留）。
enum RoomInfoApi { web, webHtml, mobile, userHtml }

class RoomInfoException implements Exception {
  RoomInfoException(this.message);

  final String message;

  @override
  String toString() => 'RoomInfoException: $message';
}

class RoomInfo {
  const RoomInfo({
    required this.living,
    required this.isLiveRadio,
    required this.webRid,
    required this.liveId,
    required this.owner,
    required this.title,
    required this.avatar,
    required this.cover,
    required this.secUid,
    required this.api,
  });

  /// 未开播（含 status_code=30003「直播已结束」）时的空结果。
  const RoomInfo.offline({
    required this.webRid,
    required this.api,
  })  : living = false,
        isLiveRadio = false,
        liveId = '',
        owner = '',
        title = '',
        avatar = '',
        cover = '',
        secUid = '';

  /// 是否在播。
  final bool living;

  /// 是否为直播电台（web 接口 room_status == 1）。
  final bool isLiveRadio;

  /// 用户输入的直播间号（URL 中的 webRid）。
  final String webRid;

  /// 弹幕连接所需的 liveId（room.id_str）；未开播为空串。
  final String liveId;

  /// 主播昵称。
  final String owner;

  final String title;
  final String avatar;
  final String cover;
  final String secUid;
  final RoomInfoApi api;

  @override
  String toString() =>
      'RoomInfo(api: ${api.name}, webRid: $webRid, liveId: $liveId, living: $living, '
      'isLiveRadio: $isLiveRadio, owner: $owner, title: $title)';
}