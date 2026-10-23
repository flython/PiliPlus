# 播放页独立窗口（macOS）— SPEC

> 取证见同目录 `feasibility.md`（212 行）、`storage-isolation.md`（212 行）。
> 本文档只写"做什么"，证据与反证在上述两份报告里。

## 1. 目标

macOS 上把**视频列表（主窗口）**与**播放页（播放窗口）**拆成两个窗口，可以边播边在另一个窗口浏览列表。

## 2. 产品语义（已与用户逐条确认）

| # | 决策 |
|---|---|
| R1 | 播放窗口是「视频专用窗」：跑完整 GetX 路由表（能开 UP 页 / 番剧 / 评论 / 网页），**不渲染底部 Tab 导航栏**；**不挂常驻返回按钮**（返回靠 Esc / 标题栏关闭），有原生标题栏 |
| R2 | 全局最多一个播放窗口。播放窗口内再点视频 = 原地替换（沿用 `toVideoPage` 的 `off` 语义），不新开窗 |
| R3 | macOS **默认开启**。开关两处：`设置 → 桌面`「播放页独立窗口」+ 播放页头部（与弹幕分离开关同位置）。关掉完全退回今天的行为 |
| R4 | UGC / PGC / 番剧 / 收藏 / 稍后再看 / 历史 / 动态里的视频全部进播放窗口（共用 `PageUtils.toVideoPage` 单点收口） |
| R5 | 关闭播放窗口 = **停止播放并释放**，不做后台继续播放 |
| R6 | 独立弹幕子窗口的**形态与行为完全不变**（黑底 + 标题 + 纯弹幕，不读 Hive、无交互），只是驱动方从主引擎变为播放引擎 |
| R7 | 跨窗口分流：**默认全部留在本窗口**，一条自动跨窗口分流都不做。那 63 处硬编码的 `Get.toNamed('/member?mid=…')` 一行不用改 |
| R8 | 不做「在主窗口打开」逃生口（二期再议） |

## 3. 两个硬阻塞与选定方案

| 阻塞 | 证据 | 方案 |
|---|---|---|
| **H1 Hive** | 同进程两 isolate 共用一个 box 文件会静默丢数 + `close()` 抛 `PathNotFoundException`（`storage-isolation.md` 实测） | **A：主引擎唯一 Hive owner**。播放引擎不开任何 Hive 文件，用主引擎下发的整箱快照做内存镜像，所有写操作转发主引擎。播放引擎零 Hive 文件、零锁、零 compact |
| **H2 media_kit** | `media_kit_native_event_loop.cc:21-26` 的 `static Dart_PostCObject g_post_c_object` / `static Dart_Port g_send_port` 是**进程级**，后建 Player 的 engine 会抢走端口，先建的那个播放器静默停更 | **A1：播放窗口 = 唯一媒体引擎**。主窗口永不创建 `Player`，直播 / 音频 / 桌面小窗播放的播放器全部转发到播放窗口 |

**H2 的连带后果（必须写进验收清单）**
- 主窗口不再有播放器 ⇒ 桌面小窗播放 / 桌面 PiP / 最小化暂停在主窗口失效（它们全部依赖 `WindowController.instance.window`）。
- Now Playing 与键盘媒体键改由播放窗口的 engine 提供。
- **这反过来推翻了「直播留主窗口」的原始决策**（弹幕分离功能从未覆盖直播）。

## 4. 架构

```
┌────────────────────── 主进程 / 单进程 ──────────────────────┐
│                                                          │
│  Engine 1（主窗口）                Engine 2（播放窗口）      │
│  ├ GetX 路由（/ 底部 Tab）           ├ GetX 路由（/playback）│
│  ├ 视频/直播/音频列表                ├ 视频页 / 直播 / 音频    │
│  ├ Hive owner（唯一）               ├ Hive 内存镜像（A）     │
│  ├ Tray / WindowController          ├ WindowController(自己)│
│  └ 无 Player                        └ Player（唯一）        │
│         │                                    ▲               │
│         │  desktop_multi_window + 自定义 channel           │
│         ├───── 打开播放窗口 /arguments{type:playback} ─────>│
│         │<──── 视频 arguments（JSON）──────────────────────┤
│         │<──── storageSnapshot（整箱二进制）────────────────┤
│         │──── storageApply（写穿）────────────────────────>│
│         │                                                  │
│         └─ Engine 3（弹幕子窗口，形态不变，零插件业务依赖）─┘
└──────────────────────────────────────────────────────────┘
```

## 5. 实施清单

