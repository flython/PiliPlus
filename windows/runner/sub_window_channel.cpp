#include "sub_window_channel.h"

#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <vector>

namespace {

// 保活全部子窗口 channel：handler 由 messenger 异步派发，容器不可在
// 调用中析构；窗口销毁后残留条目极小且不再被触达，随进程生命周期释放。
std::vector<std::unique_ptr<
    flutter::MethodChannel<flutter::EncodableValue>>>&
SubWindowChannels() {
  static std::vector<
      std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>>
      channels;
  return channels;
}

// desktop_multi_window 官方 C API（include/desktop_multi_window/
// desktop_multi_window_plugin.h）。避免为单个函数引入对插件头目录的
// 构建期依赖，这里按签名自行声明并从插件 DLL 动态解析。
using WindowCreatedCallbackFn = void (*)(void* flutter_view_controller);
using SetWindowCreatedCallbackFn = void (*)(WindowCreatedCallbackFn);

void OnSubWindowCreated(void* flutter_view_controller) {
  if (flutter_view_controller == nullptr) {
    return;
  }
  auto* controller =
      reinterpret_cast<flutter::FlutterViewController*>(
          flutter_view_controller);
  auto* view = controller->view();
  if (view == nullptr) {
    return;
  }
  // engine 的 messenger 直接就是 flutter::BinaryMessenger*，生命周期跟随
  // 子 engine。不能走 FlutterDesktopPluginRegistrarGetMessenger：它返回 C ABI
  // 的不完整类型 FlutterDesktopMessengerRef，MethodChannel 构造函数不收。
  auto* messenger = controller->engine()->messenger();
  if (messenger == nullptr) {
    return;
  }
  // 注册点子窗口顶层 HWND 已存在（插件 Create 先包壳再回调）。
  // 预先解析并按值捕获，handler 不再依赖 controller 存活。
  HWND root = GetAncestor(view->GetNativeWindow(), GA_ROOT);
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "PiliPlus/subwindow",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [root](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "close") {
          // 先回复再投递销毁：WM_CLOSE 在插件 Win32Window 上经
          // DefWindowProc → DestroyWindow，与用户点 X 同链路，子窗口
          // engine 随之销毁并通知主窗口（RemoveWindow）。
          result->Success();
          PostMessage(root, WM_CLOSE, 0, 0);
        } else {
          result->NotImplemented();
        }
      });
  SubWindowChannels().push_back(std::move(channel));
}

}  // namespace

void RegisterSubWindowCloseChannel() {
  // 插件随主 engine 的 GeneratedPluginRegistrant 加载；未加载（如该
  // 插件被禁用）时静默跳过，与未打本补丁的行为一致。
  HMODULE module = ::GetModuleHandleW(L"desktop_multi_window_plugin.dll");
  if (module == nullptr) {
    return;
  }
  auto set_callback = reinterpret_cast<SetWindowCreatedCallbackFn>(
      reinterpret_cast<void*>(::GetProcAddress(
          module, "DesktopMultiWindowSetWindowCreatedCallback")));
  if (set_callback != nullptr) {
    set_callback(&OnSubWindowCreated);
  }
}
