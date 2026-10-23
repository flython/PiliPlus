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

/// 播放窗口的全屏。两种模式，别混：
/// - 系统全屏：NSWindow.toggleFullScreen:，独占一个 Space
/// - 应用内全屏（右键菜单）：把窗口铺满本屏，留在当前 Space，和主窗口行为一致
///
/// 为什么必须从原生侧发起：
/// Dart 侧用 FFI 改窗口属性会崩。nativeapi 的事件派发是同步的
/// （cnativeapi/src/platform/macos/window_manager_macos.mm:652
///   DispatchWindowEvent → Emit → listener->Invoke），AppKit 改
/// styleMask / frame 时会同步发出 windowDidResize，而此刻 Dart 还没从
/// FFI 调用返回，通知就回跳进了 Dart 回调，Dart VM 断言
/// "Cannot invoke native callback from a leaf call."
/// （runtime_entry.cc:5233）然后 abort。
/// 从 method channel 里发起时 Dart 栈已经退干净，通知落在事件循环里，
/// 不会命中那条断言。
///
/// 状态按窗口记，不按类记：多个播放窗口可以同时存在，而 static 的
/// restoreFrame 会让后开的窗口继承前一个的还原框。
private final class PlaybackFullScreenState {
  var restoreFrame: NSRect?
}

private enum PlaybackFullScreen {
  private static var states: [ObjectIdentifier: PlaybackFullScreenState] = [:]

  static func state(for window: NSWindow) -> PlaybackFullScreenState {
    let key = ObjectIdentifier(window)
    if let s = states[key] { return s }
    let s = PlaybackFullScreenState()
    states[key] = s
    return s
  }

  static func set(_ enter: Bool, inApp: Bool, on window: NSWindow) {
    if inApp {
      applyInApp(enter, on: window)
      return
    }
    // 已经在目标状态就别再 toggle，否则会把用户需要的那个状态反掉
    if window.styleMask.contains(.fullScreen) == enter { return }
    window.toggleFullScreen(nil)
  }

  /// 应用内全屏：只把窗口拉到本屏那么大，不动 styleMask（改 styleMask
  /// 会连带改 frame，触发同一批同步通知）。
  ///
  /// restoreFrame 为空时的退出一律按「已经铺过屏」处理，把窗口收回 800x600
  /// 的默认尺寸并居中，而不是什么都不做。窗口开机就落在 1512x944（几何记忆
  /// 或用户上次没退出），第一次右键进、第二次右键退时 restoreFrame 是 nil，
  /// 静默失败会让用户彻底失去退出手段。
  private static func applyInApp(_ enter: Bool, on window: NSWindow) {
    let state = state(for: window)
    if enter {
      guard state.restoreFrame == nil else { return }
      state.restoreFrame = window.frame
      if let screen = window.screen {
        window.setFrame(screen.visibleFrame, display: true)
      }
    } else {
      if let restore = state.restoreFrame {
        state.restoreFrame = nil
        window.setFrame(restore, display: true)
      } else {
        // 兜底：没有可还原的 frame，退回默认尺寸居中。
        let visible = window.screen?.visibleFrame ?? window.frame
        let w = min(SubWindowKind.playback.defaultSize.width, visible.width)
        let h = min(SubWindowKind.playback.defaultSize.height, visible.height)
        let frame = NSRect(
          x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h)
        window.setFrame(frame, display: true)
      }
    }
  }

  /// 窗口关闭时清掉，避免下一个播放窗口继承上一个的原 frame。
  static func reset(for window: NSWindow) {
    states.removeValue(forKey: ObjectIdentifier(window))
  }

  /// 供几何持久化判断：铺屏态下「铺满屏幕」的尺寸不该被记成窗口记忆位置。
  static func isInAppFullScreen(_ window: NSWindow) -> Bool {
    states[ObjectIdentifier(window)]?.restoreFrame != nil
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
        // 播放窗默认贴主窗口排：典型用法是主窗口在左、边播边在右边浏览列表。
        // 原来固定落 visible.midX，13 寸屏（逻辑宽 1440）上会被 clamp 拉到
        // x=440，直接盖掉主窗口 2/3 —— 用户观感是「点个视频，主窗口被压过去了」。
        let main = NSApp.windows.first {
          $0 !== window && $0.isVisible
            && $0.styleMask.contains(.titled)
            && $0.frame.width > 400 && $0.frame.height > 300
        }
        // 贴着主窗口时把窗口收窄到屏幕的 45%，让左右分屏真的成立
        var width = frame.width
        if main != nil { width = min(width, (visible.width - 3 * margin) / 2) }
        frame.size.width = width

        if let main {
          let mf = main.frame
          if mf.maxX + margin + width <= visible.maxX {
            frame.origin.x = mf.maxX + margin
          } else if mf.minX - margin - width >= visible.minX {
            frame.origin.x = mf.minX - margin - width
          } else {
            // 两边都放不下（主窗口本身就快占满屏了），退回居中
            frame.origin.x = visible.midX - width / 2
          }
          frame.origin.y = mf.midY - frame.height / 2
        } else {
          frame.origin.x = visible.midX - width / 2
          frame.origin.y = visible.midY - frame.height / 2
        }
      }
      window.setFrame(clamp(frame, in: visible), display: true)
    }
  }
}