### 5.1 原生 `macos/Runner/MainFlutterWindow.swift`
- N1 `onWindowCreatedCallback` 内对子窗口调 `RegisterGeneratedPlugins(registry: viewController)`。**这是所有后续工作的前提**（子 engine 现在零插件注册，连 `path_provider` 路径都拿不到）。
- N2 `SubWindowGeometry` 改为按窗口类型参数化（defaultsKey / defaultSize：弹幕 `danmakuSubWindowFrame` 480×270；播放 `playbackSubWindowFrame` 1000×620）。
- N3 新增 channel 方法 `setupWindow({type, title, width, height})`，**由子窗口 Dart 主动调用**（回调拿不到 windowId，见 `feasibility.md` §1）。原生负责：装几何 delegate、恢复记忆几何、设置标题、设置初始尺寸。
- N4 几何 delegate 的安装时机必须晚于 window_manager 的 `register()`（否则被抢），`setupWindow` 的异步轮询天然满足。

### 5.2 Dart 窗口识别与分发
- D1 `lib/multi_window/window_env.dart`：`enum WindowKind { main, playback, danmaku }` + `WindowEnv.kind`。
- D2 `lib/multi_window/sub_window.dart`：新增 `'playback'` 分支；**弹幕分支零改动**。
- D3 `lib/multi_window/playback_window.dart`：`PlaybackWindow.i.open(arguments)`（已存在则替换 + `show/focus`）、`exists`、`close`。
- D4 `lib/utils/page_utils.dart`：`toVideoPage` / `toLiveRoom` / 音频播放入口，主窗口且开关开启时转发到播放窗口；播放引擎内部维持栈内替换。

### 5.3 播放引擎 bootstrap
- D5 `lib/main.dart`：子窗口分流之后按窗口类型走不同的 `runApp`；播放引擎复用主引擎的全部 bootstrap（MediaKit / 路径 / GetX lazyPut / HttpOverrides / setupServiceLocator / Request / SmartDialog），但 `initialRoute = '/playback'`、不跑窗口标题栏与最大化逻辑。
- D6 `lib/router/app_pages.dart` + 新页面：新增 `'/playback'` 哨兵页（不渲染底部 Tab 的空壳），`/playback` 是播放引擎的路由栈底；弹到栈底 = 关闭整个播放窗口。

### 5.4 存储镜像（H1）
- D7 `lib/utils/storage/memory_box.dart`：`MemoryBox<E> implements Box<E>`，纯 map 支撑同步读，`put/delete/clear/putAll/deleteAll` 同步改本地 + 异步转发主引擎。
- D8 `lib/utils/storage/hive_codec.dart`：用 hive_ce 的 `BinaryWriterImpl`/`BinaryReaderImpl` + `TypeRegistryImpl` 编解码整箱（`UserInfoData` / `LoginAccount` 等自定义 adapter 对象必须走 hive 二进制，不能用 JSON）。
- D9 `lib/utils/storage/storage_bridge.dart`：播放引擎侧拉快照 + 转发写；主引擎侧提供快照 + 执行写。
- D10 `lib/utils/storage.dart`：`GStorage.init()` 按窗口类型分叉；`regAdapter()` 改成可传入指定 registry。

### 5.5 已知崩溃点修复
- F1 `lib/pages/video/introduction/local/controller.dart:53` `Get.find<DownloadController>()` —— `DownloadController` 只在下载页 `Get.put`，播放引擎播离线视频必崩 → 补 `lazyPut`。
- F2 `lib/services/shutdown_timer_service.dart:82` `late final player = PlPlayerController.instance;` —— nullable 赋给 `late final`，主窗口无播放器时 TypeError。

### 5.6 设置开关
- S1 `lib/utils/storage_key.dart` + `lib/utils/storage_pref.dart` 新增 `playbackSeparateWindow`，macOS 默认 `true`，其它平台不显示。
- S2 设置页 + 播放页头部各一个开关。

## 6. 明确不做

- 不做「在主窗口打开」逃生口。
- 不做后台继续播放。
- 不做播放窗口「切成纯弹幕模式」。
- 不做多播放窗口并行。
- 不改 media_kit fork、不引入 IsolatedHive、不做 storage 反向推送。
- Windows / Linux 不在本次范围。

## 7. 已知取舍（必须让用户知情）

1. 播放窗口存活期间，主窗口改的设置**不会实时反映**到播放窗口（镜像只单向回写）。
   用户把焦点切回播放窗口时会补拉一次（`StorageMirror.refresh`，
   3s 限流），所以「切过去就看得见」，但窗口一直开着、期间只改设置不切窗口
   的场景仍看不见。
2. 播放窗口里的账号同理，切回播放窗口时会补拉。刷新时会把「还没被主引擎
   确认的写」重新盖回去，不会把播放窗口刚写的登录态冲掉。
3. **写回会覆盖**：播放窗口里改一项弹幕/字幕设置，`save()` 会把这一组 static
   字段的**全部**值一起写回主引擎（`DanmakuOptions.save()` 写 15 个键、
   `putSubtitleSettings()` 写 7 个键），其中其余项是播放窗口启动时的旧值
   ⇒ 主窗口刚改过的设置下次启动生效时会被还原。这是 §1 的加强版：
   不仅不刷新，还会**回滚**。
