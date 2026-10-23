import 'dart:async';
import 'dart:math' show min;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';

import 'package:PiliPlus/multi_window/playback_args.dart';
import 'package:PiliPlus/multi_window/storage_mirror.dart';
import 'package:PiliPlus/multi_window/window_env.dart';
import 'package:PiliPlus/utils/storage_pref.dart';

/// 主引擎 → 播放引擎
const kOpenVideoMethod = 'openVideo';
const kTeardownMethod = 'teardown';

/// 播放引擎 → 主引擎
const kWindowClosedMethod = 'windowClosed';

/// 播放窗口在**主引擎**侧的控制端。
///
/// 职责：建窗 / 复用单例 / 派发「打开某个页面」/ 关窗前让播放引擎拆掉弹幕子窗口。
class PlaybackWindow {
  PlaybackWindow._();

  static final PlaybackWindow i = PlaybackWindow._();

  WindowController? _controller;

  /// 正在建窗，避免连点视频开出两个窗口。
  Future<WindowController>? _pending;

  /// 每次关窗自增，用于中断正在重试的派发。
  int _generation = 0;

  bool get isOpen => _controller != null;

  /// 主引擎决定「这个视频要不要送播放窗口」的判据。
  ///
  /// 关键是 `|| isOpen` 那一半：只要播放窗口还开着，视频就**必须**继续走它，
  /// 不管开关是什么状态。一个进程只能有一个 media_kit `Player`（事件循环
  /// 端口是 C 侧的进程级 static），主引擎这时自己再建一个，正在播的窗口就
  /// 变成无声 + 进度条不动 + 一行日志都没有。
  ///
  /// 少了这一半会出现一个很难查的场景：用户在**播放窗口里**把开关关掉
  /// （页头部那个开关，两个窗口都渲染），播放窗口照常播放，关窗逻辑却在
  /// 播放引擎里是空操作，而开关的写会立刻经 `_applyWrite` 落到主引擎的真实
  /// Hive —— 于是主引擎从此开始建第二个 `Player`。
  ///
  /// 开关关掉后想收回播放窗口，去主窗口「设置 → 桌面」拨，那里才会调
  /// [onSeparateWindowChanged] 真正关窗。
  bool get useSeparateWindow => Pref.playbackSeparateWindow || isOpen;

  /// 在主引擎启动时调用一次：注册窗口关闭通知 + 存储镜像的对端方法。
  ///
  /// 两个 handler 必须合并成一次 `setWindowMethodHandler`：
  /// desktop_multi_window 的 `WindowChannel` 每个 channel 只存一个 handler，
  /// 后注册的会把先注册的顶掉。
  Future<void> init() async {
    final self = await WindowController.fromCurrentEngine();
    await self.setWindowMethodHandler((call) {
      if (call.method == kWindowClosedMethod) {
        // 带 windowId 是必须的：窗口被拆过一轮之后（比如派发失败重建），
        // 旧窗口的 willClose 通知会迟到。没有 id 就只能无条件清句柄，
        // 那条迟到通知会把新窗口的句柄一起清掉，于是再点视频又开第三个窗。
        //
        // 注意：`self` 是主引擎自己的 windowId，不是子窗口的。这里要跟
        // **当前正在用的**子窗口句柄比，不是跟主窗口比。上一个版本写成
        // `self.windowId` 是错的主键比对，永远匹配不上，句柄清不掉，
        // 用户表现为「关掉一次就再也点不开」。
        if (call.arguments == _controller?.windowId || call.arguments == null) {
          _controller = null;
          // 同 [close]：用户点红点走的就是这条通路，必须一样自增 generation，
          // 否则正在重试的派发会对着已销毁的窗口空转满 12 秒，然后被
          // page_utils 当成「开不了窗」回退到主窗口再开一次。
          _generation++;
        }
      }
      return StorageMirror.onMainCall(call);
    });
  }

  /// 打开（或替换）播放窗口里的视频页。
  /// 视频页的 arguments 是 `Map`。直播页走 [openRoute] 传裸 `int roomId`
  /// （见 `PageUtils.toLiveRoom`），所以不能把这里收窄成 `Map`。
  Future<void> open(dynamic arguments, {bool off = false}) =>
      openRoute('/videoV', arguments, off: off);

