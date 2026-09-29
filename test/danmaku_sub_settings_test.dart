import 'dart:io';

import 'package:PiliPlus/multi_window/danmaku_sub_settings.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  setUpAll(() async {
    // Pref 类静态加载即取 GStorage.setting，须先注入测试 box
    Hive.init(
      Directory.systemTemp
          .createTempSync('piliplus_danmaku_sub_settings')
          .path,
    );
    GStorage.setting = await Hive.openBox('setting');
  });

  group('DanmakuSubSettings', () {
    test('默认同步主设置', () {
      expect(DanmakuSubSettings.i.syncWithMain, isTrue);
    });

    test('copyFromMain 与主设置一致且 blockTypes 深拷贝', () {
      DanmakuOptions.danmakuFontScale = 1.5;
      DanmakuOptions.danmakuFontWeight = 7;
      DanmakuOptions.danmakuShowArea = 0.8;
      DanmakuOptions.danmakuDuration = 9.0;
      DanmakuOptions.danmakuStaticDuration = 5.0;
      DanmakuOptions.danmakuStrokeWidth = 2.0;
      DanmakuOptions.danmakuLineHeight = 2.0;
      DanmakuOptions.danmakuMassiveMode = true;
      DanmakuOptions.danmakuStatic2Scroll = true;
      DanmakuOptions.danmakuFixedV = true;
      DanmakuOptions.blockTypes
        ..clear()
        ..addAll({2, 5});

      final sub = DanmakuSubSettings.i;
      sub.syncWithMain = false;
      sub.copyFromMain(0.6);

      expect(sub.fontScale, 1.5);
      expect(sub.fontWeight, 7);
      expect(sub.showArea, 0.8);
      expect(sub.duration, 9.0);
      expect(sub.staticDuration, 5.0);
      expect(sub.strokeWidth, 2.0);
      expect(sub.lineHeight, 2.0);
      expect(sub.massiveMode, isTrue);
      expect(sub.static2Scroll, isTrue);
      expect(sub.fixedV, isTrue);
      expect(sub.blockTypes, {2, 5});
      expect(sub.opacity, 0.6);

      // 深拷贝：改子窗口集合不影响主设置
      sub.blockTypes.add(4);
      expect(DanmakuOptions.blockTypes.contains(4), isFalse);
    });

    test('copyFromMain 后 toOption 与主 get(notFullscreen: true) 同构', () {
      final sub = DanmakuSubSettings.i;
      sub.copyFromMain(1.0);
      for (final speed in <double>[1.0, 2.0]) {
        final main = DanmakuOptions.get(notFullscreen: true, speed: speed);
        final subOption = sub.toOption(speed: speed);
        expect(subOption.fontSize, main.fontSize);
        expect(subOption.fontWeight, main.fontWeight);
        expect(subOption.area, main.area);
        expect(subOption.duration, main.duration);
        expect(subOption.staticDuration, main.staticDuration);
        expect(subOption.hideTop, main.hideTop);
        expect(subOption.hideBottom, main.hideBottom);
        expect(subOption.hideScroll, main.hideScroll);
        expect(subOption.hideSpecial, main.hideSpecial);
        expect(subOption.strokeWidth, main.strokeWidth);
        expect(subOption.scrollFixedVelocity, main.scrollFixedVelocity);
        expect(subOption.massiveMode, main.massiveMode);
        expect(subOption.static2Scroll, main.static2Scroll);
        expect(subOption.lineHeight, main.lineHeight);
      }
    });

    test('toOption 时长按倍速折算', () {
      final sub = DanmakuSubSettings.i;
      sub.syncWithMain = false;
      sub.duration = 10.0;
      sub.staticDuration = 4.0;
      final o = sub.toOption(speed: 2.0);
      expect(o.duration, 5.0);
      expect(o.staticDuration, 2.0);
    });

    test('save/load 往返', () {
      final sub = DanmakuSubSettings.i;
      sub
        ..syncWithMain = false
        ..fontScale = 1.8
        ..fontWeight = 3
        ..showArea = 0.3
        ..duration = 12.0
        ..staticDuration = 6.0
        ..strokeWidth = 0.5
        ..lineHeight = 1.2
        ..massiveMode = true
        ..static2Scroll = true
        ..fixedV = true
        ..blockTypes = {4, 7}
        ..opacity = 0.4
        ..save();

      final restored = DanmakuSubSettings.load();
      expect(restored.syncWithMain, isFalse);
      expect(restored.fontScale, 1.8);
      expect(restored.fontWeight, 3);
      expect(restored.showArea, 0.3);
      expect(restored.duration, 12.0);
      expect(restored.staticDuration, 6.0);
      expect(restored.strokeWidth, 0.5);
      expect(restored.lineHeight, 1.2);
      expect(restored.massiveMode, isTrue);
      expect(restored.static2Scroll, isTrue);
      expect(restored.fixedV, isTrue);
      expect(restored.blockTypes, {4, 7});
      expect(restored.opacity, 0.4);
    });
  });
}