4. 主窗口的桌面小窗播放 / PiP 失效（播放器只存在于播放窗口）。
   最小化暂停同样只在播放窗口生效。
5. 两 engine 都注册 `audio_service`；只有有 Player 的那个会更新 Now Playing
   与媒体键。
6. 播放窗口里点视频页头部的「返回主页」= `Get.until(isFirst)` = 回到哨兵页
   = 关掉整个窗口（`header_control.dart:1757`）。这是既有语义，本次没有改它。
7. 播放窗口**不再有悬浮返回按钮**（用户决策：常驻的返回键挡画面）。
   返回上一层的入口只剩：Esc（`main.dart` 的 `BackDetector` → `_onBack`
   → `Get.back`）、原生标题栏关闭键（关窗即停止播放）。
   代价是「播放窗口里点进 UP 页 / 评论页后返回」没有可见按钮；
   `_onBack` 在栈可 pop 时就是 `navigator.pop()`，键盘可达。
8. 「播放页独立窗口」开关只在**主窗口**「设置 → 桌面」里会连带关掉播放窗口。
   在播放窗口的视频页头部关掉它，只改后续入口；已经开着的播放窗口继续播，
   视频也继续送它（一个进程只能有一个 media_kit `Player`），
   直到用户自己关窗。

## 8. 验证状态

### 8.1 已通过

| 项 | 命令 | 结果 |
|---|---|---|
| 单元测试 | `flutter test test/memory_box_test.dart`（Flutter 3.47.7） | `00:00 +15: All tests passed!` — MemoryBox 5 条、编解码往返 4 条、播放窗口 arguments 判定 3 条 |
| 静态分析 | `dart analyze`（本次改动全部文件） | `No issues found!`（0 error / 0 warning / 0 info） |
| 全仓静态分析 | `dart analyze lib` | 187 issues（基线 178）。命中本次改动文件的只有 `gallery_viewer.dart` 的 PhotoView API 既有断裂，参数本身一行没动 |
| 仓库另两个既有测试 | `flutter test test/danmaku_sub_settings_test.dart test/utils/accounts/deleted_account_test.dart` | **加载失败**，非本次引入：它们传递 import 到 `mini_scaffold.dart`（`StandardBottomSheet`）与 `dyn_tab_bar.dart`（`TabBarState` / `TabBarLayoutCallback` / `IndicatorPainter`），这些 Flutter 内部类在 3.47 已改名/移出，与 §8.2 同族 |

测试只 import 叶子文件（`window_env.dart` / `hive_codec.dart` / `memory_box.dart`），
绕开 `GStorage` → widget 依赖链上两个在 Flutter 3.47.x 编译不过的既有文件
（`text_ellipsis/paragraph_ellipsis.dart`、`text_more/paragraph_more.dart`，
原因见下）。

### 8.2 阻塞：macOS 端到端构建在本环境跑不起来（既有依赖问题，非本改动引入）

`flutter build macos --debug` 在编译第三方 pod `media_kit_video` 时失败：

```
media-kit-85f0a69e…/media_kit_video/common/darwin/Classes/plugin/MPVVideoOutParams.swift:23:12:
  error: cannot find type 'mpv_node_list' in scope
…/TextureSW.swift:48:18: error: cannot find 'MPV_RENDER_API_TYPE_SW' in scope
…/TextureSW.swift:50:18: error: cannot find type 'mpv_render_param' in scope
…/TextureSW.swift:56:7: error: cannot find 'mpv_render_context_create' in scope
** BUILD FAILED **
```

**证据表明与本改动无关**：`git worktree add /tmp/piliplus-baseline b356efc26`
在**未改动的基线**上构建，报完全相同的错误、同一批文件。
失败点在 CocoaPods 依赖编译阶段，先于 Runner target，`~/.pub-cache` 下的文件本 diff 从未触及。

根因（待修，不在本次范围）：`media_kit_video/macos/media_kit_video.podspec`
只声明了 `s.dependency 'FlutterMacOS'` +
`FRAMEWORK_SEARCH_PATHS` + `OTHER_LDFLAGS = -framework Mpv`，
**没有 `s.dependency 'media_kit_libs_macos_video'`**，
所以 Swift 侧看不到 mpv 的 C 声明。这与本仓库锁定的
`media_kit_video` fork（`bggRGjQaUbCoE/media-kit` ref `native`）
和当前 Xcode 16.2 / Swift 工具链的组合有关。

修它需要动 `dependency_overrides` 或上游 fork，
而 **H2 的结论正是基于当前这个老 media-kit**（进程级 `g_send_port`，
新版 `media-kit-08b7b941…` 才是 per-handle 注册的修好版），
换版本会同时推翻本设计的存储/播放器归属分析。因此不在本次改动内处理。

### 8.3 因此未获得的验证（必须让用户知情）

