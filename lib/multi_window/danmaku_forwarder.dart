import 'dart:async';

import 'package:PiliPlus/multi_window/danmaku_codec.dart';
import 'package:PiliPlus/multi_window/danmaku_sub_settings.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

/// 弹幕分离窗口转发器（仅主窗口 engine 使用）。
///
/// 主窗口是唯一数据源：不改动现有拉取/过滤/合并/按进度上屏链路，只在
/// DanmakuController 各变更入口（上屏/配置/暂停恢复/清屏）套一层代理，
/// 把同样的调用转发给子窗口；分离模式下主弹幕层隐藏但管线照常运行。
/// 子窗口关闭（用户点红点或 exit）时自动回退，弹幕恢复主窗口显示。
class DanmakuForwarder {
  DanmakuForwarder._();

  static final DanmakuForwarder i = DanmakuForwarder._();

  /// 分离模式开关；主弹幕层的透明度联动此值（见 PlDanmaku.build）。
  final RxBool enabled = false.obs;

  /// 子窗口独立弹幕设置（工单 07）；syncWithMain=true 时子窗口
  /// 实时跟随主设置（一期行为），false 时使用独立值。
  final DanmakuSubSettings subSettings = DanmakuSubSettings.load();

  static void _log(String message) {
    debugPrint('[danmaku-subwindow] forwarder: $message');
  }

  /// config 重试上限：40 次 * 300ms = 12s，超时视为子窗口异常并回收。
  static const int _kConfigMaxAttempts = 40;

  PlPlayerController? _player;
  int? _cid;
  String? Function()? _titleGetter;
  WindowController? _subWindow;
  DanmakuController<DanmakuExtra>? _real;
  DanmakuController<DanmakuExtra>? _activeReal;
  bool _subReady = false;
  final List<Map<String, Object?>> _pendingItems = [];
  StreamSubscription<void>? _windowsSub;
  Worker? _opacityWorker;
  Timer? _closeTimer;

  bool get _shouldForward => enabled.value && _subReady;

  bool get _syncWithMain => subSettings.syncWithMain;

  int _forwardedCount = 0;

  /// PlDanmaku 挂载时注册当前播放上下文（不论是否处于分离模式）。
  /// 分离模式下新挂载即下发 reset：子窗口清屏并跟随最新管线。
  /// 上次为分离态（记忆开关）时，新视频页自动重新进入分离模式。
  void attach(
    PlPlayerController player,
    int cid, {
    String? Function()? titleGetter,
  }) {
    _player = player;
    _cid = cid;
    if (titleGetter != null) _titleGetter = titleGetter;
    _closeTimer?.cancel();
    _closeTimer = null;
    _opacityWorker?.dispose();
    _opacityWorker = ever<double>(player.danmakuOpacity, (v) {
      // 就绪前丢弃（config 快照已带 opacity）；独立模式下主透明度不下发
      if (_subReady && _syncWithMain) _send('opacity', v);
    });
    if (enabled.value) {
      if (_subReady) {
        _send('reset', {'cid': cid, 'title': _currentTitle()});
      }
      // 未就绪时 reset 省略：config 重试快照已含 cid/title
    } else if (Pref.danmakuSeparateWindow) {
      _log('auto reopen separation for new video (remembered on)');
      unawaited(open());
    }
  }

  /// PlDanmaku 卸载时调用；仅当仍是当前上下文时才清空。
  /// 退出播放页立即关闭子窗口（记忆开关不变，下次进入视频页由 attach
  /// 自动重开）；切集是同名路由替换，旧挂载者先卸载但仍在视频页内，
  /// 不关窗，由新页 attach 走无缝 reset。
  void detach(int cid) {
    if (_cid == cid) {
      _cid = null;
      _player = null;
      _activeReal = null;
      _opacityWorker?.dispose();
      _opacityWorker = null;
      if (enabled.value) {
        _closeTimer?.cancel();
        if (Get.currentRoute != '/videoV') {
          _log('video page exited, closing sub window');
          unawaited(_teardownWindow());
        } else {
          // 仍在视频页：等待新挂载者 attach 接管（attach 会取消本定时器）；
          // 300ms 兜底复查，防 dispose 与路由更新时序反常导致窗口滞留
          _closeTimer = Timer(const Duration(milliseconds: 300), () {
            if (enabled.value &&
                _cid == null &&
                Get.currentRoute != '/videoV') {
              _log('video page exited (fallback), closing sub window');
              unawaited(_teardownWindow());
            }
          });
        }
      }
    }
  }

  String _currentTitle() {
    final getter = _titleGetter;
    if (getter == null) return '';
    try {
      return getter() ?? '';
    } catch (_) {
      return '';
    }
  }

  DanmakuOption _subOption() =>
      subSettings.toOption(speed: _player?.playbackSpeed ?? 1.0);

