import Cocoa
import FlutterMacOS
import desktop_multi_window

/// 子窗口类型。desktop_multi_window 建窗时只透传一个 `arguments` 字符串，
/// 类型由子窗口 Dart 侧解析后通过 `setupWindow` 回传原生（创建回调拿不到
/// windowId/config，见 .scratch/playback-separate-window/feasibility.md §1）。
private enum SubWindowKind: String {
  case danmaku
  case playback

  var defaultsKey: String {
    switch self {
    case .danmaku: return "danmakuSubWindowFrame"
    case .playback: return "playbackSubWindowFrame"
    }
  }

  var defaultSize: NSSize {
    switch self {
    case .danmaku: return NSSize(width: 480, height: 270)
    case .playback: return NSSize(width: 1000, height: 620)
    }
  }
}

/// 子窗口几何持久化：移动/缩放/关闭时记录 frame（屏坐标，点）。
/// 存 UserDefaults（Hive 是 Dart 侧存储，原生窗口事件无法可靠写回）。
/// 恢复时校验记忆位置所在显示器；已不存在则落到默认位置，
/// 并按目标屏可见区域钳制大小与位置。
private enum SubWindowGeometry {
  static let margin: CGFloat = 64

  static func save(_ kind: SubWindowKind, from window: NSWindow) {
    let f = window.frame
    UserDefaults.standard.set(
      "\(f.origin.x),\(f.origin.y),\(f.width),\(f.height)",
      forKey: kind.defaultsKey)
  }

  static func load(_ kind: SubWindowKind) -> NSRect? {
    guard let raw = UserDefaults.standard.string(forKey: kind.defaultsKey) else {
      return nil
    }
    let parts = raw.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 4 else { return nil }
    return NSRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
  }

  /// 主窗口当前所在屏；找不到时退回主屏
  static func homeScreen() -> NSScreen? {
    let mainWindow = NSApp.windows.first { $0 is MainFlutterWindow }
    return mainWindow?.screen ?? NSScreen.screens.first
  }

  static func clamp(_ frame: NSRect, in visible: NSRect) -> NSRect {
    let width = min(frame.width, visible.width)
    let height = min(frame.height, visible.height)
    let x = min(max(frame.origin.x, visible.minX), visible.maxX - width)
    let y = min(max(frame.origin.y, visible.minY), visible.maxY - height)
    return NSRect(x: x, y: y, width: width, height: height)
  }

  static func apply(_ kind: SubWindowKind, to window: NSWindow) {
    if let saved = load(kind),
      let screen = NSScreen.screens.first(where: {
        NSPointInRect(saved.origin, $0.frame)
      }) {
      window.setFrame(clamp(saved, in: screen.visibleFrame), display: true)
    } else {
      let home = homeScreen()
      let visible = home?.visibleFrame ?? window.frame
      var frame = NSRect(origin: .zero, size: kind.defaultSize)
      switch kind {
      case .danmaku:
        frame.origin.x = visible.maxX - frame.width - margin
        frame.origin.y = visible.maxY - frame.height - margin
      case .playback:
        // 播放窗落主屏右半边、纵向居中：典型用法是主窗口在左、边播边在左边浏览。
        frame.origin.x = visible.midX
        frame.origin.y = visible.midY - frame.height / 2
      }
      window.setFrame(clamp(frame, in: visible), display: true)
    }
  }
}

/// 几何监听挂在 NSWindow 通知上，而不是 NSWindowDelegate。
///
/// 原因：播放窗口需要 window_manager（置顶 / 全屏 / PiP 边界），而 window_manager
/// 在 Dart 侧 `ensureInitialized` 时会把自己的 WindowManager 设成 window.delegate
/// （WindowManager.swift 的 mainWindow setter），一个窗口只能有一个 delegate。
/// 原来的 delegate 方案在播放窗口上会被 window_manager 覆盖，位置记忆直接失效。
/// NSWindow 的 willClose/didMove/didEndLiveResize 通知不受 delegate 归属影响。
private final class SubWindowGeometryWatcher {
  static let shared = SubWindowGeometryWatcher()

  private var tokens: [ObjectIdentifier: [NSObjectProtocol]] = [:]