- 没有实机运行截图/录屏。
- 分窗开合、跨窗口跳转、弹幕子窗口回归、关窗释放播放器 —— 这些只有
  §8.2 的依赖问题解决后才能端到端验证。
- Windows 端未编译（`setupWindow` 调用已用 `Platform.isMacOS` 守卫，
  因为 `windows/runner/sub_window_channel.cpp:61-69` 只实现了 `close`）。

### 8.4 静态审阅发现并已修的 8 个 bug

见 commit `3b7e2a7a6` 之后的修复提交：

1. **关播放窗口会永久关掉用户的「弹幕分窗」设置**（`cc11fa18c`）：
   `_stopEverything()` 调的是 `DanmakuForwarder.close()`，
   而它的语义是「设置面板关开关」，会把 `SettingBoxKey.danmakuSeparateWindow`
   写成 `false` 并落盘。改为新增的 `DanmakuForwarder.teardown()`
   （直接走 `_teardownWindow()`，不动记忆开关）。
2. **主窗口 method handler 被顶掉**（`cc11fa18c`）：
   `PlaybackWindow.init()` 与 `StorageMirror.attachMain()` 先后对同一个
   `WindowController` 调 `setWindowMethodHandler`，
   而 `desktop_multi_window` 的 `WindowChannel` 每 channel 只存一个 handler，
   后注册的会把先注册的顶掉 ⇒ `kWindowClosedMethod` 丢失，
   主引擎再也收不到「播放窗口已关」。改为合并成一次注册
   （`StorageMirror.onMainCall(MethodCall)` 静态方法）。
3. **关窗重复拆播放器**（`cc11fa18c`）：关窗有三条入口
   （主引擎 `teardown`、`closeWindow`、原生标题栏 `windowClosing`），
   `_closing` 闸门只挡住后两条对 `closeWindow` 的重入，
   `kTeardownMethod → _stopEverything()` 仍会第二次执行
   `PlPlayerController.updatePlayCount()`。加 `_stopped` 闸门。
4. **子窗口 NSWindow 泄漏**（`211e497ae`）：
   `MainFlutterWindow.swift` 的 `SubWindowGeometryWatcher.watch()`
   只增不减，而通知闭包强引用 `NSWindow` ⇒ 每开关一次播放/弹幕窗口
   就永久留下一个已关窗口。加 `release(key:)`，
   在 `willClose` 通知里 `removeObserver`。
5. **`MemoryBox.clear()` 不转发删除**（`d313bc8a5`）：
   只清本地镜像，主引擎盘上数据还在 ⇒ 下次启动快照一灌，
   用户以为清掉的搜索历史又回来了。改为逐条 `onWrite(name, key, null)`。
6. **`MemoryBox.add()` 自增从 0 重排**（`d313bc8a5`）：
   快照里已有 `0..N` 这些数字键（`historyWord` / `video` 就是这么存的），
   `add()` 从 0 起会直接盖掉已有条目。改为 `applySnapshot()` 后
   从 `max(numeric keys)+1` 接着排。
   两者的回归用例在 `test/memory_box_test.dart`（15 条全过）。

### 8.5 查过但确认「不是 bug」的假设（记录以免重复排查）

- **`didPop` 会不会把「原地替换」误判成按返回**：不会。
  `Get.offNamed` 走 `NavigatorState.pushReplacement`，
  observers 收到的是 `didReplace` 而非 `didPop`
  （GetX `routes/observers/route_observer.dart` 只实现这两个回调）；
  `didPop` 仅在真 pop 时触发，而 GetX 的 `didPop` 会同步把
  `Routing.current` 设为 `previousRoute` 名。
  曾据猜测改过一版「等一帧再看栈顶」，证伪后已撤回。
- **`GStorage.init()` 的播放分支跳过 `regAdapter()` 会导致 typeId 错位**：
  不会，`regAdapter()` 在 return 之前（`lib/utils/storage.dart:30-35`）。
- **`Accounts.accountMode` 在播放引擎是空的**：不会，
  `main()` 无条件跑 `Request.setCookie()` → `Accounts.refresh()`。
- **非 macOS 平台会被这条路径波及**：不会，
  `Pref.playbackSeparateWindow` getter 带 `Platform.isMacOS &&` 守卫。
- **子窗口几何 key 与主窗口/弹幕窗口冲突**：不会，
  `playbackSubWindowFrame` / `danmakuSubWindowFrame`（UserDefaults），
  主窗口几何在 Hive 的 `SettingBoxKey.windowSize/windowPosition`。

### 8.6 第二轮三份 subagent 评审发现并已修的问题

评审范围 `b356efc26..3b7e2a7a6`，三条独立视角：并发/生命周期、回归一致性、用户视角。

**阻断级**