  /// 下发子窗口的配置快照；option/opacity 来源随同步模式切换。
  Map<String, Object?> _configPayload() {
    final speed = _player?.playbackSpeed ?? 1.0;
    return {
      'option': encodeDanmakuOption(
        _syncWithMain
            ? _real?.option ??
                  DanmakuOptions.get(notFullscreen: true, speed: speed)
            : subSettings.toOption(speed: speed),
      ),
      'opacity': _syncWithMain
          ? (_player?.danmakuOpacity.value ?? 1.0)
          : subSettings.opacity,
      'isPlaying': _player?.playerStatus.isPlaying ?? false,
      'cid': _cid,
      'title': _currentTitle(),
    };
  }

  /// 「同步主设置」开关（设置面板子窗口区块）。切换瞬间以主设置当前值
  /// 为新内容（工单 07）：切独立=复制起点，切回同步=覆盖子窗口。
  Future<void> setSyncWithMain(bool sync) async {
    if (subSettings.syncWithMain == sync) return;
    subSettings.syncWithMain = sync;
    subSettings.copyFromMain(_player?.danmakuOpacity.value ?? 1.0);
    subSettings.save();
    _log('sub settings sync switched to $sync');
    if (enabled.value && _subReady) {
      await _send('config', _configPayload());
    }
  }

  /// 独立设置项变更后调用（设置面板）：持久化并即时下发。
  Future<void> applySubSettings() async {
    subSettings.save();
    if (enabled.value && !_syncWithMain && _subReady) {
      await _send('config', _configPayload());
    }
  }

  /// 包装真实控制器：所有变更先转发再透传。
  /// 多个 PlDanmaku 实例并存时只有最新一个转发（与主窗口
  /// playerController.danmakuController 的“最新挂载者生效”语义一致）。
  DanmakuController<DanmakuExtra> wrap(DanmakuController<DanmakuExtra> real) {
    _log('danmaku controller wrapped');
    _real = real;
    _activeReal = real;
    bool isActive(DanmakuController<DanmakuExtra> c) =>
        identical(_activeReal, c);
    return DanmakuController<DanmakuExtra>(
      addDanmaku: (item) {
        if (item is! SpecialDanmakuContentItem<DanmakuExtra> &&
            isActive(real)) {
          _sendItem(encodeDanmakuContent(item));
        }
        return real.addDanmaku(item);
      },
      updateOption: (option) {
        if (isActive(real) && _subReady) {
          if (_syncWithMain) {
            _send('option', encodeDanmakuOption(option));
          } else {
            // 独立模式：主屏 option 键变化（倍速/全屏切换等）时按独立
            // 设置重算下发；主设置改动触发的调用重算结果不变，等效 no-op
            _send('option', encodeDanmakuOption(_subOption()));
          }
        }
        real.updateOption(option);
      },
      pause: () {
        if (isActive(real) && _subReady) _send('status', false);
        real.pause();
      },
      resume: () {
        if (isActive(real) && _subReady) _send('status', true);
        real.resume();
      },
      clear: () {
        if (isActive(real) && _subReady) _send('clear', null);
        real.clear();
      },
      getOption: real.getOption,
      isRunning: real.isRunning,
      findDanmaku: real.findDanmaku,
      findSingleDanmaku: real.findSingleDanmaku,
      getTrackCount: real.getTrackCount,
      scrollDanmaku: real.scrollDanmaku,
      staticDanmaku: real.staticDanmaku,
      specialDanmaku: real.specialDanmaku,
    );
  }

  /// 高级弹幕（mode 7）的原始内容只有 PlDanmaku 上屏点拿得到，
  /// 由 view.dart 在构造 SpecialDanmakuContentItem 前调用；
  /// cid 用来区分并存的新旧挂载实例，只有当前集的才转发。
  void forwardSpecial({
    required int cid,
    required int color,
    required double fontSize,
    required List content,
  }) {
    if (_cid != cid) return;
    _sendItem(encodeSpecialRaw(color, fontSize, content));
  }

  /// getAll 结果里是否存在弹幕型子窗口（主窗口 arguments 为空串）。
  Future<bool> _hasSubWindow() async {
    try {
      final windows = await WindowController.getAll();
      return windows.any((w) => w.arguments == kDanmakuWindowArgs);
    } catch (e) {
      _log('getAll failed: $e');
      return false;
    }
  }

