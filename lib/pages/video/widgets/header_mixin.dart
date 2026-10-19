import 'dart:io' show Platform;

import 'package:PiliPlus/common/widgets/button/icon_button.dart';
import 'package:PiliPlus/multi_window/danmaku_forwarder.dart';
import 'package:PiliPlus/multi_window/window_env.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/menu_row.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

mixin HeaderMixin<T extends StatefulWidget> on State<T> {
  PlPlayerController get plPlayerController;

  bool get isFullScreen => plPlayerController.isFullScreen.value;

  ThemeData? get theme {
    if (plPlayerController.darkVideoPage) {
      return ThemeUtils.darkTheme;
    }
    return null;
  }

  Future<void>? showBottomSheet(
    StatefulWidgetBuilder builder, {
    ValueGetter<EdgeInsets>? padding,
  }) {
    final theme = this.theme;
    return PageUtils.showVideoBottomSheet(
      context,
      maxWidth: 512,
      padding: padding,
      child: theme != null
          ? Theme(
              data: theme,
              child: StatefulBuilder(builder: builder),
            )
          : StatefulBuilder(builder: builder),
    );
  }

  Widget resetBtn(ThemeData theme, Object def, VoidCallback onPressed) {
    return iconButton(
      tooltip: '默认值: $def',
      icon: const Icon(Icons.refresh),
      onPressed: onPressed,
      iconColor: theme.colorScheme.outline,
      size: 24,
      iconSize: 24,
    );
  }

  /// 弹幕功能
  void showSetDanmaku({bool isLive = false}) {
    // 屏蔽类型
    const blockTypesList = [
      (value: 2, label: '滚动'),
      (value: 5, label: '顶部'),
      (value: 4, label: '底部'),
      (value: 6, label: '彩色'),
      (value: 7, label: '高级'),
    ];

    final danmakuController = plPlayerController.danmakuController;

    final isFullScreen = this.isFullScreen;

    showBottomSheet(
      (context, setState) {
        final theme = Theme.of(context);

        void setOptions() => danmakuController?.updateOption(
          DanmakuOptions.get(
            notFullscreen: !isFullScreen,
            speed: plPlayerController.playbackSpeed,
          ),
        );

        const EdgeInsets sliderPadding = .symmetric(vertical: 16);

        final sliderTheme = SliderThemeData(
          trackHeight: 10,
          padding: const .symmetric(horizontal: 6),
          trackShape: const MSliderTrackShape(),
          thumbColor: theme.colorScheme.primary,
          activeTrackColor: theme.colorScheme.primary,
          inactiveTrackColor: theme.colorScheme.onInverseSurface,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
        );

        void updateLineHeight(double val) {
          DanmakuOptions.danmakuLineHeight = val.toPrecision(1);
          setState(() {});
          setOptions();
        }

        void updateDuration(double val) {
          DanmakuOptions.danmakuDuration = val.toPrecision(1);
          setState(() {});
          setOptions();
        }

        void updateStaticDuration(double val) {
          DanmakuOptions.danmakuStaticDuration = val.toPrecision(1);
          setState(() {});
          setOptions();
        }

        void updateFontSizeFS(double val) {
          DanmakuOptions.danmakuFontScaleFS = val.toPrecision(2);
          setState(() {});
          if (isFullScreen) {
            setOptions();
          }
        }

        void updateFontSize(double val) {
          DanmakuOptions.danmakuFontScale = val.toPrecision(2);
          setState(() {});
          if (!isFullScreen) {
            setOptions();
          }
        }

        void updateStrokeWidth(double val) {
          DanmakuOptions.danmakuStrokeWidth = val;
          setState(() {});
          setOptions();
        }

        void updateFontWeight(double val) {
          DanmakuOptions.danmakuFontWeight = val.toInt();
          setState(() {});
          setOptions();
        }

        void updateOpacity(double val) {
          plPlayerController.danmakuOpacity.value = val.toPrecision(2);
          setState(() {});
        }

        void updateShowArea(double val) {
          DanmakuOptions.danmakuShowArea = val.toPrecision(1);
          setState(() {});
          setOptions();
        }

        void updateDanmakuWeight(double val) {
          DanmakuOptions.danmakuWeight = val.toInt();
          setState(() {});
        }

        void onUpdateBlockType(int blockType, bool blocked) {
          if (blocked) {
            DanmakuOptions.blockTypes.remove(blockType);
          } else {
            DanmakuOptions.blockTypes.add(blockType);
          }
          DanmakuOptions.blockColorful = DanmakuOptions.blockTypes.contains(6);
          setState(() {});
          setOptions();
        }

        return Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            clipBehavior: Clip.hardEdge,
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: SliderTheme(
                data: sliderTheme,
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    const SizedBox(
                      height: 45,
                      child: Center(
                        child: Text('弹幕设置', style: TextStyle(fontSize: 14)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (!isLive) ...[
                      if (Platform.isMacOS && WindowEnv.isMain)
                        Row(
                          mainAxisAlignment: .spaceBetween,
                          children: [
                            const Text('播放页独立窗口'),
                            Switch(
                              value: Pref.playbackSeparateWindow,
                              onChanged: (v) =>
                                  Pref.playbackSeparateWindow = v,
                            ),
                          ],
                        ),
                      if (PlatformUtils.isDesktop)
                        Obx(
                          () => Row(
                            mainAxisAlignment: .spaceBetween,
                            children: [
                              const Text('弹幕分离窗口'),
                              Switch(
                                value: DanmakuForwarder.i.enabled.value,
                                onChanged: (v) {
                                  if (v) {
                                    DanmakuForwarder.i.open();
                                  } else {
                                    DanmakuForwarder.i.close();
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      if (PlatformUtils.isDesktop)
                        Obx(() {
                          if (!DanmakuForwarder.i.enabled.value) {
                            return const SizedBox.shrink();
                          }
                          final sub = DanmakuForwarder.i.subSettings;
                          void apply() {
                            DanmakuForwarder.i.applySubSettings();
                            setState(() {});
                          }

                          Widget subSlider({
                            required String title,
                            required double min,
                            required double max,
                            int? divisions,
                            required double value,
                            required double resetValue,
                            String Function(double)? label,
                            required ValueChanged<double> onChanged,
                          }) => Column(
                            crossAxisAlignment: .start,
                            children: [
                              Row(
                                mainAxisAlignment: .spaceBetween,
                                children: [
                                  // （子窗口）前缀防与主设置同名项混淆
                                  Text('（子窗口）$title'),
                                  resetBtn(
                                    theme,
                                    label?.call(resetValue) ?? resetValue,
                                    () {
                                      onChanged(resetValue);
                                    },
                                  ),
                                ],
                              ),
                              Padding(
                                padding: sliderPadding,
                                child: Slider(
                                  min: min,
                                  max: max,
                                  divisions: divisions,
                                  value: value.clamp(min, max),
                                  label: label?.call(value),
                                  onChanged: onChanged,
                                ),
                              ),
                            ],
                          );

                          return Column(
                            crossAxisAlignment: .start,
                            children: [
                              Row(
                                mainAxisAlignment: .spaceBetween,
                                children: [
                                  const Text('子窗口 · 同步主设置'),
                                  Switch(
                                    value: sub.syncWithMain,
                                    onChanged: (v) {
                                      DanmakuForwarder.i.setSyncWithMain(v);
                                      setState(() {});
                                    },
                                  ),
                                ],
                              ),
                              if (!sub.syncWithMain) ...[
                                const Text('（子窗口）按类型屏蔽'),
                                SingleChildScrollView(
                                  scrollDirection: .horizontal,
                                  padding: const .symmetric(vertical: 10),
                                  child: Row(
                                    spacing: 10,
                                    // 彩色(6)走主窗口上屏着色管线，无法独立
                                    children: blockTypesList
                                        .where((e) => e.value != 6)
                                        .map((e) {
                                          final blocked = sub.blockTypes
                                              .contains(e.value);
                                          return ActionRowLineItem(
                                            onTap: () {
                                              blocked
                                                  ? sub.blockTypes.remove(
                                                      e.value,
                                                    )
                                                  : sub.blockTypes.add(
                                                      e.value,
                                                    );
                                              apply();
                                            },
                                            text: e.label,
                                            selectStatus: blocked,
                                          );
                                        })
                                        .toList(),
                                  ),
                                ),
                                const Text('（子窗口）其他'),
                                SingleChildScrollView(
                                  scrollDirection: .horizontal,
                                  padding: const .symmetric(vertical: 10),
                                  child: Row(
                                    spacing: 10,
                                    children: [
                                      ActionRowLineItem(
                                        selectStatus: sub.massiveMode,
                                        onTap: () {
                                          sub.massiveMode = !sub.massiveMode;
                                          apply();
                                        },
                                        text: '海量弹幕',
                                      ),
                                      ActionRowLineItem(
                                        selectStatus: sub.static2Scroll,
                                        onTap: () {
                                          sub.static2Scroll =
                                              !sub.static2Scroll;
                                          apply();
                                        },
                                        text: '固定转滚动',
                                      ),
                                      ActionRowLineItem(
                                        selectStatus: sub.fixedV,
                                        onTap: () {
                                          sub.fixedV = !sub.fixedV;
                                          apply();
                                        },
                                        text: '滚动弹幕固定速度',
                                      ),
                                    ],
                                  ),
                                ),
                                subSlider(
                                  title:
                                      '显示区域 ${(sub.showArea * 100).toStringAsFixed(1)}%',
                                  min: 0.1,
                                  max: 1,
                                  divisions: 9,
                                  value: sub.showArea,
                                  resetValue: 0.5,
                                  label: (v) => '${v * 100}%',
                                  onChanged: (val) {
                                    sub.showArea = val.toPrecision(1);
                                    apply();
                                  },
                                ),
                                subSlider(
                                  title:
                                      '不透明度 ${(sub.opacity * 100).toStringAsFixed(1)}%',
                                  min: 0,
                                  max: 1,
                                  divisions: 100,
                                  value: sub.opacity,
                                  resetValue: 1.0,
                                  label: (v) =>
                                      '${(v * 100).toStringAsFixed(1)}%',
                                  onChanged: (val) {
                                    sub.opacity = val.toPrecision(2);
                                    apply();
                                  },
                                ),
                                subSlider(
                                  title:
                                      '字体粗细 ${sub.fontWeight + 1}（可能无法精确调节）',
                                  min: 0,
                                  max: 8,
                                  divisions: 8,
                                  value: sub.fontWeight.toDouble(),
                                  resetValue: 5,
                                  label: (v) => '${v.toInt() + 1}',
                                  onChanged: (val) {
                                    sub.fontWeight = val.toInt();
                                    apply();
                                  },
                                ),
                                subSlider(
                                  title: '描边粗细 ${sub.strokeWidth}',
                                  min: 0,
                                  max: 5,
                                  divisions: 10,
                                  value: sub.strokeWidth,
                                  resetValue: 1.5,
                                  onChanged: (val) {
                                    sub.strokeWidth = val;
                                    apply();
                                  },
                                ),
                                subSlider(
                                  title:
                                      '字体大小 ${(sub.fontScale * 100).toStringAsFixed(1)}%',
                                  min: 0.5,
                                  max: 2.5,
                                  divisions: 200,
                                  value: sub.fontScale,
                                  resetValue: 1.0,
                                  label: (v) =>
                                      '${(v * 100).toStringAsFixed(1)}%',
                                  onChanged: (val) {
                                    sub.fontScale = val.toPrecision(2);
                                    apply();
                                  },
                                ),
                                subSlider(
                                  title: '滚动弹幕时长 ${sub.duration} 秒',
                                  min: 1,
                                  max: 50,
                                  divisions: 49,
                                  value: sub.duration,
                                  resetValue: 7.0,
                                  onChanged: (val) {
                                    sub.duration = val.toPrecision(1);
                                    apply();
                                  },
                                ),
                                subSlider(
                                  title: '静态弹幕时长 ${sub.staticDuration} 秒',
                                  min: 1,
                                  max: 50,
                                  divisions: 49,
                                  value: sub.staticDuration,
                                  resetValue: 4.0,
                                  onChanged: (val) {
                                    sub.staticDuration = val.toPrecision(1);
                                    apply();
                                  },
                                ),
                                subSlider(
                                  title: '弹幕行高 ${sub.lineHeight}',
                                  min: 1.0,
                                  max: 3.0,
                                  value: sub.lineHeight,
                                  resetValue: 1.6,
                                  onChanged: (val) {
                                    sub.lineHeight = val.toPrecision(1);
                                    apply();
                                  },
                                ),
                              ],
                            ],
                          );
                        }),
                      Row(
                        mainAxisAlignment: .spaceBetween,
                        children: [
                          Text('智能云屏蔽 ${DanmakuOptions.danmakuWeight} 级'),
                          TextButton(
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () => Get
                              ..back()
                              ..toNamed(
                                '/danmakuBlock',
                                arguments: plPlayerController,
                              ),
                            child: Text(
                              "屏蔽管理(${plPlayerController.filters.count})",
                            ),
                          ),
                        ],
                      ),
                      Padding(
                        padding: sliderPadding,
                        child: Slider(
                          min: 0,
                          max: 11,
                          value: DanmakuOptions.danmakuWeight.toDouble(),
                          divisions: 11,
                          label: DanmakuOptions.danmakuWeight.toString(),
                          onChanged: updateDanmakuWeight,
                        ),
                      ),
                    ],
                    const Text('按类型屏蔽'),
                    SingleChildScrollView(
                      scrollDirection: .horizontal,
                      padding: const .symmetric(vertical: 10),
                      child: Row(
                        spacing: 10,
                        children: blockTypesList.map(
                          (e) {
                            final blocked = DanmakuOptions.blockTypes.contains(
                              e.value,
                            );
                            return ActionRowLineItem(
                              onTap: () => onUpdateBlockType(e.value, blocked),
                              text: e.label,
                              selectStatus: blocked,
                            );
                          },
                        ).toList(),
                      ),
                    ),
                    const Text('其他'),
                    SingleChildScrollView(
                      scrollDirection: .horizontal,
                      padding: const .symmetric(vertical: 10),
                      child: Row(
                        spacing: 10,
                        children: [
                          ActionRowLineItem(
                            selectStatus: DanmakuOptions.danmakuMassiveMode,
                            onTap: () {
                              DanmakuOptions.danmakuMassiveMode =
                                  !DanmakuOptions.danmakuMassiveMode;
                              setState(() {});
                              setOptions();
                            },
                            text: '海量弹幕',
                          ),
                          ActionRowLineItem(
                            selectStatus: DanmakuOptions.danmakuStatic2Scroll,
                            onTap: () {
                              DanmakuOptions.danmakuStatic2Scroll =
                                  !DanmakuOptions.danmakuStatic2Scroll;
                              setState(() {});
                              setOptions();
                            },
                            text: '固定转滚动',
                          ),
                          ActionRowLineItem(
                            selectStatus: DanmakuOptions.danmakuFixedV,
                            onTap: () {
                              DanmakuOptions.danmakuFixedV =
                                  !DanmakuOptions.danmakuFixedV;
                              setState(() {});
                              setOptions();
                            },
                            text: '滚动弹幕固定速度',
                          ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '显示区域 ${(DanmakuOptions.danmakuShowArea * 100).toStringAsFixed(1)}%',
                        ),
                        resetBtn(theme, '50.0%', () => updateShowArea(0.5)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0.1,
                        max: 1,
                        value: DanmakuOptions.danmakuShowArea,
                        divisions: 9,
                        label: '${DanmakuOptions.danmakuShowArea * 100}%',
                        onChanged: updateShowArea,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '不透明度 ${(plPlayerController.danmakuOpacity * 100).toStringAsFixed(1)}%',
                        ),
                        resetBtn(theme, '100.0%', () => updateOpacity(1.0)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0,
                        max: 1,
                        value: plPlayerController.danmakuOpacity.value,
                        divisions: 100,
                        label:
                            '${(plPlayerController.danmakuOpacity * 100).toStringAsFixed(1)}%',
                        onChanged: updateOpacity,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '字体粗细 ${DanmakuOptions.danmakuFontWeight + 1}（可能无法精确调节）',
                        ),
                        resetBtn(theme, 6, () => updateFontWeight(5)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0,
                        max: 8,
                        value: DanmakuOptions.danmakuFontWeight.toDouble(),
                        divisions: 8,
                        label: '${DanmakuOptions.danmakuFontWeight + 1}',
                        onChanged: updateFontWeight,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('描边粗细 ${DanmakuOptions.danmakuStrokeWidth}'),
                        resetBtn(theme, 1.5, () => updateStrokeWidth(1.5)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0,
                        max: 5,
                        value: DanmakuOptions.danmakuStrokeWidth,
                        divisions: 10,
                        label: DanmakuOptions.danmakuStrokeWidth.toString(),
                        onChanged: updateStrokeWidth,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '字体大小 ${(DanmakuOptions.danmakuFontScale * 100).toStringAsFixed(1)}%',
                        ),
                        resetBtn(theme, '100.0%', () => updateFontSize(1.0)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0.5,
                        max: 2.5,
                        value: DanmakuOptions.danmakuFontScale,
                        divisions: 200,
                        label:
                            '${(DanmakuOptions.danmakuFontScale * 100).toStringAsFixed(1)}%',
                        onChanged: updateFontSize,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '全屏字体大小 ${(DanmakuOptions.danmakuFontScaleFS * 100).toStringAsFixed(1)}%',
                        ),
                        resetBtn(theme, '120.0%', () => updateFontSizeFS(1.2)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0.5,
                        max: 2.5,
                        value: DanmakuOptions.danmakuFontScaleFS,
                        divisions: 200,
                        label:
                            '${(DanmakuOptions.danmakuFontScaleFS * 100).toStringAsFixed(1)}%',
                        onChanged: updateFontSizeFS,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('滚动弹幕时长 ${DanmakuOptions.danmakuDuration} 秒'),
                        resetBtn(theme, 7.0, () => updateDuration(7.0)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 1,
                        max: 50,
                        value: DanmakuOptions.danmakuDuration,
                        divisions: 49,
                        label: DanmakuOptions.danmakuDuration.toString(),
                        onChanged: updateDuration,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '静态弹幕时长 ${DanmakuOptions.danmakuStaticDuration} 秒',
                        ),
                        resetBtn(theme, 4.0, () => updateStaticDuration(4.0)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 1,
                        max: 50,
                        value: DanmakuOptions.danmakuStaticDuration,
                        divisions: 49,
                        label: DanmakuOptions.danmakuStaticDuration.toString(),
                        onChanged: updateStaticDuration,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('弹幕行高 ${DanmakuOptions.danmakuLineHeight}'),
                        resetBtn(theme, 1.6, () => updateLineHeight(1.6)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 1.0,
                        max: 3.0,
                        value: DanmakuOptions.danmakuLineHeight,
                        onChanged: updateLineHeight,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    )?.whenComplete(
      () => DanmakuOptions.save(plPlayerController.danmakuOpacity.value),
    );
  }
}

class MSliderTrackShape extends RoundedRectSliderTrackShape {
  const MSliderTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    SliderThemeData? sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    const double trackHeight = 3;
    final double trackLeft = offset.dx;
    final double trackTop =
        offset.dy + (parentBox.size.height - trackHeight) / 2;
    final double trackWidth = parentBox.size.width;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }
}
