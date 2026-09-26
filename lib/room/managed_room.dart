// 主播（房间）列表项：用户添加后持久化到本地（design.md 2.3 的 rooms[]）。
//
// 除 webRid 与备注外，额外缓存最近一次「刷新」拿到的主播名 / 标题 / 开播状态，
// 这样冷启动读本地列表时行内就有可读信息，而不是只显示一串直播间号。
class ManagedRoom {
  const ManagedRoom({
    required this.webRid,
    this.name = '',
    this.owner = '',
    this.title = '',
    this.living,
    required this.addedAt,
  });

  /// 主播标识，同时作为列表唯一键。
  ///
  /// 通常是由链接解析出的 webRid（纯数字）；解析不出来时保留用户原始输入，
  /// 不在这里断定为非法——连接阶段会给出失败原因。
  final String webRid;

  /// 用户填写的备注，可空。
  final String name;

  /// 最近一次刷新得到的主播昵称。
  final String owner;

  /// 最近一次刷新得到的直播标题。
  final String title;

  /// 最近一次刷新的开播状态；null 表示尚未刷新过。
  final bool? living;

  /// 添加时间（epoch 秒）。
  final int addedAt;

  /// 行内主标题：备注优先，其次主播名，最后退回直播间号。
  String get displayName =>
      name.isNotEmpty ? name : (owner.isNotEmpty ? owner : webRid);

  ManagedRoom copyWith({
    String? name,
    String? owner,
    String? title,
    bool? living,
  }) =>
      ManagedRoom(
        webRid: webRid,
        name: name ?? this.name,
        owner: owner ?? this.owner,
        title: title ?? this.title,
        living: living ?? this.living,
        addedAt: addedAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'room_id': webRid,
        'room_name': name,
        'owner': owner,
        'title': title,
        if (living != null) 'living': living,
        'added_at': addedAt,
      };

  /// 解析单条记录；缺少 room_id 时返回 null（按坏数据跳过）。
  static ManagedRoom? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final Object? webRid = raw['room_id'];
    if (webRid is! String || webRid.trim().isEmpty) return null;
    final Object? living = raw['living'];
    return ManagedRoom(
      webRid: webRid.trim(),
      name: _asString(raw['room_name']),
      owner: _asString(raw['owner']),
      title: _asString(raw['title']),
      living: living is bool ? living : null,
      addedAt: _asInt(raw['added_at']),
    );
  }

  static String _asString(Object? value) => value is String ? value : '';

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  @override
  String toString() =>
      'ManagedRoom(webRid: $webRid, name: $name, owner: $owner, living: $living)';
}