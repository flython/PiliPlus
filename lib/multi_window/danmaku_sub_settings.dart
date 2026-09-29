import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';

/// 子窗口独立弹幕设置（仅主窗口 engine 使用，工单 07）。
///
/// 渲染类设置与主设置同构但独立存取，持久化在主窗口 Hive
/// （[SettingBoxKey.danmakuSubWindowSettings]）；子窗口 engine 不读
/// Hive，全部经 channel 快照下发。数据类设置（云屏蔽/屏蔽规则）与
/// 「显示弹幕」总开关不做独立，始终跟随主设置。
class DanmakuSubSettings {
  DanmakuSubSettings._();

  static final DanmakuSubSettings i = DanmakuSubSettings._();

  /// 同步主设置：true 时子窗口实时跟随主设置（一期行为），
  /// false 时使用下方独立字段；切换瞬间均以主设置当前值为新内容。
  bool syncWithMain = true;

  // 与主设置同构的渲染类字段；默认值同弹幕设置面板的 reset 值。
  double fontScale = 1.0;
  int fontWeight = 5;
  double showArea = 0.5;
  double duration = 7.0;
  double staticDuration = 4.0;
  double strokeWidth = 1.5;
  double lineHeight = 1.6;
  bool massiveMode = false;
  bool static2Scroll = false;
  bool fixedV = false;

  /// 屏蔽类型（2滚动 4底部 5顶部 7高级）；彩色(6)走主窗口上屏
  /// 着色管线，无法独立，始终跟随主设置。
  Set<int> blockTypes = {};

  double opacity = 1.0;

  static DanmakuSubSettings load() {
    final s = i;
    final m = GStorage.setting.get(SettingBoxKey.danmakuSubWindowSettings);
    if (m is Map) {
      s
        ..syncWithMain = m['syncWithMain'] as bool? ?? true
        ..fontScale = (m['fontScale'] as num?)?.toDouble() ?? 1.0
        ..fontWeight = (m['fontWeight'] as num?)?.toInt() ?? 5
        ..showArea = (m['showArea'] as num?)?.toDouble() ?? 0.5
        ..duration = (m['duration'] as num?)?.toDouble() ?? 7.0
        ..staticDuration = (m['staticDuration'] as num?)?.toDouble() ?? 4.0
        ..strokeWidth = (m['strokeWidth'] as num?)?.toDouble() ?? 1.5
        ..lineHeight = (m['lineHeight'] as num?)?.toDouble() ?? 1.6
        ..massiveMode = m['massiveMode'] as bool? ?? false
        ..static2Scroll = m['static2Scroll'] as bool? ?? false
        ..fixedV = m['fixedV'] as bool? ?? false
        ..blockTypes = ((m['blockTypes'] as List?) ?? const [])
            .whereType<num>()
            .map((e) => e.toInt())
            .toSet()
        ..opacity = (m['opacity'] as num?)?.toDouble() ?? 1.0;
    }
    return s;
  }

  Map<String, Object?> toMap() => {
    'syncWithMain': syncWithMain,
    'fontScale': fontScale,
    'fontWeight': fontWeight,
    'showArea': showArea,
    'duration': duration,
    'staticDuration': staticDuration,
    'strokeWidth': strokeWidth,
    'lineHeight': lineHeight,
    'massiveMode': massiveMode,
    'static2Scroll': static2Scroll,
    'fixedV': fixedV,
    'blockTypes': blockTypes.toList(),
    'opacity': opacity,
  };

  void save() =>
      GStorage.setting.put(SettingBoxKey.danmakuSubWindowSettings, toMap());

  /// 以主设置当前值整体覆盖（切「独立」起点与切回「同步」覆盖共用）。
  void copyFromMain(double mainOpacity) {
    fontScale = DanmakuOptions.danmakuFontScale;
    fontWeight = DanmakuOptions.danmakuFontWeight;
    showArea = DanmakuOptions.danmakuShowArea;
    duration = DanmakuOptions.danmakuDuration;
    staticDuration = DanmakuOptions.danmakuStaticDuration;
    strokeWidth = DanmakuOptions.danmakuStrokeWidth;
    lineHeight = DanmakuOptions.danmakuLineHeight;
    massiveMode = DanmakuOptions.danmakuMassiveMode;
    static2Scroll = DanmakuOptions.danmakuStatic2Scroll;
    fixedV = DanmakuOptions.danmakuFixedV;
    blockTypes = Set.of(DanmakuOptions.blockTypes);
    opacity = mainOpacity;
  }

  /// 与 DanmakuOptions.get 同构（子窗口无全屏概念，仅一套字号）。
  DanmakuOption toOption({required double speed}) => DanmakuOption(
    fontSize: 15 * fontScale,
    fontWeight: fontWeight,
    area: showArea,
    duration: duration / speed,
    staticDuration: staticDuration / speed,
    hideBottom: blockTypes.contains(4),
    hideScroll: blockTypes.contains(2),
    hideTop: blockTypes.contains(5),
    hideSpecial: blockTypes.contains(7),
    strokeWidth: strokeWidth,
    scrollFixedVelocity: fixedV,
    massiveMode: massiveMode,
    static2Scroll: static2Scroll,
    safeArea: true,
    lineHeight: lineHeight,
  );
}
