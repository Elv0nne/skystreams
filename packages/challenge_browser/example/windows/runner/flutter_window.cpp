#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <optional>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

INPUT Key(WORD key, bool up) {
  INPUT input = {};
  input.type = INPUT_KEYBOARD;
  input.ki.wVk = key;
  input.ki.wScan = static_cast<WORD>(MapVirtualKey(key, MAPVK_VK_TO_VSC));
  input.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
  return input;
}

INPUT Mouse(DWORD flags) {
  INPUT input = {};
  input.type = INPUT_MOUSE;
  input.mi.dwFlags = flags;
  return input;
}

void Send(std::vector<INPUT> inputs) {
  SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // For the integration tests: Tab, Escape, Space and clicks as the system's own input, which goes to whatever
  // has keyboard focus or is under the pointer, Flutter's view or a page.
  keys_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "challenge_browser_example/keys",
      &flutter::StandardMethodCodec::GetInstance());
  keys_->SetMethodCallHandler([this](const auto& call, auto result) {
    const HWND view = flutter_controller_->view()->GetNativeWindow();
    if (call.method_name() == "focusFlutter") {
      // As a click on Flutter's content would.
      SetForegroundWindow(GetHandle());
      SetFocus(view);
      result->Success(flutter::EncodableValue(GetForegroundWindow() == GetHandle()));
    } else if (call.method_name() == "tab") {
      const bool* shift = std::get_if<bool>(call.arguments());
      std::vector<INPUT> keys;
      if (shift && *shift) keys.push_back(Key(VK_SHIFT, false));
      keys.push_back(Key(VK_TAB, false));
      keys.push_back(Key(VK_TAB, true));
      if (shift && *shift) keys.push_back(Key(VK_SHIFT, true));
      Send(keys);
      result->Success();
    } else if (call.method_name() == "escape") {
      Send({Key(VK_ESCAPE, false), Key(VK_ESCAPE, true)});
      result->Success();
    } else if (call.method_name() == "space") {
      Send({Key(VK_SPACE, false), Key(VK_SPACE, true)});
      result->Success();
    } else if (call.method_name() == "click") {
      // At [x, y]: logical pixels from the top left of Flutter's view.
      const auto& at = std::get<flutter::EncodableList>(*call.arguments());
      const double scale = FlutterDesktopGetDpiForHWND(view) / 96.0;
      POINT point = {static_cast<LONG>(std::get<double>(at[0]) * scale),
                     static_cast<LONG>(std::get<double>(at[1]) * scale)};
      ClientToScreen(view, &point);
      SetCursorPos(point.x, point.y);
      Send({Mouse(MOUSEEVENTF_LEFTDOWN), Mouse(MOUSEEVENTF_LEFTUP)});
      result->Success();
    } else {
      result->NotImplemented();
    }
  });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