/// 几何监听挂在 NSWindow 通知上，而不是 NSWindowDelegate。
///
/// 一个窗口只能有一个 delegate，而播放窗口要用 window_manager（置顶 / 全屏 /
/// PiP 边界，window_controller.dart:257-290）；一旦谁调了
/// `WindowManager.ensureInitialized()`，`WindowManager.swift` 的 mainWindow setter
/// 就会把自己设成该窗口的 delegate，delegate 方案在播放窗口上随时可能失效。
/// NSWindow 的 willClose / didMove / didEndLiveResize 通知与 delegate 归属无关。
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
        // 铺屏态下别把「铺满屏幕」这个尺寸存成记忆位置：下次开播放窗口会直接
        // 落成全屏尺寸，而且 SubWindowGeometry.apply 找不到屏幕会落默认位。
        if !PlaybackFullScreen.isInAppFullScreen(window) {
          SubWindowGeometry.save(kind, from: window)
        }
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

/// 装一次性 observer token 的小盒子。
///
/// 闭包里要把自己注册时的 token 摘掉，但 Swift 不允许闭包捕获「捕获后又被赋值」
/// 的局部 var（Swift 6 并发检查直接判错），所以过一层引用类型。
private final class ObserverTokenBox {
  fileprivate var token: NSObjectProtocol?
  fileprivate var tokens: [NSObjectProtocol] = []

  fileprivate func remove() {
    if let token { NotificationCenter.default.removeObserver(token) }
    token = nil
    for t in tokens { NotificationCenter.default.removeObserver(t) }
    tokens = []
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
              // 闭包强引用 viewController（进而强引用 engine），必须自己摘掉，
              // 否则 NotificationCenter 会一直留着，每开关一次播放窗口就漏一个引擎。
              // token 放进盒子里再捕获：闭包捕获后又被赋值的局部 var 在 Swift 6
              // 并发检查下是错误（这里报 warning），也拿不到"只摘一次"的语义。
              let closingBox = ObserverTokenBox()
              closingBox.token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
              ) { _ in
                closingBox.remove()
                PlaybackFullScreen.reset(for: window)
                channel.invokeMethod("windowClosing", arguments: nil)
              }

              // 用户可能按 Esc / 绿灯键 / 系统手势退出全屏，Dart 侧要跟着变。
              // 这些 observer 必须一起放进 closingBox：block 式
              // addObserver(forName:object:queue:usingBlock:) 被
              // NotificationCenter 强引用，且 block 捕获了 channel（进而
              // 是 engine），窗口关闭并不会自动摘掉 —— 每开关一次播放窗口
              // 就永久漏一个 block + 一个引擎的引用。
              // didResize 必须接：铺屏走 setFrame，不发 didExitFullScreen，
              // 少了它 Dart 侧的镜像会卡在 true，下一次右键被幂等判断吃掉。
              let fsEnterToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification, object: window,
                queue: .main
              ) { _ in
                channel.invokeMethod("fullScreenChanged", arguments: true)
              }
              let fsExitToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification, object: window,
                queue: .main
              ) { _ in
                channel.invokeMethod("fullScreenChanged", arguments: false)
              }
              let fsResizeToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window,
                queue: .main
              ) { _ in
                // 铺屏走 setFrame，不发 didEnter/didExitFullScreen，只发
                // didResize —— 少了这里 Dart 侧的镜像会卡在 true，下一次
                // 右键被幂等判断吃掉。
                // 只在铺屏态才报：系统全屏的 resize 由 didEnter/didExit
                // 覆盖，这里再报会跟 exit 撞车（185 行那次 true 就是撞出来的），
                // 把刚退出的状态又打回全屏，之后右键全失效。
                if PlaybackFullScreen.isInAppFullScreen(window) {
                  channel.invokeMethod(
                    "fullScreenChanged",
                    arguments: window.styleMask.contains(.fullScreen))
                }
              }
              closingBox.tokens += [fsEnterToken, fsExitToken, fsResizeToken]
            }
          }
          result(nil)

        case "setTitle":
          if let title = args["title"] as? String {
            viewController.view.window?.title = title
          }
          result(nil)

        case "togglePlaybackFullScreen":
          // 必须在原生侧改窗口状态，不能从 Dart 用 FFI 改：
          // AppKit 改窗口几何会同步发通知，通知回跳进 Dart 时 Dart 还在
          // FFI 叶子调用里，VM 断言直接 abort（详见 PlaybackFullScreen 注释）。
          // 缺 key / 拼错时默认「退出」，不是「进入」：误进全屏会把用户
          // 从窗口态强行拽走，误退则只是一次空操作。
          let enter = args["enter"] as? Bool ?? false
          let inApp = args["inApp"] as? Bool ?? false
          withWindow { window in
            PlaybackFullScreen.set(enter, inApp: inApp, on: window)
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
