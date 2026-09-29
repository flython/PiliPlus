import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart' show Color;

/// 弹幕分离窗口的跨 engine 编解码。
///
/// 子窗口 engine 不加载 PiliPlus 业务代码，只依赖 canvas_danmaku，
/// 因此弹幕配置与弹幕条目都以 plain map 过通道。

/// 子窗口的 WindowConfiguration.arguments 原文；主窗口用它从
/// getAll 结果里识别弹幕子窗口（子窗口自身在 sub_window.dart 依据
/// config['type'] 分流）。
const String kDanmakuWindowArgs = '{"type":"danmaku"}';

Map<String, Object?> encodeDanmakuOption(DanmakuOption o) => {
  'fontSize': o.fontSize,
  'fontWeight': o.fontWeight,
  'area': o.area,
  'duration': o.duration,
  'staticDuration': o.staticDuration,
  'hideTop': o.hideTop,
  'hideBottom': o.hideBottom,
  'hideScroll': o.hideScroll,
  'hideSpecial': o.hideSpecial,
  'strokeWidth': o.strokeWidth,
  'scrollFixedVelocity': o.scrollFixedVelocity,
  'massiveMode': o.massiveMode,
  'static2Scroll': o.static2Scroll,
  'safeArea': o.safeArea,
  'lineHeight': o.lineHeight,
};

DanmakuOption decodeDanmakuOption(Map<dynamic, dynamic> m) => DanmakuOption(
  fontSize: (m['fontSize'] as num).toDouble(),
  fontWeight: m['fontWeight'] as int,
  area: (m['area'] as num).toDouble(),
  duration: (m['duration'] as num).toDouble(),
  staticDuration: (m['staticDuration'] as num).toDouble(),
  hideTop: m['hideTop'] as bool,
  hideBottom: m['hideBottom'] as bool,
  hideScroll: m['hideScroll'] as bool,
  hideSpecial: m['hideSpecial'] as bool,
  strokeWidth: (m['strokeWidth'] as num).toDouble(),
  scrollFixedVelocity: m['scrollFixedVelocity'] as bool,
  massiveMode: m['massiveMode'] as bool,
  static2Scroll: m['static2Scroll'] as bool,
  safeArea: m['safeArea'] as bool,
  lineHeight: (m['lineHeight'] as num).toDouble(),
);

/// 普通弹幕条目（高级弹幕走 [encodeSpecialRaw]/[decodeSpecialRaw]，
/// 因为构造后的 SpecialDanmakuContentItem 不再保留原始内容列表）。
Map<String, Object?> encodeDanmakuContent(DanmakuContentItem<dynamic> it) => {
  't': it.text,
  'c': it.color.toARGB32(),
  'ty': it.type.index,
  'ss': it.selfSend,
  'cf': it.isColorful,
  if (it.count != null) 'n': it.count,
};

DanmakuContentItem<int> decodeDanmakuContent(Map<dynamic, dynamic> m) =>
    DanmakuContentItem<int>(
      m['t'] as String,
      color: Color(m['c'] as int),
      type: DanmakuItemType.values[m['ty'] as int],
      selfSend: m['ss'] as bool,
      isColorful: m['cf'] as bool,
      count: m['n'] as int?,
    );

Map<String, Object?> encodeSpecialRaw(int color, double fontSize, List list) =>
    {'c': color, 'fs': fontSize, 'j': list};

SpecialDanmakuContentItem<int> decodeSpecialRaw(Map<dynamic, dynamic> m) =>
    SpecialDanmakuContentItem<int>.fromList(
      Color(m['c'] as int),
      (m['fs'] as num).toDouble(),
      m['j'] as List,
    );