  /// 让播放窗口跳到 [route]。主窗口的所有播放入口都收敛到这里。
  ///
  /// 抛异常代表「播放窗口没能打开这个页面」，调用方负责回退到主窗口内打开。
  Future<void> openRoute(
    String route,
    dynamic arguments, {
    bool off = false,
  }) async {
    final existing = _controller;
    if (existing != null) {
      try {
        await _dispatch(
          existing,
          route,
          arguments,
          off: off,
          generation: _generation,
        );
        await _showSafely(existing);
        return;
      } on _WindowClosed {
        // 用户自己把窗口关了：本来就该停在这儿，不回退、不报错
        return;
      } catch (e) {
        debugPrint('播放窗口句柄已失效($e)，拆掉重建');
        // 复用失败绝大多数只有一个原因：这个窗口已经没了。
        //
        // 消息是播放引擎临死前发的，engine 一掉就发不出去，所以主引擎攥着的
        // 句柄经常是个死窗口（真机复现：关掉播放窗口后连点 8 次视频，每次都是
        // `failed to find target window`，而整轮日志里只建过 1 个窗口）。
        //
        // 这里不能像新建路径那样 rethrow：用户点视频的心愿是「能看到这个视频」，
        // 他没要求任何窗口的存活。拆掉旧的接着往下走新建流程，比弹一个
        // 「播放窗口打不开」然后什么都不发生要像样得多。
        if (identical(_controller, existing)) {
          _controller = null;
          _generation++;
        }
        await _destroyQuietly(existing);
      }
    }

    late final WindowController controller;
    try {
      controller = await _ensureWindow();
    } on _WindowClosed {
      return;
    }
    try {
      await _dispatch(
        controller,
        route,
        arguments,
        off: off,
        generation: _generation,
      );
    } on _WindowClosed {
      return;
    } catch (_) {
      _controller = null;
      await _destroyQuietly(controller);
      rethrow;
    }
    await _showSafely(controller);
  }

  /// 已经存在的播放窗口同样要置前 + 聚焦。播放窗口是另一个 NSWindow，
  /// 不 orderFront 它就停在原层序 —— 用户在主窗口点第二个视频时
  /// 主窗口纹丝不动，看起来像没点上。
  ///
  /// 放前面失败会抛 `WindowChannelException(CHANNEL_UNREGISTERED)`
  /// （窗口在这中间被用户关掉了）。派发已经成功，不该因此报「打不开」。
  Future<void> _showSafely(WindowController controller) async {
    try {
      await controller.show();
    } catch (e) {
      debugPrint('显示播放窗口失败: $e');
    }
  }

  /// 建窗时先 `hiddenAtLaunch`，等页面真的派发进去了再显示 ——
  /// 否则 `desktop_multi_window` 会先在屏幕左下角 orderFront 一个 800x600 的空窗。
  Future<WindowController> _ensureWindow() {
    final generation = _generation;
    return _pending ??= _createWindow(generation).whenComplete(() {
      _pending = null;
    });
  }

  Future<WindowController> _createWindow(int generation) async {
    final self = await WindowController.fromCurrentEngine();
    final controller = await WindowController.create(
      WindowConfiguration(
        arguments: buildPlaybackWindowArgs(self.windowId),
        hiddenAtLaunch: true,
      ),
    );
    if (generation != _generation) {
      // 建窗途中用户把窗口关了：把它销毁掉，而且**不能**把这个将死的
      // 句柄返回给调用方 —— 调用方会拿它空转满 40 次重试才放弃。
      unawaited(_destroyQuietly(controller));
      throw const _WindowClosed();
    }
    _controller = controller;
    return controller;
  }

