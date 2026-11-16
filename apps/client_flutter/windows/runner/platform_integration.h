#ifndef RUNNER_PLATFORM_INTEGRATION_H_
#define RUNNER_PLATFORM_INTEGRATION_H_
#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <memory>
#include <optional>
#include "pin_store.h"

class PlatformIntegration {
 public:
  PlatformIntegration(HWND window, flutter::BinaryMessenger* messenger);
  ~PlatformIntegration();
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
 private:
  using Value = flutter::EncodableValue;
  using Map = flutter::EncodableMap;
  void Handle(const flutter::MethodCall<Value>& call, std::unique_ptr<flutter::MethodResult<Value>> result);
  void Event(const char* type);
  void Show();
  void Lock();
  void Logout();
  void Initialize();
  void UpdatePet();
  void SetAutostart(bool enabled);
  void Toast(const std::string& title, const std::string& body, bool hidden);
  static LRESULT CALLBACK PetProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);
  HWND window_;
  HWND pet_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
  PinStore pin_;
  bool initialized_ = false;
  bool tray_ = false;
  bool hotkey_ = false;
  bool pet_visible_ = false;
  bool locked_ = false;
  bool session_locked_ = false;
  bool fullscreen_ = false;
  bool in_call_ = false;
  bool click_through_ = false;
  int unread_ = 0;
};
#endif
