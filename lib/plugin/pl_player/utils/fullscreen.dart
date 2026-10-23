import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/multi_window/window_env.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/desktop/window_controller.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart'
    show SystemChrome, SystemUiOverlay, DeviceOrientation, MethodChannel;

bool _isDesktopFullScreen = false;

void enterDesktopFullScreen({bool inAppFullScreen = false}) {
  if (WindowEnv.isPlayback) {
    // 播放窗口的左键全屏 = 系统全屏（独占 Space）；
    // 右键的「应用内全屏」= 窗口铺满本屏，两者要能区分开
    _setPlaybackFullScreen(true, inApp: inAppFullScreen);
    return;
  }
  if (!inAppFullScreen && !_isDesktopFullScreen) {
    WindowController.instance.window?.isFullScreen = _isDesktopFullScreen =
        true;
  }
}

/// [inAppFullScreen] 必须跟进入时一致：原生侧按它分两种模式，而两种模式的
/// 退出判据不同（系统全屏比 styleMask，铺屏比 restoreFrame）。少了这个参数
/// 就只能永远发 inApp:false，铺屏态下原生比对 styleMask 恒 false == false
/// 命中早退，窗口停在铺满状态退不回来。
void exitDesktopFullScreen({bool inAppFullScreen = false}) {
  if (_isDesktopFullScreen) {
    WindowController.instance.window?.isFullScreen = _isDesktopFullScreen =
        false;
  }
  _setPlaybackFullScreen(false, inApp: inAppFullScreen);
}

// ---------------------------------------------------------------------------
// 播放窗口的全屏：交给原生侧走 NSWindow.toggleFullScreen:
//
// 不能从 Dart 调，因为 nativeapi 0.5.2 的事件派发是同步的
// （cnativeapi/src/platform/macos/window_manager_macos.mm:652
//   DispatchWindowEvent → Emit → listener->Invoke）。
// AppKit 改窗口状态会同步发通知，通知在 Dart 还没从 FFI 调用返回时就回跳进
// Dart 回调，Dart VM 断言 "Cannot invoke native callback from a leaf call."
// （runtime_entry.cc:5233）然后 abort——点全屏整个进程消失，没有 Dart 异常，
// Catcher 也接不到。从 method channel 发起时 Dart 栈已经退干净，不会命中。
//
// 所以切换全屏放在 macos/Runner/MainFlutterWindow.swift 的 PlaybackFullScreen。
// 进退全屏由原生发 fullScreenChanged 事件回来，Dart 侧在这里跟着改状态。
// ---------------------------------------------------------------------------

const _subWindowChannel = MethodChannel('PiliPlus/subwindow');

// 原生侧的播放窗口全屏状态。不能从 Dart 读，因为读也要发通道。
// 系统全屏和应用内铺屏是两种状态，分别记。
bool _isPlaybackFullScreen = false;
bool _isPlaybackInAppFullScreen = false;

void _setPlaybackFullScreen(bool enter, {bool inApp = false}) {
  if (enter) {
    if (inApp ? _isPlaybackInAppFullScreen : _isPlaybackFullScreen) return;
    _isPlaybackInAppFullScreen = inApp;
    _isPlaybackFullScreen = !inApp;
  } else {
    if (!_isPlaybackFullScreen && !_isPlaybackInAppFullScreen) return;
    _isPlaybackFullScreen = false;
    _isPlaybackInAppFullScreen = false;
  }
  _subWindowChannel
      .invokeMethod<void>(
        'togglePlaybackFullScreen',
        {'enter': enter, 'inApp': inApp},
      )
      .timeout(const Duration(seconds: 2))
      .catchError((Object e) {
        debugPrint('播放窗口全屏切换失败: $e');
      });
}

/// 原生侧的全屏状态变了，把 Dart 侧的镜像改过来。
///
/// 用户按 Esc / 点绿灯退出全屏时，原生的 didExitFullScreen 会发事件，
/// 但 Dart 镜像还停在 true，下一次点全屏就会被 `_setPlaybackFullScreen`
/// 里的幂等判断吃掉，点了没反应。
///
/// 只有「系统全屏」的状态由这里推：铺屏走 setFrame，不发
/// didEnter/didExitFullScreen，只发 didResize —— 而 didResize 在铺屏的
/// 进入瞬间也会响（窗口从 1000x620 拉到 1512x944）。如果把 didResize 也当
/// 真，刚铺上屏就被打回 false，下一次右键被幂等判断吃掉，铺屏退不出去。
/// 所以这里只信系统全屏那两半，铺屏的状态只由 Dart 自己发起的调用改。
void syncPlaybackFullScreenFlag(bool enter) {
  _isPlaybackFullScreen = enter;
}

/// 铺屏态的镜像。给 [playback_bridge] 判 fullScreenChanged 用：铺屏时
/// setFrame 也会触发 didResize → fullScreenChanged(false)，但那不是退出全屏。
bool get isPlaybackInAppFullScreen => _isPlaybackInAppFullScreen;

/// 把系统全屏状态同步进 [PlPlayerController.isFullScreen]。
///
/// 用户在播放窗口里用麦克风键 / 系统菜单进全屏时走的是这条路，Dart 侧不发
/// triggerFullScreen，不补这一句整个播放器界面都以为还在窗口模式。
void syncFullScreenFromWindow({required bool isFullScreen}) {
  if (WindowEnv.isPlayback) return; // 播放窗口不走系统全屏
  final controller = PlPlayerController.instance;
  if (controller == null) return;
  _isDesktopFullScreen = isFullScreen;
  if (controller.isFullScreen.value != isFullScreen) {
    controller.setFullScreenState(isFullScreen);
  }
}

List<DeviceOrientation>? _lastOrientation;
Future<void>? _setPreferredOrientations(List<DeviceOrientation> orientations) {
  if (_lastOrientation == orientations) {
    return null;
  }
  _lastOrientation = orientations;
  return SystemChrome.setPreferredOrientations(orientations);
}

Future<void>? portraitUpMode() {
  return _setPreferredOrientations(const [.portraitUp]);
}

Future<void>? portraitDownMode() {
  return _setPreferredOrientations(const [.portraitDown]);
}

Future<void>? landscapeLeftMode() {
  return _setPreferredOrientations(const [.landscapeLeft]);
}

Future<void>? landscapeRightMode() {
  return _setPreferredOrientations(const [.landscapeRight]);
}

Future<void>? fullMode() {
  return _setPreferredOrientations(
    const [.portraitUp, .portraitDown, .landscapeLeft, .landscapeRight],
  );
}

bool _showSystemBar = true;
bool get showSystemBar_ => _showSystemBar;
Future<void>? hideSystemBar() {
  if (!_showSystemBar) {
    return null;
  }
  _showSystemBar = false;
  return SystemChrome.setEnabledSystemUIMode(.immersiveSticky);
}

//退出全屏显示
Future<void>? showSystemBar() {
  if (_showSystemBar) {
    return null;
  }
  _showSystemBar = true;
  return SystemChrome.setEnabledSystemUIMode(
    Platform.isAndroid && DeviceUtils.sdkInt < 29 ? .manual : .edgeToEdge,
    overlays: SystemUiOverlay.values,
  );
}
