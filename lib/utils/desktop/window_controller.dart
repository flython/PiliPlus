import 'dart:async' show Timer;
import 'dart:io' show Platform;

import 'package:PiliPlus/multi_window/window_env.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/utils/desktop/tray_controller.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:nativeapi/nativeapi.dart' as nativeapi;
import 'package:window_manager/window_manager.dart';

class WindowController {
  WindowController._();
  static WindowController get instance => _instance;
  static final WindowController _instance = WindowController._();

  int? _windowId;
  nativeapi.Window? _window;
  nativeapi.Window? get window => _window;

  double? _opacity;

  final _setting = GStorage.setting;
  bool _isMaximized = false;
  set windowMaximizedPref(bool value) {
    _setting.put(SettingBoxKey.isWindowMaximized, value);
  }

  Timer? _moveTimer;
  Timer? _resizeTimer;
  static const _kDuration = Duration(milliseconds: 200);

  late bool minimizeOnExit = Pref.minimizeOnExit;
  late bool pauseOnMinimize = Pref.pauseOnMinimize;
  late bool isPlaying = false;

  void init() {
    assert(_window == null);

    final window = WindowManager.instance.getCurrent();
    if (window == null) return;
    _window = window;
    _windowId = window.addListener(_windowListener);
    _isMaximized = window.isMaximized;
  }

  void _windowListener(WindowEvent event) {
    switch (event) {
      case WindowFocusedEvent():
        // https://github.com/leanflutter/window_manager/issues/571
        _setOpacityOnWindows(1.0);
        break;
      case WindowBlurredEvent():
        break;
      case WindowMinimizedEvent():
        break;
      case WindowMaximizedEvent():
        if (WindowEnv.isMain) windowMaximizedPref = _isMaximized = true;
        break;
      case WindowRestoredEvent():
        if (WindowEnv.isMain && _isMaximized) {
          windowMaximizedPref = _isMaximized = false;
        }
        break;
      case WindowMovedEvent():
        _moveTimer?.cancel();
        _moveTimer = Timer(_kDuration, onWindowMoved);
        break;
      case WindowResizedEvent():
        _resizeTimer?.cancel();
        _resizeTimer = Timer(_kDuration, onWindowResized);
        break;
      case WindowCreatedEvent():
        break;
      case WindowClosedEvent():
        break;
      case WindowEnteredFullScreenEvent():
        break;
      case WindowExitedFullScreenEvent():
        break;
      case WindowCloseRequestedEvent():
        // 播放窗口也跑这套监听器，但它只是众多窗口之一：cancel 会让红点
        // 点不动，onClose() 更是 GStorage.compact/close + 退出整个 app
        // ——点播放窗口的关闭键会把整个应用带走。
        if (!WindowEnv.isMain) break;
        event.request.cancel();
        if (TrayController.instance.showTrayIcon && minimizeOnExit) {
          _hide();
        } else {
          onClose();
        }
        break;
      case WindowPropertyChangedEvent():
        break;
      case WindowOcclusionChangedEvent():
        break;
    }
  }

  void onWindowMoved() {
    final window = _window;
    if (window == null) return;
    if (PlPlayerController.instance?.updatePipBounds(window) ?? false) {
      return;
    }
    // 播放窗口的位置/尺寸由 SubWindowGeometry 自己记到 UserDefaults，
    // 这里的 Hive key 是**主窗口**专用，写进去会互相覆盖。
    if (!WindowEnv.isMain) return;
    final position = window.position;
    _setting.put(SettingBoxKey.windowPosition, [position.x, position.y]);
  }

  void onWindowResized() {
    final window = _window;
    if (window == null) return;
    if (PlPlayerController.instance?.updatePipBounds(window) ?? false) {
      return;
    }
    if (!WindowEnv.isMain) return;
    final bounds = window.bounds;
    _setting.putAll({
      SettingBoxKey.windowSize: [bounds.width, bounds.height],
      SettingBoxKey.windowPosition: [bounds.x, bounds.y],
    });
  }

  void _playIfNeeded() {
    if (pauseOnMinimize && isPlaying) {
      PlPlayerController.instance?.play();
    }
  }

  void _pauseIfNeeded() {
    if (pauseOnMinimize) {
      if (PlPlayerController.instance case final player?) {
        if (isPlaying = player.playerStatus.isPlaying) {
          player.pause();
        }
      } else {
        isPlaying = false;
      }
    }
  }

  Future<void> onClose() async {
    await GStorage.compact();
    await GStorage.close();
    TrayController.instance.dispose();
    DeviceUtils.exitApp();
  }

  void _setOpacityOnWindows(double opacity) {
    if (Platform.isWindows && _opacity != opacity) {
      _opacity = opacity;
      _window?.opacity = opacity;
    }
  }

  void _hide() {
    _pauseIfNeeded();
    // https://github.com/leanflutter/window_manager/issues/571
    _setOpacityOnWindows(0.0);
    _window?.hide();
  }

  void show() {
    _window
      ?..focus()
      ..show();
    _playIfNeeded();
  }

  void toggleVisibility() {
    final window = _window;
    if (window == null) return;
    window.isVisible ? _hide() : show();
  }

  void dispose() {
    _moveTimer?.cancel();
    _resizeTimer?.cancel();
    _window?.removeListener(_windowId!);
    _window = null;
  }
}