  func watch(kind: SubWindowKind, window: NSWindow) {
    let key = ObjectIdentifier(window)
    guard tokens[key] == nil else { return }
    let names: [Notification.Name] = [
      NSWindow.didMoveNotification,
      NSWindow.didEndLiveResizeNotification,
      NSWindow.willCloseNotification,
    ]
    let added = names.map { name in
      NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
        SubWindowGeometry.save(kind, from: window)
        if name == NSWindow.willCloseNotification {
          // 观察者必须随窗口一起注销：闭包强引用 window，
          // 否则每开关一次播放窗口/弹幕窗口就永久留下一个已关的 NSWindow。
          SubWindowGeometryWatcher.shared.release(key: key)
        }
      }
    }
    tokens[key] = added
  }

  func release(key: ObjectIdentifier) {
    for token in tokens.removeValue(forKey: key) ?? [] {
      NotificationCenter.default.removeObserver(token)
    }
  }
}

class MainFlutterWindow: NSWindow {
  private func registerSubWindowChannel() {
    // desktop_multi_window 的子 engine 不注册任何插件，Dart 侧无法程序化关闭
    // 自身窗口（SystemNavigator.pop 会 terminate 整个 app）。借助官方钩子给
    // 子 engine 挂一个极简通道；performClose 与用户点红色关闭按钮同路径。
    // 注意：放在 awakeFromNib 而非 AppDelegate.applicationDidFinishLaunching——
    // 后者在 FlutterAppDelegate 体系下实测不会被调用。
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { viewController in
      let registrar = viewController.registrar(forPlugin: "PiliPlusSubWindowChannel")
      let channel = FlutterMethodChannel(
        name: "PiliPlus/subwindow",
        binaryMessenger: registrar.messenger)

      // view.window 未挂上（VC 视图懒加载）则稍后重试。
      func withWindow(_ attempt: Int = 0, _ body: @escaping (NSWindow) -> Void) {
        if let window = viewController.view.window {
          body(window)
        } else if attempt < 50 {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withWindow(attempt + 1, body)
          }
        }
      }

      var pluginsEnabled = false

      channel.setMethodCallHandler { call, result in
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "close":
          viewController.view.window?.performClose(nil)
          result(nil)

        case "enablePlugins":
          // desktop_multi_window 的子 engine 从不跑 GeneratedPluginRegistrant，
          // 子窗口里 path_provider / window_manager / media_kit_video / audio_service
          // 全部 MissingPluginException。播放窗口要跑完整 app，必须显式补注册。
          // 弹幕子窗口刻意保持"零插件"（spec.md:27），所以按窗口类型按需开启。
          if !pluginsEnabled {
            pluginsEnabled = true
            RegisterGeneratedPlugins(registry: viewController)
          }
          result(nil)

        case "setupWindow":
          let kind = SubWindowKind(rawValue: args["type"] as? String ?? "") ?? .danmaku
          let title = args["title"] as? String
          // 创建即恢复记忆位置并挂几何监听；此时 Flutter 尚未出帧，移动无感。
          withWindow { window in
            SubWindowGeometryWatcher.shared.watch(kind: kind, window: window)
            SubWindowGeometry.apply(kind, to: window)
            if let title { window.title = title }

            // 播放窗口：关窗前先通知 Dart 收尾（落播放进度等）。willClose 早于
            // 窗口真正销毁，此刻 engine 还活着。只对播放窗口发，弹幕窗口零改动。
            if kind == .playback {
              NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
              ) { _ in
                channel.invokeMethod("windowClosing", arguments: nil)
              }
            }
          }
          result(nil)

        case "setTitle":
          if let title = args["title"] as? String {
            viewController.view.window?.title = title
          }
          result(nil)

        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  private func applyOpaqueWindowAppearance() {
    // 恢复系统默认的不透明窗口背景
    self.isOpaque = true
    self.backgroundColor = .windowBackgroundColor

    // 正常显示标题栏时禁用透明效果
    if self.titleVisibility == .visible {
      self.titlebarAppearsTransparent = false
      self.styleMask.remove(.fullSizeContentView)
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController.init()
    // 先不显示窗口
    self.isReleasedWhenClosed = false
    self.contentViewController = flutterViewController
    self.setFrame(self.frame, display: true)

    applyOpaqueWindowAppearance()
    registerSubWindowChannel()

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 监听首帧渲染完成再显示窗口
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("io.flutter.embedding.engine.firstFrame"),
      object: flutterViewController.engine, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      // window_manager 配置完成后恢复不透明样式
      self.applyOpaqueWindowAppearance()
      self.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
    // 不在这里调用 makeKeyAndOrderFront
    super.awakeFromNib()
  }
}
