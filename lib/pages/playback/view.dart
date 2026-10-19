import 'package:flutter/material.dart';
import 'package:get/get.dart';

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

/// 播放窗口的悬浮返回按钮。
///
/// 为什么需要它：桌面端视频页没有 AppBar（`VideoDetailPageV.build` 里
/// `removeAppBar` 为真时直接给 null），移动端那个带返回键的
/// `_buildOverlayToolBar` 在桌面又不渲染。于是播放窗口里只剩两条退路 ——
/// 不可发现的 Esc，和标题栏关闭键（后者等于放弃播放）。用户在播放窗口里
/// 打开 UP 页、番剧页之后，按钮上的「返回主页」直接 `Get.until(isFirst)`，
/// 回到哨兵页就把整个窗口关了，压根回不到上一层的 UP 页。
///
/// 显隐由 [PlaybackBridge.routeTick] 驱动：栈里只剩哨兵页时
/// （也就是视频页返回、窗口即将关闭的那一刻）淡出。
class PlaybackBackButton extends StatelessWidget {
  const PlaybackBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: PlaybackBridge.routeTick,
      builder: (context, _, _) {
        final show = Get.key.currentState?.canPop() ?? false;
        return IgnorePointer(
          ignoring: !show,
          child: AnimatedOpacity(
            opacity: show ? 1 : 0,
            duration: const Duration(milliseconds: 150),
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                // 让开原生标题栏，免得两个「返回」叠在一起
                padding: const EdgeInsets.only(top: 8, left: 8),
                child: Material(
                  color: Colors.black.withValues(alpha: 0.45),
                  shape: const CircleBorder(),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: Get.back,
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(
                        Icons.arrow_back_ios_new_rounded,
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