  /// 把消息送进播放窗口。新引擎首帧前调用会抛 MissingPluginException，
  /// 所以按 `DanmakuForwarder` 同款策略重试到成功为止。
  ///
  /// 每次 `invokeMethod` 都要自带 `.timeout`：它是对端 `await handler.call()`
  /// 的往返，对端卡住不回（比如 `_appReady` 那次 post-frame 没跑到）时，
  /// future 永远不会 complete，`Future.delayed` 只在 catch 分支里，
  /// 「20 次 × 200ms」这个上界对「不回复」根本不成立 —— 主窗口会被永久
  /// 挂死，连 `.catchError` 的 toast 都出不来，之后每次点视频重复挂死。
  Future<void> _dispatch(
    WindowController controller,
    String route,
    dynamic arguments, {
    required bool off,
    required int generation,
  }) async {
    // 卡**总**预算，不是「次数 × 单次上界」。对端正常回包是毫秒级的，
    // 次数只在它快速报错时才有意义（子 engine 的 method channel 是建窗后
    // 才注册的，头几次必然 CHANNEL_UNREGISTERED）；而对端不回包时，
    // 单次 5s 的 timeout 会把 20 次重试放大成 ≈100s 的「点了没反应」。
    final budget = Stopwatch()..start();
    Object? last;
    while (true) {
      if (generation != _generation) {
        throw const _WindowClosed();
      }
      final remaining =
          _kDispatchBudget.inMilliseconds - budget.elapsedMilliseconds;
      if (remaining <= 0) {
        debugPrint('播放窗口派发超时: $last');
        throw StateError('播放窗口启动超时');
      }
      try {
        await controller
            .invokeMethod<void>(
              kOpenVideoMethod,
              {
                'route': route,
                'arguments': encodePlaybackArguments(arguments),
                'off': off,
              },
            )
            .timeout(
              Duration(
                milliseconds: min(
                  remaining,
                  _kCallTimeout.inMilliseconds,
                ),
              ),
            );
        return;
      } catch (e) {
        last = e;
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  /// 「播放页独立窗口」开关被拨动时的收尾（设置页与播放页头部共用）。
  ///
  /// 关掉开关时必须把已经开着的播放窗口收掉。留着它的话主窗口会自己开视频页、
  /// 自己建 `Player`（`PageUtils.toVideoPage` 的分流条件是
  /// 「开关开着**或者**播放窗口已经开着」，见 `page_utils.dart`），
  /// 两个 engine 抢 media_kit 那个进程级事件循环端口，正在播的窗口表现是
  /// 无声 + 进度条不动 + 一行日志都没有。
  static void onSeparateWindowChanged(bool value) {
    if (!value) unawaited(i.close());
  }

  /// 关闭播放窗口：先让播放引擎拆弹幕子窗口（`kTeardownMethod` 内部会做），
  /// 再关原生窗——引擎随之释放。
  Future<void> close() async {
    final controller = _controller;
    _controller = null;
    // 无条件自增：窗口经常是被用户/播放引擎先关掉的，那时 `_controller`
    // 已经是 null 而 `_generation` 没动，正在重试的派发就断不了。
    _generation++;
    if (controller == null) return;
    await _destroyQuietly(controller);
  }

  Future<void> _destroyQuietly(WindowController controller) async {
    try {
      await controller
          .invokeMethod<void>(kTeardownMethod)
          .timeout(_kCloseTimeout);
    } catch (e) {
      debugPrint('播放窗口收尾失败: $e');
    }
    // 收尾失败也**必须**把原生窗关掉。放在一起顺序 await 的话，
    // teardown 超时会让 close 永远不执行：mpv 继续出声，而主引擎已经
    // 把句柄置空了，下一次点视频会开出第二个播放窗口。
    try {
      await controller.invokeMethod<void>('close').timeout(_kCloseTimeout);
    } catch (e) {
      debugPrint('关闭播放窗口失败: $e');
    }
  }

  static const _kCloseTimeout = Duration(seconds: 2);

  /// 派发重试的**总**预算。子 engine 的 method channel 是建窗之后才注册的，
  /// 头几次必然 CHANNEL_UNREGISTERED，所以要重试；对端一旦就位就回包，耗时
  /// 是毫秒级的。剩下的等待（存储快照、首帧）都在播放引擎内部 await。
  /// 用户在这段时间里既没有 spinner 也没有任何提示，拖得越久越像是点了没反应。
  static const _kDispatchBudget = Duration(seconds: 10);

  /// 单次派发往返的上限。对端要等 `markAppReady()`（首帧 post-frame）才回包，
  /// 冷启动深链时可能超过两秒；再久就当它卡死了，重试下一轮。
  /// 真正封顶的是 [_kDispatchBudget]，不是「次数 × 这个」。
  static const _kCallTimeout = Duration(seconds: 3);
}

/// 播放窗口在派发途中被关掉了 —— 用户点红点，或播放引擎自己退了。
///
/// 跟「打不开这个页面」是两回事：用户是主动关的，回退到主窗口再弹一个
/// 视频页违背意图，所以 [PlaybackWindow.openRoute] 会把它就地吃掉。
class _WindowClosed implements Exception {
  const _WindowClosed();

  @override
  String toString() => '播放窗口已关闭';
}
