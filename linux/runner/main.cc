#include "my_application.h"
#include "sub_window_channel.h"

int main(int argc, char** argv) {
  RegisterSubWindowCloseChannel();
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
