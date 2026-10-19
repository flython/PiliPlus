import 'dart:typed_data';

import 'package:hive_ce/hive.dart';
// hive_ce 的 barrel 没有导出这两个实现类，而 `IsolatedBox` 全是 Future、
// 用不了本项目全同步的 `Box` API，只能直接引 src 实现。
// ignore: implementation_imports
import 'package:hive_ce/src/binary/binary_reader_impl.dart';
// ignore: implementation_imports
import 'package:hive_ce/src/binary/binary_writer_impl.dart';

/// Hive 箱内容的二进制编解码。
///
/// 播放窗口是第二个 engine，共享不了箱文件（见
/// `.scratch/playback-separate-window/storage-isolation.md`），所以走
/// 「主引擎编码 → 字节 → 播放引擎解码」这条路。用 hive_ce 自己的二进制实现，
/// 两端各自跑 `GStorage.regAdapter()`，adapter 注册顺序一致 ⇒ typeId 一致。
///
/// 单独成文件是为了让它只依赖 hive_ce：单元测试直接 import 本文件，
/// 不会被 `GStorage` 那一串 widget 依赖链拖住。
///
/// `BinaryWriterImpl` / `BinaryReaderImpl` 没有被 hive_ce 的 barrel 导出，
/// 所以只能引 src（项目 `lib/hive.dart` 已有同样先例）。

/// 整箱编码。hive_ce 的 `write` 按 typeId 递归处理 adapter，
/// 对象值不需要额外处理。
Uint8List encodeBox(Map<dynamic, dynamic> map) =>
    (BinaryWriterImpl(Hive)..write(map)).toBytes();

Map<dynamic, dynamic> decodeBox(Uint8List bytes) =>
    BinaryReaderImpl(bytes, Hive).read() as Map<dynamic, dynamic>;

/// 单条变更编码成 `[key, value]`；value 为 null 表示删除。
Uint8List encodeEntry(dynamic key, Object? value) =>
    (BinaryWriterImpl(Hive)..write([key, value])).toBytes();

List<dynamic> decodeEntry(Uint8List bytes) =>
    BinaryReaderImpl(bytes, Hive).read() as List<dynamic>;