1. **`await Get.toNamed/offNamed` 等的是路由的 *pop* future，不是导航完成**
   ⇒ `kOpenVideoMethod` 的应答要等用户离开视频页才发出 ⇒ 主引擎的
   `controller.show()` 永远等不到 ⇒ 窗口是 `hiddenAtLaunch` 建的
   ⇒ **第一次点视频播放窗口根本不出现，第二次才带着第二个视频出来**。
   根因：getx `extension_navigation.dart:120-123`/`:157-160` 就是
   `pushNamed`/`pushReplacementNamed` 的返回值；而
   `desktop_multi_window` 的 `invokeMethod` 是请求-应答式往返。
   改为导航**不 await**，只把「窗口标题」这个本地通道 await 在前面。
   连带 `lib/pages/download/detail/widgets/item.dart:155`、
   `lib/pages/later/widgets/video_card_h_later.dart:210` 的
   `await PageUtils.toVideoPage(...)` 不再挂满窗口生命周期。
2. **主窗口仍能建 `Player`**，三个口子：`PageUtils.toVideoPage` /
   `toLiveRoom` 的兜底分支、`AudioPage.toAudioPage`、`gallery_viewer.dart`
   的 livePhoto。后建的 `Player` 会抢走 media_kit 那个**进程级**事件循环
   端口，表现为正在播的窗口无声 + 进度条不动 + 一行日志都没有。
   三处兜底全部删掉，改为提示；`/audio` 补上 `PlaybackWindow` 分支。
3. **播放引擎的窗口集成整条链断掉**：`main.dart` 用
   `WindowEnv.isMain` 把整个 window_manager 块挡在播放引擎外
   ⇒ `WindowController.instance.window` 恒为 null ⇒ 置顶 / 桌面全屏 /
   桌面小窗播放全是 `?.` 静默 no-op，按钮在、点了没反应也没提示。
   改为播放引擎也 `WindowController.instance.init()`，并在
   `window_controller.dart` 里给三处加 `WindowEnv.isMain` 守卫：
   - `WindowCloseRequestedEvent` 不再 `cancel()` + 不再走 `onClose()`
     （后者 = `GStorage.compact/close` + `DeviceUtils.exitApp()`，
     **点播放窗口的关闭键会结束整个 app**）；
   - `onWindowMoved` / `onWindowResized` 不再把播放窗口的几何写进
     **主窗口**的 Hive key。

**严重级**

4. `_destroyQuietly` 里 teardown 与 close 在同一个 `try` 顺序 await：
   teardown 超时则 close 永不执行，mpv 继续出声，而主引擎已把句柄置空
   ⇒ 下一次点视频开出**第二个**播放窗口。拆成两个独立 `try`。
5. `close()` 在 `_controller == null` 时直接 return 不 bump `_generation`，
   `windowClosed` 通路同样不 bump ⇒ `_dispatch` 唯一的中断点失效
   ⇒ **用户明明关掉了，窗口又自己弹出来播**。两条通路都无条件自增。
6. `show()` 早于播放引擎就绪：app 没 ready 时直接回包成功 ⇒ 主引擎
   show 出一个没标题、没控件、完全无响应的白窗。改为先
   `await _appReady.future` 再回包。
7. 存储快照取空**静默降级**：`snapshotReady` 标志 + 播放引擎内部
   `await` 快照完成（而不是让主引擎把这次点击重试满预算），
   等不到才抛，抛出去只提示不回退主窗口内打开。
8. 关窗丢播放进度/心跳：原来只调一次 `PlPlayerController.updatePlayCount()`，
   而它在 `_playerCount > 1` 时只 `-= 1`，既不 dispose 也不报心跳。
   改为直接 `dispose()`。
9. `_pushTo` 的 `catchError((_) {})` 彻底吞掉写失败，`_findBox` 静默 return
   ⇒ 播放引擎的写入静默丢失、日志零行。两处都补 `debugPrint`。
10. `header_mixin.dart` 的开关被 `WindowEnv.isMain` 挡住，而开关打开时
    视频页就跑在播放引擎里 ⇒ **这个入口是死的**。改为两个窗口都渲染，
    换成自带状态的 `_PlaybackSeparateSwitch`（`Pref` 只是 Hive getter，
    没有东西通知外面重建，拨动后会一直停在旧值）。
11. **关掉开关不会关掉已开的播放窗口**，而主窗口随后会按新条件自己建
    `Player` ⇒ 两个 engine 抢端口，正在播的窗口卡死。
    `SwitchModel.onChanged` 与页头开关都接
    `PlaybackWindow.onSeparateWindowChanged`。
12. **播放窗口里没有可见的返回入口**：桌面端视频页 `appBar` 恒为 null，
    移动端那个带返回的 `_buildOverlayToolBar` 不渲染，
    原生标题栏又留白（`setTitle` 全仓无 Dart 调用点）。
    曾新增 `PlaybackBackButton`（由 `PlaybackBridge.routeTick` 驱动显隐）；
    **该按钮已被根除**，见 §7 第 7 条。`_openVideo` 里按视频标题调原生
    `setTitle` 保留。
