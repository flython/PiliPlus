import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import 'package:PiliPlus/pages/playback/view.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/multi_window/danmaku_forwarder.dart';
import 'package:PiliPlus/multi_window/playback_args.dart';
import 'package:PiliPlus/multi_window/playback_window.dart';
import 'package:PiliPlus/multi_window/storage_mirror.dart';
import 'package:PiliPlus/utils/page_utils.dart';

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

  /// app 首帧之后才放行 openVideo。
  ///
  /// 必须在注册 window handler **之前**建好，否则 `:init` 还没跑到
  /// `_appReady = Completer()` 时到达的请求会看到 null。
  Completer<void>? _appReady;

  /// 关窗有两条入口（Dart 的 closeWindow 与原生标题栏的 windowClosing），
  /// 用它挡掉重复的播放器拆除。
  bool _closing = false;

  /// 播放器/弹幕子窗口是否已经拆过。见 [_stopEverything]。
  bool _stopped = false;

  /// 是否已经成功打开过至少一个页面。见 [PlaybackRouteObserver]。
  bool _openedOnce = false;

  bool get openedOnce => _openedOnce;

  /// 路由栈深度变化时自增。播放窗口的悬浮返回按钮靠它决定要不要亮着
  /// （见 `PlaybackBackButton`）—— 没有可观察对象，Navigator 不会通知外面。
  static final ValueNotifier<int> routeTick = ValueNotifier(0);

  /// 自己的 windowId。关窗通知要带上它：主引擎可能已经拆过一轮窗口，
  /// 不带 id 的话旧窗口那条迟到的通知会误伤新窗口的句柄。
  static String? _selfWindowId;

  /// 在 `main.dart` 的子窗口分流处调用。
  ///
  /// [mainWindowId] 来自 `WindowConfiguration.arguments`，由主引擎建窗时写入。
  /// 返回后 `main()` 继续走完整 bootstrap，但 `WindowEnv.kind` 已经是 playback。
  Future<void> init(String mainWindowId, String windowType) async {
    _appReady = Completer<void>();
    final self = await WindowController.fromCurrentEngine();
    _selfWindowId = self.windowId;
    _main = WindowController.fromWindowId(mainWindowId);
    await self.setWindowMethodHandler(_handleWindowMethod);

    const channel = MethodChannel('PiliPlus/subwindow');
    channel.setMethodCallHandler(_handleNativeMethod);
    await channel.invokeMethod<void>('setupWindow', {'type': windowType});
    // 播放引擎跑 bootstrap 期间需要 path_provider / window_manager / media_kit，
    // 它们在子 engine 里默认没注册
    await channel.invokeMethod<void>('enablePlugins');

    await StorageMirror.fetchSnapshot(_main!);
  }

  /// 播放页渲染完成后调用（`PlaybackRootPage.initState`）。
  void markAppReady() {
    final ready = _appReady;
    if (ready != null && !ready.isCompleted) ready.complete();
  }

  Future<dynamic> _handleWindowMethod(MethodCall call) async {
    switch (call.method) {
      case kOpenVideoMethod:
        final args = (call.arguments as Map).cast<String, dynamic>();
        // 快照没拿到就别开：播放窗口会带着空镜像跑起来（未登录 +
        // 全默认设置），而恢复路径不存在。抛出去让 page_utils 提示用户。
        await StorageMirror.throwIfSnapshotMissing();
        final request = _OpenRequest(
          args['route'] as String,
          decodePlaybackArguments(args['arguments'] as Map?),
          args['off'] as bool? ?? false,
        );
        // 必须等首帧才回包：窗口是 hiddenAtLaunch 建的，主引擎拿到应答就
        // show()。不等的话用户会看到一个没标题、没控件的白窗。
        await _appReady?.future;
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
      // 先通知主引擎，再拆东西，顺序不能反。
      //
      // `willClose` 一过 NSWindow 随即销毁，engine 跟着掉；之后任何 `await`
      // 的续体都不保证还能跑。原先把通知放在 `_stopEverything()` 后面，而
      // `_stopEverything()` 里要 `await StorageMirror.settle()`（最长 800ms）
      // —— 真机上就复现了：窗口关掉后 `dispose player` 打出来了，主引擎却
      // 一直攥着已死的 windowId，之后点任何视频都是
      // `failed to find target window`，用户表现为「关掉之后就再也点不开了」。
      try {
        await _main?.invokeMethod<void>(kWindowClosedMethod, _selfWindowId);
      } catch (e) {
        debugPrint('通知主引擎 windowClosed 失败: $e');
      }
      await _stopEverything();
    }
  }

  Future<void> _openVideo(_OpenRequest request) async {
    // 原生标题栏留空的话，Cmd-Tab 里几个播放窗口没法区分，用户也看不出
    // 眼前这个窗口在放什么。setTitle 是本地通道，往返很快，放在导航之前
    // 让 show() 出来的窗口就是带标题的。
    final title = request.arguments is Map
        ? (request.arguments as Map)['title'] as String?
        : null;
    if (title != null && title.isNotEmpty) {
      try {
        await const MethodChannel(
          'PiliPlus/subwindow',
        ).invokeMethod<void>('setTitle', {'title': title});
      } catch (e) {
        debugPrint('设置播放窗口标题失败: $e');
      }
    }

    // 窗口内再点同一个播放页 = 原地替换，不叠第二层
    //
    // 这里**不能 await**。GetX 的 toNamed/offNamed 返回的是被推路由的
    // *pop* future（getx lib/get_navigation/src/extension_navigation.dart:120
    // /:157 就是 pushNamed / pushReplacementNamed 的返回值），只有那一页被
    // 弹出时才 complete。而 kOpenVideoMethod 是请求-应答式 RPC，主引擎在
    // await 它来决定何时 show() 窗口 —— await 导航等于让 show() 永远等不到，
    // 窗口（hiddenAtLaunch 建的）就一次都不会显示。
    _openedOnce = true;
    if (request.off) {
      unawaited(
        Get.offNamed(
          request.route,
          arguments: request.arguments,
          preventDuplicates: false,
        ),
      );
    } else {
      // 复用 PageUtils 的规则：栈顶已经是媒体页就替换，否则压一层。
      // 主窗口跨窗派发过来的也走这条，否则从 UP 页进来点视频会顶掉 UP 页。
      PageUtils.toPlaybackMediaNamed(request.route, request.arguments);
    }
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
    try {
      await _main?.invokeMethod<void>(kWindowClosedMethod, _selfWindowId);
    } catch (e) {
      debugPrint('通知主引擎 windowClosed 失败: $e');
    }
  }

  /// 关闭前把播放引擎独占的东西全部释放，否则 mpv 会继续出声。
  ///
  /// 关窗有三条入口（主引擎的 teardown、closeWindow、原生标题栏的
  /// windowClosing），用 [_stopped] 挡掉重复拆除。
  Future<void> _stopEverything() async {
    if (_stopped) return;
    _stopped = true;
    await DanmakuForwarder.i.teardown();
    // 这里要的是「全部停掉」而不是「减一次计数」：
    // updatePlayCount() 在 _playerCount > 1 时只做 -= 1，既不 dispose 也不
    // 上报心跳（controller.dart:1711-1717）。播放窗口里叠过直播页/音频页时
    // 计数会 > 1，只减计数会让底下那个视频的播放器留在原地不出声，
    // 用户下次打开同一个视频看到的服务端进度是旧的。
    PlPlayerController.instance?.dispose();
    // dispose 会写播放进度。这些写是 fire-and-forget 的转发，下一步就是
    // 关原生窗、engine 随之销毁 —— 不等它们落地，用户看到的就是
    // 「关掉播放窗口后进度没记上」。
    await StorageMirror.settle();
  }
}

/// 视频页是栈顶、下面只剩哨兵页（或栈空）时返回 = 关掉整个播放窗口。
class PlaybackRouteObserver extends NavigatorObserver {
  @override
  void didPop(Route route, Route? previousRoute) {
    // `_openedOnce` 挡掉程序自己把哨兵页 off 掉的那一次：那走的是
    // pushReplacement → didReplace，本来就不会到这里，纯属兜底。
    //
    // 哨兵页是 initialRoute、永远在栈底，所以栈底的名字判据成立；
    // `previousRoute == null` 那支留作防御（GetX 的 offNamed 走
    // pushReplacementNamed，只替换栈顶，不会把栈清空）。
    if (PlaybackBridge.i.openedOnce &&
        (previousRoute == null ||
            previousRoute.settings.name == PlaybackRootPage.routeName)) {
      unawaited(PlaybackBridge.i.closeWindow());
    }
    _tick();
  }

  @override
  void didPush(Route route, Route? previousRoute) => _tick();

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) => _tick();

  void _tick() => PlaybackBridge.routeTick.value++;
}

class _OpenRequest {
  const _OpenRequest(this.route, this.arguments, this.off);

  final String route;
  final dynamic arguments;
  final bool off;
}
