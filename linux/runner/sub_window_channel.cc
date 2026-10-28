#include "sub_window_channel.h"

#include <desktop_multi_window/desktop_multi_window_plugin.h>
#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

namespace {

// 销毁必须延后到 idle：与 Windows 侧 PostMessage(WM_CLOSE) 同义。若在方法
// 回调栈内同步 destroy，插件会在 destroy 里拆掉子 engine → messenger
// shutdown → 关掉本通道并释放它持有的引用，而 message_cb 还在栈上。
// 先持一个引用进 idle，防止这个空档里用户点 X 把窗口释放掉。
gboolean DestroyWindowIdle(gpointer user_data) {
  // GTK 自己保证重复 destroy 是 no-op，用户已点 X 时这里什么都不做。
  gtk_widget_destroy(GTK_WIDGET(user_data));
  g_object_unref(user_data);
  return G_SOURCE_REMOVE;
}

// 子窗口只有 close 一个方法（与 Windows/macOS 现有实现一致）。销毁走
// GtkWidget::destroy，插件 ObserveWindowClose 的 "destroy" 回调会
// RemoveWindow 并通知主窗口，与用户点窗口关闭键同一条链路。
void MethodCallCb(FlMethodChannel*,
                  FlMethodCall* method_call,
                  gpointer user_data) {
  if (g_strcmp0(fl_method_call_get_name(method_call), "close") != 0) {
    fl_method_call_respond_not_implemented(method_call, nullptr);
    return;
  }
  fl_method_call_respond_success(method_call, nullptr, nullptr);
  g_idle_add(DestroyWindowIdle, g_object_ref(user_data));
}

void OnSubWindowCreated(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry,
                                                  "DesktopMultiWindowPlugin");
  if (registrar == nullptr) return;
  FlView* view = fl_plugin_registrar_get_view(registrar);
  if (view == nullptr) return;
  // 回调点在建窗之后（插件先 gtk_container_add 再回调），toplevel 已就绪。
  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
  if (!GTK_IS_WINDOW(toplevel)) return;

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), "PiliPlus/subwindow",
      FL_METHOD_CODEC(codec));
  // messenger 内部会 g_object_ref 本通道并持有到子 engine 销毁，所以这里
  // 放掉自己这份引用即可，不需要额外的生命周期管理。
  fl_method_channel_set_method_call_handler(channel, MethodCallCb, toplevel,
                                            nullptr);
  g_object_unref(channel);
}

}  // namespace

void RegisterSubWindowCloseChannel() {
  desktop_multi_window_plugin_set_window_created_callback(&OnSubWindowCreated);
}
