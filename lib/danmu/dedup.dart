/// 以 msgId 为键的有界去重器（design.md 第 5 章：以 common.msgId 作为唯一键）。
///
/// 采用插入序淘汰：容量耗尽时丢弃最早一条，避免长时间运行内存无界增长。
/// msgId 为 0 表示该条消息没有可用的唯一键，不参与去重。
class MsgIdDeduplicator {
  MsgIdDeduplicator({this.capacity = 4096}) : assert(capacity > 0);

  final int capacity;
  final Set<int> _seen = <int>{};

  int get length => _seen.length;

  /// 返回 true 表示该 msgId 已出现过，调用方应丢弃这条消息。
  bool isDuplicate(int msgId) {
    if (msgId == 0) return false;
    if (_seen.contains(msgId)) return true;
    _seen.add(msgId);
    while (_seen.length > capacity) {
      _seen.remove(_seen.first);
    }
    return false;
  }

  void clear() => _seen.clear();
}