import 'dart:typed_data';

import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';

/// 播放参数里唯一两个 enum 键。
///
/// 不用猜：全仓 `PageUtils.toVideoPage` 的 arguments map 里，
/// `videoType` 由它自己塞，`sourceType` 由 later / fav / member /
/// download / scheme 五处 `extraArguments` 塞，
/// 其余键（bvid/cid/cover/heroTag/progress/isVertical/oid/count…）
/// 全是 int/String/bool。
final _argumentEnums = <String, List<Enum>>{
  'videoType': VideoType.values,
  'sourceType': SourceType.values,
};

/// 平台通道的 `StandardMessageCodec` 只认
/// bool/double/int/String/Uint8List/List/Map（`message_codecs.dart:386-464`），
/// Dart enum 传过去直接抛 `Invalid argument: Instance of 'VideoType'`，
/// 而 arguments 必然带 `videoType` ⇒ 播放窗口第一次打开就派发失败。
///
/// 用 `name` 而不是 `index` 编码：枚举重排后 `index` 会静默取到另一个值，
/// `firstWhere` 是当场报错。
/// 播放窗口的路由参数。视频页传的是 `Map`（`PageUtils.toVideoPage`），
/// 直播页传的是裸 `int roomId`（`PageUtils.toLiveRoom`），所以签名收 `dynamic`。
///
/// 之前签名写死 `Map<dynamic, dynamic>`，直播的裸 int 会在调用点当场抛
/// `type 'int' is not a subtype of type 'Map<dynamic, dynamic>'`，主引擎把
/// 每次点击重试满 10s 预算后报「播放窗口打不开」—— 直播页在播放窗口里
/// 从来没打开过。
dynamic encodePlaybackArguments(dynamic args) {
  // 非 Map（直播的 roomId）走平台通道的 StandardMessageCodec 原生支持：
  // bool/int/double/String/List/Uint8List/Map 都能过，原样返回即可。
  if (args is! Map) {
    if (args != null &&
        args is! bool &&
        args is! num &&
        args is! String &&
        args is! List &&
        args is! Uint8List) {
      throw ArgumentError(
        '播放窗口没法通过平台通道传 arguments（类型 ${args.runtimeType}）',
      );
    }
    return args;
  }
  final out = <String, dynamic>{};
  for (final entry in args.entries) {
    final key = '${entry.key}';
    final value = entry.value;
    if (value is Enum) {
      out[key] = value.name;
    } else if (value != null &&
        value is! bool &&
        value is! num &&
        value is! String &&
        value is! List &&
        value is! Map) {
      // 不自己拦的话，错误只剩 codec 抛的一个实例名，
      // 看不出是哪个键、什么东西传不过去。
      throw ArgumentError(
        '播放窗口没法通过平台通道传 $key（类型 ${value.runtimeType}）',
      );
    } else {
      out[key] = value;
    }
  }
  return out;
}

/// [encodePlaybackArguments] 的逆运算。
dynamic decodePlaybackArguments(dynamic raw) {
  if (raw is! Map) return raw;
  final out = <dynamic, dynamic>{...raw};
  for (final entry in _argumentEnums.entries) {
    final name = out[entry.key];
    if (name is String) {
      out[entry.key] = entry.value.firstWhere((e) => e.name == name);
    }
  }
  return out;
}
