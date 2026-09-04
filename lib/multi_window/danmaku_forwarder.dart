import 'dart:async';

import 'package:PiliPlus/multi_window/danmaku_codec.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
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

  static void _log(String message) {
    debugPrint('[danmaku-subwindow] forwarder: $message');
  }

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
      _send('opacity', v);
    });
    if (enabled.value) {
      _send('reset', {'cid': cid, 'title': _currentTitle()});
    } else if (Pref.danmakuSeparateWindow) {
      _log('auto reopen separation for new video (remembered on)');
      unawaited(open());
    }
  }

  /// PlDanmaku 卸载时调用；仅当仍是当前上下文时才清空。
  /// 退出播放页时关闭子窗口（记忆开关不变，下次进入视频页由 attach
  /// 自动重开）；切集是同名路由替换，旧挂载者先卸载但仍在视频页内，
  /// 延迟 + 路由判定后不关窗，由新页 attach 走无缝 reset。
  void detach(int cid) {
    if (_cid == cid) {
      _cid = null;
      _player = null;
      _activeReal = null;
      _opacityWorker?.dispose();
      _opacityWorker = null;
      if (enabled.value) {
        _closeTimer?.cancel();
        _closeTimer = Timer(const Duration(seconds: 1), () {
          if (enabled.value &&
              _cid == null &&
              Get.currentRoute != '/videoV') {
            _log('video page exited, closing sub window');
            unawaited(_closeWindow());
          }
        });
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
        if (isActive(real)) _send('option', encodeDanmakuOption(option));
        real.updateOption(option);
      },
      pause: () {
        if (isActive(real)) _send('status', false);
        real.pause();
      },
      resume: () {
        if (isActive(real)) _send('status', true);
        real.resume();
      },
      clear: () {
        if (isActive(real)) _send('clear', null);
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
      final windows = await WindowController.getAll();
      // await 期间可能已被自身 close() 关停，此时窗口注销是预期结果
      if (!enabled.value) return;
      if (windows.length < 2) {
        _log('sub window closed by user, restoring main layer');
        // 用户直接关掉子窗口视为关闭分离模式，记忆开关同步置否
        GStorage.setting.put(SettingBoxKey.danmakuSeparateWindow, false);
        _disable();
      }
    });
    try {
      final controller = await WindowController.create(
        const WindowConfiguration(
          arguments: '{"type":"danmaku"}',
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

  /// 关闭分离模式（设置面板开关）：记忆开关置否，通知子窗口自关。
  Future<void> close() async {
    if (!enabled.value) return;
    GStorage.setting.put(SettingBoxKey.danmakuSeparateWindow, false);
    await _closeWindow();
  }

  Future<void> _closeWindow() async {
    if (!enabled.value) return;
    _log('separation off, closing sub window');
    await _send('exit', null);
    _disable();
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
  /// （含当前option/透明度/状态），直到送达或分离模式关闭。
  Future<void> _sendConfigWithRetry() async {
    var attempt = 0;
    while (enabled.value) {
      attempt++;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final real = _real;
      if (real == null) {
        if (attempt % 25 == 0) {
          _log('config attempt $attempt: danmaku controller not wrapped yet');
        }
        continue;
      }
      final ok = await _send('config', {
        'option': encodeDanmakuOption(real.option),
        'opacity': _player?.danmakuOpacity.value ?? 1.0,
        'isPlaying': _player?.playerStatus.isPlaying ?? false,
        'cid': _cid,
        'title': _currentTitle(),
      });
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
