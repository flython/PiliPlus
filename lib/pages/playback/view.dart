import 'package:flutter/material.dart';

import 'package:PiliPlus/multi_window/playback_bridge.dart';

/// 播放窗口的栈底哨兵页。
///
/// 它什么都不渲染，只负责两件事：
///  * 让播放窗口的路由栈有一个底，好让「视频页返回」有明确的落点；
///  * 首帧渲染完就通知 [PlaybackBridge] 可以开始派发 openVideo 了。
class PlaybackRootPage extends StatefulWidget {
  const PlaybackRootPage({super.key});

  static const routeName = '/playback';

  @override
  State<PlaybackRootPage> createState() => _PlaybackRootPageState();
}

class _PlaybackRootPageState extends State<PlaybackRootPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PlaybackBridge.i.markAppReady();
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
