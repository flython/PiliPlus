#ifndef RUNNER_SUB_WINDOW_CHANNEL_H_
#define RUNNER_SUB_WINDOW_CHANNEL_H_

// 在 desktop_multi_window 插件 DLL 上挂子窗口创建回调，为弹幕分离子
// engine 注册 PiliPlus/subwindow 通道（目前仅 close，走用户点 X 同一
// 销毁链路）。对齐 macOS MainFlutterWindow.swift 的做法；插件未加载时
// 为 no-op。见 .scratch/danmaku-separate-window/issues/05。
void RegisterSubWindowCloseChannel();

#endif  // RUNNER_SUB_WINDOW_CHANNEL_H_
