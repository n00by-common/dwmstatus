// Zig can't evaluate `DefaultRootWindow`s function signature for calling from zig @cImport
// so we just have this tiny C wrapper for it
#include <X11/Xlib.h>

Display *display;
Window root_window;

void set_title(char const *title) {
  XStoreName(display, root_window, title);
  XSync(display, 0);
}

void setup() {
  display = XOpenDisplay(0);
  root_window = DefaultRootWindow(display);
}
