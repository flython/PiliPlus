import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import 'package:PiliPlus/pages/playback/view.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/multi_window/danmaku_forwarder.dart';
import 'package:PiliPlus/multi_window/playback_window.dart';
import 'package:PiliPlus/multi_window/storage_mirror.dart';

/// 播放窗口在**播放引擎**侧的对端。
///
/// 播放窗口跑的是完整 app（完整 GetX 路由表 + 完整插件 + 完整网络栈），
/// 只有三件事和主窗口不一样：
///   1. Hive 换成内存镜像（见 `storage_mirror.dart`）
///   2. initialRoute 是哨兵页 `/playback`，不渲染底部 Tab
///   3. 播放器只存在于这里，主窗口永不建 `Player`
class PlaybackBridge {
  PlaybackBridge._();

  static final PlaybackBridge i = PlaybackBridge._();

  WindowController? _main;

  /// app 首帧之前收到的 openVideo 先排队。
  Completer<void>? _appReady;
  final List<_OpenRequest> _pending = [];

  /// 关窗有两条入口（Dart 的 closeWindow 与原生标题栏的 windowClosing），
  /// 用它挡掉重复的播放器拆除。
  bool _closing = false;

  /// 播放器/弹幕子窗口是否已经拆过。见 [_stopEverything]。
  bool _stopped = false;

  /// 是否已经成功打开过至少一个页面。见 [PlaybackRouteObserver]。
  bool _openedOnce = false;

  bool get openedOnce => _openedOnce;

  /// 在 `main.dart` 的子窗口分流处调用。
  ///
  /// [mainWindowId] 来自 `WindowConfiguration.arguments`，由主引擎建窗时写入。
  /// 返回后 `main()` 继续走完整 bootstrap，但 `WindowEnv.kind` 已经是 playback。
  Future<void> init(String mainWindowId, String windowType) async {
    final self = await WindowController.fromCurrentEngine();
    _main = WindowController.fromWindowId(mainWindowId);
    await self.setWindowMethodHandler(_handleWindowMethod);

    const channel = MethodChannel('PiliPlus/subwindow');
    channel.setMethodCallHandler(_handleNativeMethod);
    await channel.invokeMethod<void>('setupWindow', {'type': windowType});
    // 播放引擎跑 bootstrap 期间需要 path_provider / window_manager / media_kit，
    // 它们在子 engine 里默认没注册
    await channel.invokeMethod<void>('enablePlugins');

    await StorageMirror.fetchSnapshot(_main!);

    _appReady = Completer<void>();
    unawaited(_drainWhenReady());
  }

  /// 播放页渲染完成后调用（`PlaybackRootPage.initState`）。
  void markAppReady() {
    final ready = _appReady;
    if (ready != null && !ready.isCompleted) ready.complete();
  }

  Future<void> _drainWhenReady() async {
    final ready = _appReady;
    if (ready == null) return;
    await ready.future;
    if (_pending.isEmpty) return;
    final queued = List.of(_pending);
    _pending.clear();
    for (final request in queued) {
      await _openVideo(request);
    }
  }

  Future<dynamic> _handleWindowMethod(MethodCall call) async {
    switch (call.method) {
      case kOpenVideoMethod:
        final args = (call.arguments as Map).cast<String, dynamic>();
        final request = _OpenRequest(
          args['route'] as String,
          args['arguments'],
          args['off'] as bool? ?? false,
        );
        final ready = _appReady;
        if (ready == null || !ready.isCompleted) {
          _pending.add(request);
          return null;
        }
        await _openVideo(request);
      case kTeardownMethod:
        await _stopEverything();
      case 'close':
        await closeWindow();
      default:
        throw MissingPluginException('播放窗口没有 ${call.method} 方法');
    }
  }

  Future<void> _handleNativeMethod(MethodCall call) async {
    if (call.method == 'windowClosing' && !_closing) {
      // 原生标题栏被关掉：通知主引擎丢弃句柄，并保证播放器已经停
      await _stopEverything();
      await _main?.invokeMethod<void>(kWindowClosedMethod);
    }
  }

  Future<void> _openVideo(_OpenRequest request) async {
    // 窗口内再点同一个播放页 = 原地替换，不叠第二层
    if (request.off || Get.currentRoute == request.route) {
      await Get.offNamed(
        request.route,
        arguments: request.arguments,
        preventDuplicates: false,
      );
    } else {
      await Get.toNamed(
        request.route,
        arguments: request.arguments,
        preventDuplicates: false,
      );
    }
    // 必须放在跳转完成之后：第一次 open 本身就是把哨兵页 off 掉，
    // 那一次 didPop 不是「用户按了返回」。
    _openedOnce = true;
  }

  /// 关闭播放窗口：拆弹幕子窗口 → 停播放器 → 关原生窗口 → 通知主引擎。
  Future<void> closeWindow() async {
    if (_closing) return;
    _closing = true;
    await _stopEverything();
    try {
      await const MethodChannel('PiliPlus/subwindow')
          .invokeMethod<void>('close');
    } catch (e) {
      debugPrint('关闭播放窗口失败: $e');
    }
    await _main?.invokeMethod<void>(kWindowClosedMethod);
  }

  /// 关闭前把播放引擎独占的东西全部释放，否则 mpv 会继续出声。
  ///
  /// 关窗有三条入口（主引擎的 teardown、closeWindow、原生标题栏的
  /// windowClosing），用 [_stopped] 挡掉重复拆除。
  Future<void> _stopEverything() async {
    if (_stopped) return;
    _stopped = true;
    await DanmakuForwarder.i.teardown();
    PlPlayerController.updatePlayCount();
  }
}

/// 视频页是栈顶、下面只剩哨兵页时返回 = 关掉整个播放窗口。
class PlaybackRouteObserver extends NavigatorObserver {
  @override
  void didPop(Route route, Route? previousRoute) {
    // `_openedOnce` 挡掉第一次 open：那时是程序把哨兵页 off 掉换成视频页，
    // didPop 的 previousRoute 同样是哨兵页，但那时用户还没按过返回。
    if (PlaybackBridge.i.openedOnce &&
        previousRoute?.settings.name == PlaybackRootPage.routeName) {
      unawaited(PlaybackBridge.i.closeWindow());
    }
  }
}

class _OpenRequest {
  const _OpenRequest(this.route, this.arguments, this.off);

  final String route;
  final dynamic arguments;
  final bool off;
}
