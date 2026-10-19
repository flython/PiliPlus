import 'dart:async';

import 'package:hive_ce/hive.dart';

/// 写入回调：把一次「key → value」变更交给上层转发到权威引擎。
/// 参数依次是箱名、key、value（value 为 null 表示删除）。
typedef BoxWriteCallback<E> = void Function(
  String box,
  dynamic key,
  E? value,
);

/// 不落盘的 [Box]。
///
/// 播放引擎不能用 Hive 打开同一个 box 文件：hive_ce 自己在
/// `src/hive_impl.dart:56-58` 就会打「多个 isolate 必须用 IsolatedHive，否则
/// DATA CORRUPTION」的告警，而 IsolatedHive 全 async，与本项目全同步的
/// `Box` API 不兼容（实测三种故障见 `.scratch/playback-separate-window/storage-isolation.md`）。
///
/// 所以播放引擎持有内存 box：启动时由主引擎灌一份快照，之后每次写都
/// 通过 [onWrite] 转发给主引擎落盘。读在本引擎、写由权威引擎负责。
class MemoryBox<E> implements Box<E> {
  MemoryBox(this.name, {this.onWrite});

  @override
  final String name;

  final BoxWriteCallback<E>? onWrite;

  final Map<dynamic, E> _map = {};

  final _watch = StreamController<BoxEvent>.broadcast();

  int _autoIncrement = 0;

  @override
  bool get isOpen => true;

  @override
  String? get path => null;

  @override
  bool get lazy => false;

  @override
  Iterable<dynamic> get keys => _map.keys.toList(growable: false);

  @override
  int get length => _map.length;

  @override
  bool get isEmpty => _map.isEmpty;

  @override
  bool get isNotEmpty => _map.isNotEmpty;

  @override
  Iterable<E> get values => _map.values.toList(growable: false);

  @override
  dynamic keyAt(int index) => keys.elementAt(index);

  @override
  E? getAt(int index) => _map.values.elementAt(index);

  @override
  E? get(dynamic key, {E? defaultValue}) => _map[key] ?? defaultValue;

  @override
  Map<dynamic, E> toMap() => Map.of(_map);

  @override
  Iterable<E> valuesBetween({dynamic startKey, dynamic endKey}) => _map.entries
      .where((e) => startKey == null || _compare(e.key, startKey) >= 0)
      .where((e) => endKey == null || _compare(e.key, endKey) <= 0)
      .map((e) => e.value);

  @override
  Stream<BoxEvent> watch({dynamic key}) => key == null
      ? _watch.stream
      : _watch.stream.where((e) => e.key == key);

  @override
  bool containsKey(dynamic key) => _map.containsKey(key);

  @override
  Future<void> put(dynamic key, E value) async {
    _map[key] = value;
    _watch.add(BoxEvent(key, value, false));
    onWrite?.call(name, key, value);
  }

  @override
  Future<void> putAll(Map<dynamic, E> entries) async {
    for (final entry in entries.entries) {
      await put(entry.key, entry.value);
    }
  }

  @override
  Future<int> add(E value) async {
    final key = _autoIncrement++;
    await put(key, value);
    return key;
  }

  @override
  Future<Iterable<int>> addAll(Iterable<E> values) async {
    final keys = <int>[];
    for (final value in values) {
      keys.add(await add(value));
    }
    return keys;
  }

  @override
  Future<void> delete(dynamic key) async {
    _map.remove(key);
    _watch.add(BoxEvent(key, null, true));
    onWrite?.call(name, key, null);
  }

  @override
  Future<void> deleteAll(Iterable<dynamic> keys) async {
    for (final key in keys.toList()) {
      await delete(key);
    }
  }

  @override
  Future<void> putAt(int index, E value) => put(keyAt(index), value);

  @override
  Future<void> deleteAt(int index) => delete(keyAt(index));

  @override
  Future<void> compact() async {}

  @override
  Future<int> clear() async {
    final deleted = _map.keys.toList(growable: false);
    _map.clear();
    for (final key in deleted) {
      _watch.add(BoxEvent(key, null, true));
      // 必须逐条转发：只清本地镜像的话，主引擎的盘上数据还在，
      // 下次启动快照一灌，用户就看到「清空过的搜索历史」又回来了。
      onWrite?.call(name, key, null);
    }
    return deleted.length;
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    await _watch.close();
  }

  @override
  Future<void> deleteFromDisk() async {
    await clear();
  }

  /// Hive 的 `watchProgress` / `reply` 用字符串降序比较器；
  /// 内存 box 没有比较器概念，这里退回自然序即可（只影响 `valuesBetween`）。
  static int _compare(dynamic a, dynamic b) => a.toString().compareTo(b.toString());

  /// 灌入主引擎下发的快照（不走 [onWrite]，避免回环）。
  ///
  /// hive 二进制解码出来是 `Map<dynamic, dynamic>`，这里逐条 cast 回 [E]。
  void applySnapshot(Map<dynamic, dynamic> entries) {
    _map
      ..clear()
      ..addAll(entries.map((key, value) => MapEntry(key, value as E)));
    // 灌进来的箱里已经有 0..N 这些数字键（historyWord / video 就是这么存的），
    // 不接着排下去的话 [add] 会从 0 开始，直接盖掉已有条目。
    _autoIncrement = _map.keys
        .whereType<int>()
        .fold<int>(0, (max, key) => key >= max ? key + 1 : max);
  }
}
