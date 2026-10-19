import 'dart:async';
import 'dart:typed_data';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:hive_ce/hive.dart';

import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/hive_codec.dart';
import 'package:PiliPlus/utils/memory_box.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/models/user/info.dart';

/// 播放引擎 → 主引擎
const kStorageSnapshotMethod = 'storageSnapshot';
const kStorageWriteMethod = 'storageWrite';

/// 一个箱文件只能有一个 owner。
///
/// hive_ce 自己就写着（`src/hive_impl.dart:56-58`）：多 isolate 必须用
/// IsolatedHive，否则 DATA CORRUPTION；IsolatedHive 又全是 Future，跟本项目
/// 全同步的 `Box` API 冲突（实测故障见 `.scratch/playback-separate-window/storage-isolation.md`）。
/// 所以定成：主引擎是唯一 owner，播放引擎拿内存镜像，启动时灌一次快照，
/// 之后每次写立刻转给主引擎落盘。
///
/// 编解码见 `lib/utils/hive_codec.dart`。
abstract final class StorageMirror {
  static Map<String, Uint8List> _snapshot = const {};

  static WindowController? _main;

  // ---------- 主引擎侧 ----------

  /// 主引擎：注册「给快照」和「代写」两个方法。
  static Future<void> attachMain(WindowController self) async {
    await self.setWindowMethodHandler((call) async {
      switch (call.method) {
        case kStorageSnapshotMethod:
          return _encodeAll();
        case kStorageWriteMethod:
          final args = (call.arguments as Map).cast<String, dynamic>();
          await _applyWrite(
            args['box'] as String,
            args['bytes'] as Uint8List,
          );
          return null;
        default:
          return null;
      }
    });
  }

  static Map<String, Uint8List> _encodeAll() {
    final reply = GStorage.reply;
    final boxes = <String, Box>{
      'userInfo': GStorage.userInfo,
      'localCache': GStorage.localCache,
      'setting': GStorage.setting,
      'historyWord': GStorage.historyWord,
      'video': GStorage.video,
      'account': Accounts.account,
      'watchProgress': GStorage.watchProgress,
      'reply': ?reply,
    };
    return boxes.map((name, box) => MapEntry(name, encodeBox(box.toMap())));
  }

  static Future<void> _applyWrite(String name, Uint8List bytes) async {
    final box = _findBox(name);
    if (box == null) return;
    final entry = decodeEntry(bytes);
    final value = entry[1];
    if (value == null) {
      await box.delete(entry[0]);
    } else {
      await box.put(entry[0], value);
    }
  }

  static Box? _findBox(String name) => switch (name) {
    'userInfo' => GStorage.userInfo,
    'localCache' => GStorage.localCache,
    'setting' => GStorage.setting,
    'historyWord' => GStorage.historyWord,
    'video' => GStorage.video,
    'account' => Accounts.account,
    'watchProgress' => GStorage.watchProgress,
    'reply' => GStorage.reply,
    _ => null,
  };

  // ---------- 播放引擎侧 ----------

  /// 必须在 `GStorage.init()` 之前 await：`Pref.saveReply` 决定开不开 reply 箱，
  /// 而它自己就在 setting 箱里。
  ///
  /// 主引擎可能还没跑完 `PlaybackWindow.init()`（冷启动深链直开视频就是这种情况），
  /// 所以按 `PlaybackWindow._dispatch` 同款策略重试到成功为止。
  static Future<void> fetchSnapshot(WindowController main) async {
    _main = main;
    Map<dynamic, dynamic>? raw;
    for (var i = 0; i < 40; i++) {
      try {
        raw = await main.invokeMethod<Map<dynamic, dynamic>>(
          kStorageSnapshotMethod,
        );
        break;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
    _snapshot = raw == null
        ? const {}
        : raw.map((key, value) => MapEntry('$key', value as Uint8List));
  }

  /// 建好内存箱并灌入快照。`GStorage.init()` 的播放分支调用。
  static void openBoxes() {
    GStorage.userInfo = MemoryBox<UserInfoData>('userInfo', onWrite: _pushTo);
    GStorage.localCache = MemoryBox<dynamic>('localCache', onWrite: _pushTo);
    GStorage.setting = MemoryBox<dynamic>('setting', onWrite: _pushTo);
    GStorage.historyWord = MemoryBox<dynamic>('historyWord', onWrite: _pushTo);
    GStorage.video = MemoryBox<dynamic>('video', onWrite: _pushTo);
    Accounts.account = MemoryBox<LoginAccount>('account', onWrite: _pushTo);
    GStorage.watchProgress = MemoryBox<int>('watchProgress', onWrite: _pushTo);

    // reply 留到最后：Pref.saveReply 本身就在 setting 箱里，
    // setting 没灌进去之前读到的是默认值，会把「存回复」关掉的用户又打开。
    for (final entry in _snapshot.entries) {
      if (entry.key == 'reply') continue;
      _fill(entry.key, entry.value);
    }

    final reply = MemoryBox<Uint8List>('reply', onWrite: _pushTo);
    GStorage.reply = Pref.saveReply ? reply : null;
    final replyBytes = _snapshot['reply'];
    if (replyBytes != null) reply.applySnapshot(decodeBox(replyBytes));
  }

  static void _fill(String name, Uint8List bytes) {
    final map = decodeBox(bytes);
    switch (name) {
      case 'userInfo':
        (GStorage.userInfo as MemoryBox<UserInfoData>).applySnapshot(map);
      case 'localCache':
        (GStorage.localCache as MemoryBox<dynamic>).applySnapshot(map);
      case 'setting':
        (GStorage.setting as MemoryBox<dynamic>).applySnapshot(map);
      case 'historyWord':
        (GStorage.historyWord as MemoryBox<dynamic>).applySnapshot(map);
      case 'video':
        (GStorage.video as MemoryBox<dynamic>).applySnapshot(map);
      case 'account':
        (Accounts.account as MemoryBox<LoginAccount>).applySnapshot(map);
      case 'watchProgress':
        (GStorage.watchProgress as MemoryBox<int>).applySnapshot(map);
      case 'reply':
        final reply = GStorage.reply;
        if (reply != null) (reply as MemoryBox<Uint8List>).applySnapshot(map);
    }
  }

  static void _pushTo(String box, dynamic key, Object? value) {
    final main = _main;
    if (main == null) return;
    unawaited(
      main
          .invokeMethod<void>(kStorageWriteMethod, {
            'box': box,
            'bytes': encodeEntry(key, value),
          })
          .catchError((_) {}),
    );
  }
}
