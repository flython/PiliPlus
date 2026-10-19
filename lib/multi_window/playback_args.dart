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
Map<String, dynamic> encodePlaybackArguments(Map<dynamic, dynamic> args) {
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
Map<dynamic, dynamic> decodePlaybackArguments(Map<dynamic, dynamic>? raw) {
  final out = <dynamic, dynamic>{...?raw};
  for (final entry in _argumentEnums.entries) {
    final name = out[entry.key];
    if (name is String) {
      out[entry.key] = entry.value.firstWhere((e) => e.name == name);
    }
  }
  return out;
}