  /// 开启分离模式：隐藏主弹幕层并创建子窗口，就绪后下发配置快照。
  /// 标题取值器由 attach 注入（PlDanmaku 挂载必然先于本调用）。
  Future<void> open() async {
    if (enabled.value) return;
    _subReady = false;
    _pendingItems.clear();
    enabled.value = true;
    GStorage.setting.put(SettingBoxKey.danmakuSeparateWindow, true);
    _log('separation on, creating danmaku window');
    _windowsSub = onWindowsChanged.listen((_) async {
      if (!enabled.value) return;
      final hasSub = await _hasSubWindow();
      // await 期间可能已被自身 close() 关停，此时窗口注销是预期结果
      if (!enabled.value) return;
      if (!hasSub) {
        _log('sub window closed by user, restoring main layer');
        // 用户直接关掉子窗口视为关闭分离模式，记忆开关同步置否
        GStorage.setting.put(SettingBoxKey.danmakuSeparateWindow, false);
        _disable();
      }
    });
    try {
      final controller = await WindowController.create(
        const WindowConfiguration(
          arguments: kDanmakuWindowArgs,
          hiddenAtLaunch: false,
        ),
      );
      _subWindow = controller;
      await controller.show();
    } catch (e) {
      _log('create sub window failed: $e');
      _disable();
      return;
    }
    unawaited(_sendConfigWithRetry());
  }

  /// 关闭分离模式（设置面板开关）：记忆开关置否，销毁子窗口。
  Future<void> close() async {
    if (!enabled.value) return;
    GStorage.setting.put(SettingBoxKey.danmakuSeparateWindow, false);
    _log('separation off via settings toggle');
    await _teardownWindow();
  }

  /// 程序主动关窗（退出播放页 / 设置面板关闭 / config 超时回收）。
  /// 先 _disable() 再发 exit：open() 的 windowsChanged 监听会把"窗口消失"
  /// 视为用户手关并清除记忆开关，主动关窗必须先短路该回调，只关窗口、
  /// 不动「跨会话记忆」——下次进视频页由 attach 自动重开。
  /// exit 直接走 controller.invokeMethod：_send 以 enabled 为门卫且
  /// _disable 已将其置否，上轮修复曾因此让 exit 发不出去，窗口滞留、
  /// 重开后双窗口（回归 bug）。_subWindow 引用在 _disable 前捕获。
  Future<void> _teardownWindow() async {
    if (!enabled.value) return;
    _log('teardown: closing sub window (memory switch untouched)');
    final controller = _subWindow;
    _disable();
    if (controller == null) return;
    for (var attempt = 1; attempt <= 10; attempt++) {
      try {
        await controller.invokeMethod('exit', null);
      } on WindowChannelException catch (e) {
        _log('exit send failed (attempt $attempt): ${e.message}');
      }
      if (!await _hasSubWindow()) break;
      if (attempt == 10) {
        _log('sub window still alive after exit retries, giving up');
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  void _disable() {
    if (!enabled.value) return;
    enabled.value = false;
    _subReady = false;
    _pendingItems.clear();
    _closeTimer?.cancel();
    _closeTimer = null;
    _log('disabled, total forwarded this session: $_forwardedCount');
    _windowsSub?.cancel();
    _windowsSub = null;
    _subWindow = null;
  }

  /// 子窗口就绪前拿不到 handler，持续重试下发配置快照
  /// （含当前option/透明度/状态），直到送达、分离模式关闭或超时。
  Future<void> _sendConfigWithRetry() async {
    var attempt = 0;
    while (enabled.value && attempt < _kConfigMaxAttempts) {
      attempt++;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final real = _real;
      if (real == null) {
        if (attempt % 25 == 0) {
          _log('config attempt $attempt: danmaku controller not wrapped yet');
        }
        continue;
      }
      final ok = await _send('config', _configPayload());
      if (ok) {
        _log('config delivered on attempt $attempt, flushing ${_pendingItems.length} pending items');
        _subReady = true;
        if (_pendingItems.isNotEmpty) {
          final batch = List<Map<String, Object?>>.from(_pendingItems);
          _pendingItems.clear();
          await _send('items', batch);
        }
        return;
      }
    }
    if (enabled.value) {
      _log('config delivery timed out after $attempt attempts, tearing down');
      await _teardownWindow();
    }
  }

  void _sendItem(Map<String, Object?> payload) {
    if (!_shouldForward) {
      if (enabled.value && !_subReady) {
        // 子窗口初始化期间的上屏先缓冲，就绪后补发
        if (_pendingItems.length < 500) _pendingItems.add(payload);
      }
      return;
    }
    _forwardedCount++;
    if (_forwardedCount == 1 || _forwardedCount % 100 == 0) {
      _log('danmaku items forwarded: $_forwardedCount');
    }
    unawaited(_send('item', payload));
  }

  Future<bool> _send(String method, Object? payload) async {
    if (!enabled.value) return false;
    final controller = _subWindow;
    if (controller == null) {
      _log('send "$method" skipped: no sub window');
      return false;
    }
    try {
      await controller.invokeMethod(method, payload);
      return true;
    } on WindowChannelException catch (e) {
      if (method != 'config') {
        _log('send "$method" failed, sub window is gone: ${e.message}');
        _disable();
      } else {
        _log('send "config" failed: ${e.code} ${e.message}');
      }
      return false;
    }
  }
}