13. 播放窗口复用句柄派发失败时**只丢句柄不拆窗** ⇒ 屏幕上留一个主引擎
    再也关不掉的孤儿窗口，下次点视频开出第二个。改为连窗一起
    `_destroyQuietly`。

**一般级**

14. 原生 `windowClosing` 的 observer token 被丢弃 ⇒ 闭包强引用
    viewController ⇒ 每开关一次播放窗口泄漏一个引擎。自己摘掉。
15. 播放引擎没初始化 `CacheManager.manager` ⇒ 进度条缩略图静默空白、
    `image_utils.dart` 弹 `LateInitializationError`。放开门控。
16. 派发重试预算从 12s 降到 ≈4s（20×200ms）：真正要等的只有「子引擎
    注册上 handler」，其余等待已移进播放引擎内部；这段时间用户既没有
    spinner 也没有提示。
17. 播放窗口首次落位固定在 `visible.midX`，13 寸屏上会被 clamp 盖掉主窗口
    2/3。改为**贴主窗口排**（放不下才居中）并把宽度收到屏幕的 45%。
18. 播放窗口 `minimumSize` 从未设置（默认 1000×620 无下限）。
19. 「在播放窗口里点 UP 页的视频」原来一律 `offNamed`，UP 页被顶掉后回不去。
    改为栈顶是媒体页才替换，否则压一层
    （`PageUtils.toPlaybackMediaNamed`，三处媒体入口共用）。
20. 已存在的播放窗口再次派发时不置前 ⇒ 主窗口点第二个视频「纹丝不动」。
    补 `await existing.show()`。

**查过确认不是 bug 的（记录以免重复排查）**

- `PlPlayerController.dispose()` 没有 dispose `Player`：**有**。
  `controller.dart:77` 的 `_videoPlayerController` 就是 `Player?`，
  `dispose()` 里调的就是它。
- `getAll()` / `add()` 在镜像箱上不可达、`clear()` 只在主窗口路由
  可达、`value as Uint8List` 在 `StandardMessageCodec` 上安全、
  `off: true` 到不了 `/videoV`（全仓只有两处字面量，都走 `/pgc` 与 webview）。
- 弹幕子窗口的几何与 Windows 路径零回归；播放窗口几何 key
  （`playbackSubWindowFrame`）与弹幕（`danmakuSubWindowFrame`）、主窗口
  （Hive `SettingBoxKey.windowSize/windowPosition`）三方不冲突。
- `SubWindowGeometryDelegate → SubWindowGeometryWatcher` 改成通知而非
  delegate：全仓没有任何地方调 `WindowManager.ensureInitialized()`，
  delegate 暂时不会被抢；但播放引擎现在要用 window_manager 了，
  通知方案对「谁将来调了 ensureInitialized」免疫，留着。

### 8.7 第三轮并发/生命周期评审发现并已修的问题

评审范围 `9aea6df1b..8b285909e`（只看第二轮的修复本身）。

**阻断级**

21. **`toPlaybackMediaNamed` 漏传 `preventDuplicates: false`**
    ⇒ **播放窗口里点「下一个视频」毫无反应**。
    GetX `extension_navigation.dart:149-151` 是
    `if (preventDuplicates && page == currentRoute) return null;`，
    默认 `true` 的意思是「往当前这一页替换回当前这一页直接短路」。
    同文件的老 `toDupNamed`（`:833-838`）早就显式传了这个参数，
    新函数漏抄。`toLiveRoom` 的 `off: true` 分支同样漏。
22. **`_dispatch` 的单次 `invokeMethod` 没有 `.timeout`**
    ⇒ 对端不回包时 future 永远不 complete，`Future.delayed` 只在 catch
    分支里，「20 次 × 200ms」这个上界对「不回复」根本不成立
    ⇒ **主窗口被永久挂死**，`.catchError` 的 toast 都出不来，
    之后每次点视频重复挂死。对端 `await _appReady.future` 同样无界
    （`markAppReady()` 那次 post-frame 没跑到就永远 pending）。
    单次往返加 5s 上限。

**严重级**

23. **`windowClosed` 通知不带窗口标识**：旧窗口那条迟到的通知会无条件把
    **新**窗口的句柄清掉（`windowClosed` 通路无法分辨是哪一代窗口）。
    播放引擎在两处 `invokeMethod(kWindowClosedMethod, _selfWindowId)`，
    主引擎比对 windowId 后再决定要不要清句柄。
24. **写回没有 flush 栅栏**：`_pushTo` 是 fire-and-forget，
    而关窗路径是 `dispose()` 写完播放进度紧接着 `invokeMethod('close')`
    把原生窗关掉 ⇒ engine 随之销毁，没发出去的写全作废
    ⇒ 用户看到「关掉播放窗口后进度没记上」。
    加 `_inFlight` 计数 + `StorageMirror.settle()`（`_stopEverything` 末尾等它）。

