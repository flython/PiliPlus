import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';

import 'package:PiliPlus/multi_window/storage_mirror.dart';
import 'package:PiliPlus/multi_window/window_env.dart';

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

  /// 在主引擎启动时调用一次：注册窗口关闭通知 + 存储镜像的对端方法。
  Future<void> init() async {
    final self = await WindowController.fromCurrentEngine();
    await self.setWindowMethodHandler((call) async {
      if (call.method == kWindowClosedMethod) _controller = null;
      return null;
    });
    await StorageMirror.attachMain(self);
  }

  /// 打开（或替换）播放窗口里的视频页。
  Future<void> open(Map arguments, {bool off = false}) =>
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
        return;
      } catch (_) {
        // 窗口可能刚被关掉：丢弃句柄重建
        _controller = null;
      }
    }

    final controller = await _ensureWindow();
    try {
      await _dispatch(
        controller,
        route,
        arguments,
        off: off,
        generation: _generation,
      );
    } catch (_) {
      _controller = null;
      await _destroyQuietly(controller);
      rethrow;
    }
    await controller.show();
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
    _controller = controller;
    if (generation != _generation) {
      // 建窗期间用户把窗口关了：别留下一个没人管的孤儿窗
      unawaited(_destroyQuietly(controller));
    }
    return controller;
  }

  /// 把消息送进播放窗口。新引擎首帧前调用会抛 MissingPluginException，
  /// 所以按 `DanmakuForwarder` 同款策略重试到成功为止。
  Future<void> _dispatch(
    WindowController controller,
    String route,
    dynamic arguments, {
    required bool off,
    required int generation,
  }) async {
    for (var i = 0; i < 40; i++) {
      if (generation != _generation) {
        throw StateError('播放窗口已关闭');
      }
      try {
        await controller.invokeMethod<void>(kOpenVideoMethod, {
          'route': route,
          'arguments': arguments,
          'off': off,
        });
        return;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }
    throw StateError('播放窗口启动超时');
  }

  /// 关闭播放窗口：先让播放引擎拆弹幕子窗口（`kTeardownMethod` 内部会做），
  /// 再关原生窗——引擎随之释放。
  Future<void> close() async {
    final controller = _controller;
    if (controller == null) return;
    _controller = null;
    _generation++;
    await _destroyQuietly(controller);
  }

  Future<void> _destroyQuietly(WindowController controller) async {
    try {
      await controller
          .invokeMethod<void>(kTeardownMethod)
          .timeout(const Duration(seconds: 2));
      await controller
          .invokeMethod<void>('close')
          .timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('关闭播放窗口失败: $e');
    }
  }
}
