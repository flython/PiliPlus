import Cocoa
import FlutterMacOS
import desktop_multi_window

/// 子窗口几何持久化：移动/缩放/关闭时记录 frame（屏坐标，点）。
/// 存 UserDefaults（Hive 是 Dart 侧存储，原生窗口事件无法可靠写回）。
/// 恢复时校验记忆位置所在显示器；已不存在则落到主窗口当前屏幕右上
/// 偏移位置，并按目标屏可见区域钳制大小与位置。
private enum SubWindowGeometry {
  static let defaultsKey = "danmakuSubWindowFrame"
  static let defaultSize = NSSize(width: 480, height: 270)
  static let margin: CGFloat = 64

  static func save(from window: NSWindow) {
    let f = window.frame
    UserDefaults.standard.set(
      "\(f.origin.x),\(f.origin.y),\(f.width),\(f.height)",
      forKey: defaultsKey)
  }

  static func load() -> NSRect? {
    guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else {
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

  static func apply(to window: NSWindow) {
    if let saved = load(),
      let screen = NSScreen.screens.first(where: {
        NSPointInRect(saved.origin, $0.frame)
      }) {
      window.setFrame(clamp(saved, in: screen.visibleFrame), display: true)
    } else {
      let home = homeScreen()
      let visible = home?.visibleFrame ?? window.frame
      var frame = NSRect(origin: .zero, size: defaultSize)
      frame.origin.x = visible.maxX - frame.width - margin
      frame.origin.y = visible.maxY - frame.height - margin
      window.setFrame(clamp(frame, in: visible), display: true)
    }
  }
}

private final class SubWindowGeometryDelegate: NSObject, NSWindowDelegate {
  static let shared = SubWindowGeometryDelegate()

  func windowDidMove(_ notification: Notification) {
    save(notification)
  }

  func windowDidEndLiveResize(_ notification: Notification) {
    save(notification)
  }

  func windowWillClose(_ notification: Notification) {
    save(notification)
  }

  private func save(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    SubWindowGeometry.save(from: window)
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

      // 创建即恢复记忆位置并挂几何监听；此时 Flutter 尚未出帧，移动无感。
      // view.window 未挂上（VC 视图懒加载）则稍后重试。
      func setupGeometry(attempt: Int = 0) {
        if let window = viewController.view.window {
          window.delegate = SubWindowGeometryDelegate.shared
          SubWindowGeometry.apply(to: window)
        } else if attempt < 50 {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            setupGeometry(attempt: attempt + 1)
          }
        }
      }

      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "close":
          viewController.view.window?.performClose(nil)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      setupGeometry()
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