**一般级**

25. **主引擎 → 播放引擎没有补拉通道**：镜像是启动那一刻取的快照，
    主窗口在此期间切账号 / 改设置 / 退出登录，播放窗口全都看不见 ——
    最刺眼的是**点赞记到旧账号**；反向也坏：过期快照上的
    `MemoryBox.clear()` 会按本地键逐个转发 delete，把主窗口已经删掉或
    改过的键再删一遍。
    补 `StorageMirror.refresh()`，由播放窗口的 `WindowFocusedEvent` 触发
    （macOS 上点同 app 的另一个窗口不会触发 `didBecomeActive`，
    `AppLifecycleState` 也不会变，窗口焦点是唯一可靠信号）。
    刷新时会把「还没被主引擎确认的写」重新盖回去，并 `Accounts.refresh()`
    重建 `accountMode`。
26. `openRoute` 里复用分支的 `show()` 若抛 `CHANNEL_UNREGISTERED`
    （窗口在这中间被用户关掉）会掉进销毁分支，把一个好好的窗口拆掉。
    派发与 `show()` 分离，`show()` 单独 `try`。

### 8.8 第四轮「修复本身有没有引入新问题」评审

评审范围 `9aea6df1b..8b285909e`，专门盯第二轮修复本身。

**阻断级**

27. **`_fetchDone` 闸门永远打不开，「等快照」的修复等于没修，而且比修之前更慢。**
    `_fetchDone` 只在 `openBoxes()`（由 `GStorage.init()` 调，`main.dart:111`）
    里创建，但 `fetchSnapshot()` 由 `PlaybackBridge.init()` 调
    （`main.dart:106` → `playback_bridge.dart:68`）**先**执行
    ⇒ `fetchSnapshot` 末尾那句 `complete()` 看到的是 null，是死代码；
    随后 `openBoxes` 造出一个再也没人 complete 的 Completer
    ⇒ 任何 `throwIfSnapshotMissing()` 都停在 `await _fetchDone.future` 上
    ⇒ 主引擎那次点击要卡满重试预算才报错。
    两处都改成 `_fetchDone ??= Completer<void>()`。
28. **总预算不是「次数 × 单次上界」。** `_kDispatchAttempts = 20` 配单次 5s
    timeout，实际是 ≈104s 的「点了没反应」。改成 Stopwatch 卡 10s 总预算，
    单次上限 3s 且不越过总预算。

**严重级**

29. **在播放窗口里关掉「播放页独立窗口」开关 ⇒ 同进程两个 `Player`。**
    `onChanged` 里的 `if (WindowEnv.isMain)` 在播放引擎里是空操作（关窗逻辑
    在播放引擎里够不着），而 `Pref` 的写会经 `_applyWrite` **立刻**落到主引擎
    真实 Hive ⇒ 主引擎从此开始建第二个 `Player`，抢 media_kit 进程级端口。
    根因是把「要不要走播放窗口」等同于「开关状态」。改成
    `PlaybackWindow.useSeparateWindow => Pref.playbackSeparateWindow || isOpen`：
    **只要播放窗口还开着，视频就必须继续走它**，与开关无关。
    想收回窗口去主窗口「设置 → 桌面」拨，那里才会真正关窗。
30. **已有窗口的派发失败被静默吃掉。** `catch (_)` 拆窗之后没有 rethrow，
    调用方以为成功，既不回退主窗口也不弹提示，用户点的视频凭空没了。
    与 `openRoute` 自己的文档矛盾。

**一般级**

31. `extra_settings.dart:63` 缺 `WindowEnv.isMain` 守卫（今天 `/setting` 在播放
    窗口不可达）。由 29 的改动一并解决：`onSeparateWindowChanged` 在播放引擎里
    本来就是空操作，且 `useSeparateWindow` 现在不再依赖开关。
32. ~~返回按钮的 `Stack` 在 SmartDialog overlay **之上**~~ —— 已过时：
    用户要求去掉常驻返回键，`PlaybackBackButton` 连同 `main.dart` 里的
    `Stack` 挂载点一起删除了，这个问题不复存在，见 §7 第 7 条。
33. `playback_bridge.dart` 关于 `previousRoute == null` 的注释与 GetX
    `offNamed`（`pushReplacementNamed`，只换栈顶）的语义相反；
    `playback/view.dart` 里「返回主页 → `Get.until(isFirst)`」也是错的（代码是
    `Get.back`）。两处注释都改正。
34. `main.dart` 里 `CacheManager.ensureInitialized()` 上方的注释还留着
    「两个实例会互相踩」的警告，而守卫已经去掉了。改成陈述事实。

**查过确认不是问题**

