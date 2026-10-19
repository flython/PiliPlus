import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

  /// 快照是否成功取到。见 [fetchSnapshot] 与 [throwIfSnapshotMissing]。
  static bool snapshotReady = false;

  // ---------- 主引擎侧 ----------

  /// 处理播放引擎发来的存储方法。
  ///
  /// 挂在主窗口自己的 method handler 上（见 `PlaybackWindow.init`）。
  /// 这里**不能**自己调 `setWindowMethodHandler`：desktop_multi_window 的
  /// `WindowChannel` 一个 channel 只存一个 handler，后注册的会把先注册的顶掉。
  static Future<dynamic> onMainCall(MethodCall call) async {
    switch (call.method) {
      case kStorageSnapshotMethod:
        return _encodeAll();
      case kStorageWriteMethod:
        final args = (call.arguments as Map).cast<String, dynamic>();
        await _applyWrite(args['box'] as String, args['bytes'] as Uint8List);
        return null;
      default:
        return null;
    }
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
    if (box == null) {
      debugPrint('[storageMirror] 收到未知箱 $name 的写转发，已丢弃');
      return;
    }
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
    // 取不到就是取不到，不能悄悄降级成「空镜像」。空镜像下
    // Accounts.refresh() 会把三个槽位都留成 AnonymousAccount
    // （accounts.dart:12-14），整个播放窗口变成未登录 + 全默认设置，
    // 而且快照只取一次、没有恢复路径 —— 用户看不出任何异常，只会觉得
    // 「播放窗口坏了」。宁可让这次点击失败回主窗口播放。
    snapshotReady = raw != null;
    if (!snapshotReady) {
      debugPrint('[storageMirror] 12s 内没能从主引擎取到存储快照，播放窗口将不可用');
    } else {
      _snapshot = raw!.map(
        (key, value) => MapEntry('$key', value as Uint8List),
      );
    }
    if (!(_fetchDone?.isCompleted ?? true)) _fetchDone?.complete();
  }

  static Completer<void>? _fetchDone;

  /// 快照取完之前，openVideo 要在这里等。
  ///
  /// 直接抛错会让主引擎把这次点击重试满预算（最长十几秒）才报「打不开」，
  /// 用户全程零反馈；而真正的原因只是快照还在路上（冷启动深链直开视频时，
  /// 主引擎自己还没跑到 `PlaybackWindow.init()`）。等它才是对的语义：
  /// 等不到才抛，那时主引擎的预算也快耗尽了。
  static Future<void> throwIfSnapshotMissing() async {
    if (snapshotReady) return;
    await _fetchDone?.future;
    if (snapshotReady) return;
    throw StateError('播放窗口拿不到主引擎的存储快照，本次回主窗口播放');
  }

  /// 建好内存箱并灌入快照。`GStorage.init()` 的播放分支调用。
  static void openBoxes() {
    _fetchDone = Completer<void>();
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
    if (main == null) {
      debugPrint('[storageMirror] 还没拿到主引擎句柄，丢弃 $box 的写');
      return;
    }
    // 还没被主引擎确认的写。刷新快照时要在灌回去，否则「刚写完立刻切窗口」
    // 会被新快照冲掉。
    final unconfirmed = _unconfirmed.putIfAbsent(box, () => {});
    unconfirmed[key] = value;
    _inFlight++;
    try {
      unawaited(
        main
            .invokeMethod<void>(kStorageWriteMethod, {
              'box': box,
              'bytes': encodeEntry(key, value),
            })
            .then((_) {
              // 只在值没被更新的情况下摘掉，避免连带撤掉更新的那一次写
              if (identical(unconfirmed[key], value)) unconfirmed.remove(key);
            })
            // 这一步失败 = 播放引擎的这一次写入彻底丢了（设置 / 观看进度 /
            // 登录态都在这条路上）。原来吞掉不记，用户下次启动会发现数据
            // 凭空消失，而日志里一行都没有 —— 排查成本最高的单点。
            .catchError(
              (Object e) => debugPrint('[storageMirror] 写 $box 失败: $e'),
            )
            .whenComplete(() => _inFlight--),
      );
    } catch (e) {
      _inFlight--;
      debugPrint('[storageMirror] 编码 $box 的写入失败: $e');
    }
  }

  static final Map<String, Map<dynamic, dynamic>> _unconfirmed = {};
  static int _inFlight = 0;

  /// 等在途的写回落到主引擎，最多等 [timeout]。
  ///
  /// 关窗必须过这道栅栏：`dispose()` 会写播放进度，紧接着就
  /// `invokeMethod('close')` 把原生窗关掉，那之后播放引擎的 engine 就没了，
  /// 没发出去的写全部作废 —— 用户看到的就是「关掉窗口后进度没记上」。
  static Future<void> settle({
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (_inFlight > 0 && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    if (_inFlight > 0) {
      debugPrint('[storageMirror] 还有 $_inFlight 次写没落到主引擎就关窗了');
    }
  }

  /// 从主引擎重拉一次快照，灌回内存箱。
  ///
  /// 镜像是启动那一刻取的，之后主引擎切账号 / 改设置 / 退出登录，
  /// 播放窗口全都看不见：点赞记到旧账号是最刺眼的一个。反向也坏 ——
  /// 过期快照上的 `MemoryBox.clear()` 会按本地键逐个转发 delete，
  /// 把主窗口已经删掉或改过的键再删一遍。
  ///
  /// 由播放窗口的 `WindowFocusedEvent` 触发（`WindowController.onWindowFocus`）。
  static Future<void> refresh() async {
    final main = _main;
    if (main == null || !snapshotReady) return;
    Map<dynamic, dynamic>? raw;
    for (var i = 0; i < 3; i++) {
      try {
        raw = await main.invokeMethod<Map<dynamic, dynamic>>(
          kStorageSnapshotMethod,
        );
        break;
      } catch (e) {
        debugPrint('[storageMirror] 补拉快照失败($i): $e');
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    if (raw == null) return;
    for (final entry in _unconfirmed.entries) {
      raw.putIfAbsent(entry.key, () => entry.value);
    }
    _snapshot = raw.map((key, value) => MapEntry('$key', value as Uint8List));
    for (final entry in _snapshot.entries) {
      _fill(entry.key, entry.value);
    }
    // accountMode 是另一个纯内存副本，刷新箱不够，得让 Accounts 自己再算一遍
    unawaited(Accounts.refresh());
  }
}
