// 只 import 叶子文件：`storage_mirror.dart` / `playback_window.dart` 会拖进
// `GStorage` 那一串 widget 依赖，而 `text_ellipsis`/`text_more` 两个 widget
// 在 Flutter 3.47.x 上编译不过（`RenderParagraph.textPainter` 已被改成私有
// `_textPainter`，与本次改动无关）。
import 'package:PiliPlus/models/common/video/source_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/multi_window/playback_args.dart';
import 'package:PiliPlus/multi_window/window_env.dart';
import 'package:PiliPlus/utils/hive_codec.dart';
import 'package:PiliPlus/utils/memory_box.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MemoryBox', () {
    test('读回刚写进去的值，不走 onWrite 回环', () {
      final writes = <String>[];
      final box = MemoryBox<String>(
        'setting',
        onWrite: (b, k, v) {
          writes.add('$b/$k=$v');
        },
      )..put('k', 'v');

      expect(box.get('k'), 'v');
      expect(writes, ['setting/k=v']);
    });

    test('删除会转发 null', () {
      final writes = <String>[];
      final box =
          MemoryBox<String>(
              'setting',
              onWrite: (b, k, v) {
                writes.add('$b/$k=$v');
              },
            )
            ..put('k', 'v')
            ..delete('k');

      expect(box.get('k'), isNull);
      expect(writes.last, 'setting/k=null');
    });

    test('applySnapshot 灌入的值不会被当成写入', () {
      final writes = <String>[];
      final box = MemoryBox<String>(
        'setting',
        onWrite: (b, k, v) {
          writes.add('$b/$k=$v');
        },
      )..applySnapshot({'a': '1', 'b': '2'});

      expect(box.toMap(), {'a': '1', 'b': '2'});
      expect(writes, isEmpty);
    });

    test('applySnapshot 覆盖旧内容', () {
      final box = MemoryBox<String>('setting')
        ..put('a', '1')
        ..applySnapshot({'b': '2'});

      expect(box.toMap(), {'b': '2'});
    });

    test('watch 能收到 put 事件', () async {
      final box = MemoryBox<String>('setting');
      final events = <String>[];
      final sub = box.watch().listen((e) => events.add('${e.key}'));

      box.put('k', 'v');
      await Future.delayed(Duration.zero);

      expect(events, ['k']);
      await sub.cancel();
    });

    // 回归：clear() 早期版本只清本地镜像不转发，主引擎盘上数据还在，
    // 下次启动快照一灌就「复活」，用户以为清掉的搜索历史又回来了。
    test('clear 会把每个 key 以 null 转发出去', () async {
      final writes = <String>[];
      final box =
          MemoryBox<String>(
              'historyWord',
              onWrite: (b, k, v) {
                writes.add('$b/$k=$v');
              },
            )
            ..put('a', '1')
            ..put('b', '2');
      writes.clear();

      await box.clear();

      expect(box.toMap(), isEmpty);
      expect(writes, ['historyWord/a=null', 'historyWord/b=null']);
    });

    // 回归：add() 早期版本永远从 0 开始排，会盖掉快照里已有的 0..N 条
    // （historyWord / video 就是这么存的）。
    test('applySnapshot 后 add 从已有数字键之后接着排', () async {
      final box = MemoryBox<String>('historyWord')
        ..applySnapshot({0: '旧0', 1: '旧1'});

      final key = await box.add('新');

      expect(key, 2);
      expect(box.toMap(), {0: '旧0', 1: '旧1', 2: '新'});
    });

    test('空快照后 add 从 0 开始', () async {
      final box = MemoryBox<String>('historyWord')..applySnapshot({});

      expect(await box.add('新'), 0);
    });
  });

  group('存储镜像编解码', () {
    // 这里只用 String 这种内建类型，不需要注册自定义 adapter。
    // 生产路径里两端各自跑 GStorage.regAdapter()，typeId 才能对上。

    test('box 编码后能原样解回', () {
      final source = {'a': '1', 'b': 'hello', 'c': '中文'};

      final decoded = decodeBox(encodeBox(source));

      expect(decoded, source);
    });

    test('空 box 也能往返', () {
      expect(decodeBox(encodeBox(<dynamic, dynamic>{})), <dynamic, dynamic>{});
    });

    test('null value 的写入能往返', () {
      final decoded = decodeEntry(encodeEntry('k', null));

      expect(decoded, ['k', null]);
    });

    test('单条写入能往返', () {
      final decoded = decodeEntry(encodeEntry('k', 'v'));

      expect(decoded, ['k', 'v']);
    });
  });

  group('播放窗口参数', () {
    test('主窗口 id 被写进 arguments', () {
      final args = buildPlaybackWindowArgs('7');

      expect(args, contains('"type":"playback"'));
      expect(args, contains('"main":"7"'));
    });

    test('能识别自己的 arguments', () {
      expect(isPlaybackWindowArguments(buildPlaybackWindowArgs('7')), isTrue);
    });

    test('主窗口与弹幕窗口的 arguments 不会被误判', () {
      expect(isPlaybackWindowArguments(''), isFalse);
      expect(isPlaybackWindowArguments('{"type":"danmaku"}'), isFalse);
      expect(isPlaybackWindowArguments(null), isFalse);
    });
  });

  group('播放参数过平台通道', () {
    // 真实事故：StandardMessageCodec 只认 bool/double/int/String/
    // Uint8List/List/Map，enum 过去就抛
    // `Invalid argument: Instance of 'VideoType'`，
    // 而 toVideoPage 的 arguments 必然带 videoType
    // ⇒ 播放窗口第一次打开就派发失败，冒「播放窗口打不开」。
    test('enum 编成 name 能在对端原样还原', () {
      final decoded = decodePlaybackArguments(
        encodePlaybackArguments({
          'videoType': VideoType.pgc,
          'sourceType': SourceType.watchLater,
        }),
      );

      expect(decoded['videoType'], VideoType.pgc);
      expect(decoded['sourceType'], SourceType.watchLater);
    });

    test('编出来的 Map 全是 codec 认的类型', () {
      final encoded = encodePlaybackArguments({
        'videoType': VideoType.ugc,
        'bvid': 'BV1xx',
        'cid': 123,
        'isVertical': false,
        'title': null,
      });

      for (final v in encoded.values) {
        expect(
          v == null ||
              v is bool ||
              v is num ||
              v is String ||
              v is List ||
              v is Map,
          isTrue,
          reason: '${v.runtimeType} 过不了平台通道',
        );
      }
    });

    test('codec 传不了的值当场报错并点名是哪个键', () {
      expect(
        () => encodePlaybackArguments({'weird': Object()}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('weird'),
          ),
        ),
      );
    });

    test('enum 用 name 而不是 index：重排后仍取到同一个值', () {
      final encoded = encodePlaybackArguments({'videoType': VideoType.pgc});

      expect(encoded['videoType'], 'pgc');
    });
  });
}