`toPlaybackMediaNamed` 与 `toLiveRoom` 的 `off:true` 分支都显式传了
`preventDuplicates: false`（上一轮那条「连点推荐无反应」确实修好了）；
`PlPlayerController.instance?.dispose()` 替掉 `updatePlayCount()` 方向正确；
`gallery_viewer` 早退后各路径都有 null 判断；`MainFlutterWindow.swift` 的落位
算法与 `closingToken` 自摘顺序都对；播放窗口里 `WindowCloseRequestedEvent`
直接 break 不 cancel 是对的（关窗由 `willClose → windowClosing` 接管）。

**待查实**（不影响上述结论）：`nativeapi` 的 macOS 实现与
`cached_network_image_ce` 的源码都不在 pub 缓存里，无法取证。

### 8.9 macOS Debug 包真的打出来了（此前 §8.2 的结论已被推翻）

§8.2 写的「本环境跑不通」是**当时结论下的过早判断**：当时只试了
`flutter build macos --debug` 的裸跑，失败就归因为「media_kit_video pod 缺
`media_kit_libs_macos_video`」，并没有往下追。实际上那只是**第一层**故障。
用户要求打包试跑后逐层剥开，共 5 层，前 4 层全是仓库/环境既有断裂：

1. **mpv 头文件缺失**（媒体层）
   `media_kit_video/macos/Headers/mpv/*.h` 缺失 ⇒
   `MPVVideoOutParams.swift:23 cannot find type 'mpv_node_list' in scope`、
   `TextureSW.swift:48 cannot find 'MPV_RENDER_API_TYPE_SW' in scope`。
   podspec 用 `system("make -C ../common/darwin …")` 从 github 下 mpv v0.36.0，
   本机无 github.com 连通性 ⇒ 从另一个已带 v0.36.0 头文件的 pub-cache
   checkout 拷进实际解析到的 checkout，再 `pod install`（需
   `export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`，否则 CocoaPods 在含中文的
   路径下报 `Unicode Normalize not appropriate for ASCII-8BIT`）。

2. **Flutter SDK 必须用打过仓库补丁的 3.47.3**（不是 `.fvmrc` 里的 3.47.7）
   `lib/scripts/*.patch` 是给 SDK 打的，而 `lib/scripts/patch.ps1` 是
   PowerShell（CI 用），**本机从来没执行过**。3.47.3 已有 18 个补丁打上，
   但漏了 `double_tap_gesture.patch` ⇒
   `image_double_tap_gesture_recognizer.dart:16 Superclass has no method named 'checkUp'`。
   另外 `pubspec.yaml:24` 钉的 `flutter: 3.47.7` 恰好是删掉了公开
   `TextPainter get textPainter` 的那一版（3.47.2/3.47.3/3.47.5 的
   `rendering/paragraph.dart:393` 都还有，3.47.7 只剩私有的 `_textPainter`），
   ⇒ 仓库钉的 SDK 编译不过自己的代码。

3. **pub-cache 里的 `material_ui` 也必须打补丁**（最大的坑）
   `material_ui` 是 Flutter material 的 **vendored fork**（不是转导出），
   仓库代码 `import 'package:material_ui/material_ui.dart'` 拿的是它自己的
   `lib/src/*.dart`。`StandardBottomSheet` / `BottomSheetState<T>` /
   `BottomSheetDefaultsM3` 全是 `lib/scripts/material/scaffold.patch` 加的
   **公开 typedef**（`+typedef BottomSheetState<T extends BottomSheet> = …`），
   未打补丁的 material_ui 里这三个名字根本不存在 ⇒
   `bottom_sheet.dart` 15 个 `undefined_class` / `extends_non_class`。
   按 `patch.ps1` 的 macOS 分支给 `~/.pub-cache/hosted/pub.dev/material_ui-1.6.0`
   打上 8 个补丁（modal_barrier_material / navigation_drawer / popup_menu /
   fab / text_field / scaffold / refresh_indicator / tabs）后全清。

4. **两处本分支自己的编译错**（已提交 `9db753a88`）
   - `gallery_viewer.dart:516`：`Image(...)` 被同目录 `image.dart` 的同名类
     （Flutter Image 的 fork，额外要 8 个必填参数含 `minScale`）截胡 ⇒
     `Required named parameter 'minScale' must be provided`。这是我自己上一轮
     改出来的，用回同文件注释里本来就在用的 `CachedNetworkImage`。
   - `MainFlutterWindow.swift:212`：`closingToken` 捕获后又被赋值 ⇒
     Swift 6 并发警告。改成 `ObserverTokenBox` 引用类型过一层。

结果：`✓ Built build/macos/Build/Products/Debug/PiliPlus.app`，
本分支的 Swift 代码零警告；adhoc 签名（`com.example.piliplus`）；
`codesign -v` 通过；装在 `/Applications/PiliPlus-debug.app`；
冒烟测试启动存活 18s、无崩溃报告。
