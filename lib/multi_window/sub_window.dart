import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:PiliPlus/multi_window/danmaku_codec.dart';
import 'package:PiliPlus/multi_window/playback_bridge.dart';
import 'package:PiliPlus/multi_window/window_env.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 子窗口分流（.scratch/danmaku-separate-window、.scratch/playback-separate-window）。
///
/// desktop_multi_window 的子窗口是独立 Flutter engine，与主窗口共用同一
/// main 入口，由 [handleSubWindowLaunch] 依据原生传入的
/// `['multi_window', windowId, arguments]` 参数分流。
///
/// 两类子窗口的能力完全不同：
///  * **弹幕窗口**：纯展示，不跑插件注册，不碰 Hive/网络/路由。子 engine 默认
///    没有注册任何 GeneratedPluginRegistrant，除 desktop_multi_window 自身
///    channel 外任何插件（含 window_manager）均不可用。
///  * **播放窗口**：跑的是完整 app —— 完整 GetX 路由表、完整插件、完整网络栈，
///    只是 Hive 换成内存镜像、initialRoute 换成哨兵页。主窗口永不建 `Player`
///    （media_kit 的事件循环端口是进程级 static，见 feasibility.md §7）。
///
/// 两者都由 `MainFlutterWindow.swift` 的 `onWindowCreatedCallback` 注册
/// `PiliPlus/subwindow` 通道：弹幕窗口只有 `close`，播放窗口另有
/// `setupWindow` / `enablePlugins`。
const _kDanmakuWindowType = 'danmaku';

/// 原生在 `onWindowCreatedCallback` 中为子 engine 注册的通道。
const _subWindowChannel = MethodChannel('PiliPlus/subwindow');

void _log(String message) {
  debugPrint('[subwindow] $message');
}

/// 在 main() 早期调用：当前 engine 是子窗口则返回 true。
///
/// 弹幕窗口在这里 `runApp` 并返回 true；播放窗口只做窗口/插件/快照的准备，
/// 然后返回 false 让 `main()` 继续跑完整 bootstrap。
Future<bool> handleSubWindowLaunch(List<String> args) async {
  if (args.length < 3 || args[0] != 'multi_window') return false;
  final windowId = args[1];

  final Map<String, dynamic> config;
  try {
    config = jsonDecode(args[2]) as Map<String, dynamic>;
  } on FormatException {
    runApp(const _SubWindowErrorPage(reason: '启动参数解析失败'));
    return true;
  }

  switch (config['type']) {
    case _kDanmakuWindowType:
      WindowEnv.kind = WindowKind.danmaku;
      _log('danmaku sub engine launched, windowId=$windowId');
      // 几何/标题由原生按窗口类型装，弹幕窗口和播放窗口走同一条路。
      // 只在 macOS 上要：Windows 的通道只实现了 close。
      // 装不上也不能拖垮弹幕渲染，吞掉即可。
      if (Platform.isMacOS) {
        try {
          await _subWindowChannel.invokeMethod<void>('setupWindow', {
            'type': _kDanmakuWindowType,
          });
        } catch (e) {
          _log('setupWindow failed: $e');
        }
      }
      runApp(
        _DanmakuWindowApp(controller: WindowController.fromWindowId(windowId)),
      );
      return true;
    case kPlaybackWindowType:
      WindowEnv.kind = WindowKind.playback;
      _log('playback engine launched, windowId=$windowId');
      await PlaybackBridge.i.init(
        config['main'] as String,
        kPlaybackWindowType,
      );
      return false;
    default:
      runApp(const _SubWindowErrorPage(reason: '未知的子窗口类型'));
      return true;
  }
}

/// 弹幕分离窗口：纯展示，渲染主窗口转发的弹幕。
/// 主窗口是唯一数据源，这里不拉取任何数据、不做过滤。
class _DanmakuWindowApp extends StatelessWidget {
  const _DanmakuWindowApp({required this.controller});

  final WindowController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: _DanmakuWindowPage(controller: controller),
    );
  }
}

class _DanmakuWindowPage extends StatefulWidget {
  const _DanmakuWindowPage({required this.controller});

  final WindowController controller;

  @override
  State<_DanmakuWindowPage> createState() => _DanmakuWindowPageState();
}

class _DanmakuWindowPageState extends State<_DanmakuWindowPage> {
  DanmakuController<int>? _controller;
  DanmakuOption _option = const DanmakuOption();
  String _title = '';
  int? _cid;
  double _opacity = 1;

  @override
  void initState() {
    super.initState();
    widget.controller.setWindowMethodHandler(_handle);
  }

  @override
  void dispose() {
    widget.controller.setWindowMethodHandler(null);
    super.dispose();
  }

  Future<Object?> _handle(MethodCall call) async {
    _log('danmaku window received: ${call.method}');
    switch (call.method) {
      case 'config':
        final m = call.arguments as Map;
        final option = decodeDanmakuOption(m['option']);
        setState(() {
          _title = m['title'] as String? ?? '';
          _cid = m['cid'] as int?;
          _opacity = (m['opacity'] as num?)?.toDouble() ?? 1;
        });
        _option = option;
        _controller?.updateOption(option);
        if (m['isPlaying'] == false) _controller?.pause();
      case 'reset':
        final m = call.arguments as Map;
        _controller?.clear();
        setState(() {
          _title = m['title'] as String? ?? '';
          _cid = m['cid'] as int?;
        });
      case 'option':
        final option = decodeDanmakuOption(call.arguments);
        _option = option;
        _controller?.updateOption(option);
      case 'status':
        if (call.arguments == true) {
          _controller?.resume();
        } else {
          _controller?.pause();
        }
      case 'opacity':
        setState(() => _opacity = (call.arguments as num).toDouble());
      case 'clear':
        _controller?.clear();
      case 'item':
        _addItem(call.arguments as Map);
      case 'items':
        for (final m in call.arguments as List) {
          _addItem(m as Map);
        }
      case 'exit':
        unawaited(
          _subWindowChannel.invokeMethod<void>('close').catchError((e) {
            _log('close via native channel failed: $e');
          }),
        );
    }
    return null;
  }

  void _addItem(Map m) {
    final controller = _controller;
    if (controller == null) return;
    if (m.containsKey('t')) {
      controller.addDanmaku(decodeDanmakuContent(m));
    } else {
      controller.addDanmaku(decodeSpecialRaw(m));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_title.isNotEmpty || _cid != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(
                _title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = Size(constraints.maxWidth, constraints.maxHeight);
                // 窗口尺寸变化时重建弹幕屏以重算轨道
                return Opacity(
                  opacity: _opacity,
                  child: DanmakuScreen<int>(
                    key: ValueKey(size),
                    createdController: (c) => _controller = c,
                    option: _option,
                    size: size,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SubWindowErrorPage extends StatelessWidget {
  const _SubWindowErrorPage({required this.reason});

  final String reason;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(child: Text('弹幕子窗口错误：$reason')),
      ),
    );
  }
}
