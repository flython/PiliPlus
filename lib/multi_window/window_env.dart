import 'dart:convert';

/// 窗口类型。
///
/// desktop_multi_window 创建的所有子窗口与主窗口共用 [main] 入口，靠原生传入的
/// `['multi_window', windowId, arguments]` 分流（见 `sub_window.dart`）。
/// 整个 app 需要知道自己"在哪个窗口"才能决定：Hive 镜像 / 播放器归属 / 窗口装饰
/// 这三件只在播放窗口与主窗口之间不同的行为。
enum WindowKind {
  main,

  /// 播放窗口：跑完整 app，但 initialRoute 是 /playback 且不渲染底部 Tab。
  playback,

  /// 弹幕分离窗口：纯展示，无导航、无插件（历史功能，保持不变）。
  danmaku,
}

/// 播放窗口的 `WindowConfiguration.arguments`。除了给 `handleSubWindowLaunch`
/// 分流用，还要让播放引擎知道往哪个窗口 id 发路由（跨 engine RPC）。
const kPlaybackWindowType = 'playback';

/// 除类型外还要带上主引擎的 windowId —— 只有主引擎能寻址自己
/// （`WindowController.fromCurrentEngine`），子引擎寻址不了。
String buildPlaybackWindowArgs(String mainWindowId) => jsonEncode({
  'type': kPlaybackWindowType,
  'main': mainWindowId,
});

/// 主窗口的 arguments 恒为空串、弹幕窗口是 `{"type":"danmaku"}`，
/// 都不能误判成播放窗口。
bool isPlaybackWindowArguments(String? arguments) {
  if (arguments == null || arguments.isEmpty) return false;
  try {
    return (jsonDecode(arguments) as Map)['type'] == kPlaybackWindowType;
  } catch (_) {
    return false;
  }
}

abstract final class WindowEnv {
  /// 在 `handleSubWindowLaunch` 分流时写入；没被分流就是主窗口。
  static WindowKind kind = WindowKind.main;

  static bool get isMain => kind == WindowKind.main;

  static bool get isPlayback => kind == WindowKind.playback;

  static bool get isSubWindow => kind != WindowKind.main;
}
