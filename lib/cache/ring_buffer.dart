import 'dart:collection';

/// 每栏独立的环形缓冲区（design.md 第 8 章）：只保留最近 [capacity] 条，
/// 超出自动丢弃最旧一条；数据仅在内存中，App 关闭即清空。
class RingBuffer<T> {
  RingBuffer(this.capacity) : assert(capacity > 0);

  final int capacity;
  final ListQueue<T> _items = ListQueue<T>();

  int get length => _items.length;

  bool get isEmpty => _items.isEmpty;

  void add(T item) {
    _items.addLast(item);
    while (_items.length > capacity) {
      _items.removeFirst();
    }
  }

  /// 按写入先后返回快照（旧 → 新）。
  List<T> toList() => List<T>.unmodifiable(_items);

  void clear() => _items.clear();
}