#include "platform_integration.h"
#include <flutter/standard_method_codec.h>
#include <commdlg.h>
#include <shellapi.h>
#include <shlobj.h>
#include <propkey.h>
#include <propvarutil.h>
#include <wtsapi32.h>
#include <wincred.h>
#include <wincrypt.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.UI.Notifications.h>
#include <algorithm>
#include <cwctype>
#include <stdexcept>
#include <vector>
#include "resource.h"

namespace {
constexpr wchar_t kAumid[] = L"com.jingyu.client";
constexpr wchar_t kSession[] = L"com.jingyu.client.session";
constexpr UINT kTrayMessage = WM_APP + 41;
constexpr UINT kTimer = 42;
constexpr int kHotkey = 43;
std::wstring Wide(const std::string& input) {
  if (input.empty()) return {};
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(), static_cast<int>(input.size()), nullptr, 0);
  if (!count) throw std::invalid_argument("Invalid UTF-8");
  std::wstring output(count, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input.data(), static_cast<int>(input.size()), output.data(), count);
  return output;
}
std::string Utf8(const std::wstring& input) {
  const int count = WideCharToMultiByte(CP_UTF8, 0, input.data(), static_cast<int>(input.size()), nullptr, 0, nullptr, nullptr);
  std::string output(count, '\0');
  WideCharToMultiByte(CP_UTF8, 0, input.data(), static_cast<int>(input.size()), output.data(), count, nullptr, nullptr);
  return output;
}
std::wstring Executable() {
  std::wstring path(32768, L'\0');
  const DWORD size = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (!size || size >= path.size()) throw std::runtime_error("Cannot resolve executable");
  path.resize(size);
  return path;
}
void Check(HRESULT hr, const char* message) { if (FAILED(hr)) throw std::runtime_error(message); }
const flutter::EncodableValue* Field(const flutter::EncodableMap& args, const char* name) {
  auto found = args.find(flutter::EncodableValue(name));
  return found == args.end() ? nullptr : &found->second;
}
std::string Text(const flutter::EncodableMap& args, const char* name) {
  auto* value = Field(args, name);
  if (!value || !std::holds_alternative<std::string>(*value)) throw std::invalid_argument(std::string("Missing string: ") + name);
  return std::get<std::string>(*value);
}
bool Flag(const flutter::EncodableMap& args, const char* name, bool fallback = false) {
  auto* value = Field(args, name);
  if (!value) return fallback;
  if (!std::holds_alternative<bool>(*value)) throw std::invalid_argument(std::string("Expected boolean: ") + name);
  return std::get<bool>(*value);
}
void Shortcut() {
  Check(SetCurrentProcessExplicitAppUserModelID(kAumid), "Cannot set process AUMID");
  PWSTR programs = nullptr;
  Check(SHGetKnownFolderPath(FOLDERID_Programs, KF_FLAG_CREATE, nullptr, &programs), "Cannot find Start Menu");
  std::wstring shortcut = std::wstring(programs) + L"\\Jingyu Client.lnk";
  CoTaskMemFree(programs);
  winrt::com_ptr<IShellLinkW> link;
  Check(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(link.put())), "Cannot create Start Menu shortcut");
  const auto executable = Executable();
  Check(link->SetPath(executable.c_str()), "Cannot set shortcut path");
  Check(link->SetWorkingDirectory(executable.substr(0, executable.find_last_of(L"\\/")).c_str()), "Cannot set shortcut directory");
  Check(link->SetDescription(L"Jingyu Client"), "Cannot set shortcut description");
  auto properties = link.as<IPropertyStore>();
  PROPVARIANT aumid{};
  Check(InitPropVariantFromString(kAumid, &aumid), "Cannot create AUMID property");
  const HRESULT status = properties->SetValue(PKEY_AppUserModel_ID, aumid);
  PropVariantClear(&aumid);
  Check(status, "Cannot set shortcut AUMID");
  Check(properties->Commit(), "Cannot commit shortcut properties");
  Check(link.as<IPersistFile>()->Save(shortcut.c_str(), TRUE), "Cannot save Start Menu shortcut");
}
void SaveSession(const std::string& json) {
  if (json.empty() || json.size() > 2200) throw std::invalid_argument("Session must be 1 to 2200 bytes");
  DATA_BLOB input{static_cast<DWORD>(json.size()), reinterpret_cast<BYTE*>(const_cast<char*>(json.data()))}, output{};
  if (!CryptProtectData(&input, L"Jingyu session", nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output))
    throw std::runtime_error("Cannot encrypt session");
  CREDENTIALW credential{};
  credential.Type = CRED_TYPE_GENERIC;
  credential.TargetName = const_cast<wchar_t*>(kSession);
  credential.UserName = const_cast<wchar_t*>(L"JingyuClient");
  credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
  credential.CredentialBlobSize = output.cbData;
  credential.CredentialBlob = output.pbData;
  const BOOL ok = CredWriteW(&credential, 0);
  SecureZeroMemory(output.pbData, output.cbData);
  LocalFree(output.pbData);
  if (!ok) throw std::runtime_error("Cannot save session credential");
}
flutter::EncodableValue ReadSession() {
  PCREDENTIALW credential = nullptr;
  if (!CredReadW(kSession, CRED_TYPE_GENERIC, 0, &credential)) {
    if (GetLastError() == ERROR_NOT_FOUND) return flutter::EncodableValue();
    throw std::runtime_error("Cannot read session credential");
  }
  DATA_BLOB input{credential->CredentialBlobSize, credential->CredentialBlob}, output{};
  const BOOL ok = CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output);
  CredFree(credential);
  if (!ok) throw std::runtime_error("Cannot decrypt session credential");
  std::string json(reinterpret_cast<char*>(output.pbData), output.cbData);
  SecureZeroMemory(output.pbData, output.cbData);
  LocalFree(output.pbData);
  return flutter::EncodableValue(json);
}
void ClearSession() {
  if (!CredDeleteW(kSession, CRED_TYPE_GENERIC, 0) && GetLastError() != ERROR_NOT_FOUND)
    throw std::runtime_error("Cannot remove session credential");
}
std::optional<int64_t> Integer(const flutter::EncodableMap& args, const char* name) {
  auto* value = Field(args, name);
  if (!value) return std::nullopt;
  if (std::holds_alternative<int32_t>(*value)) return std::get<int32_t>(*value);
  if (std::holds_alternative<int64_t>(*value)) return std::get<int64_t>(*value);
  return std::nullopt;
}
// A user-chosen backup file holds the exact bytes the Dart side produced. The
// bridge enforces the caller's 4 MiB bound before any OS dialog is shown.
constexpr size_t kMaxBackupBytes = 4 * 1024 * 1024;
constexpr size_t kMaxBackupFileName = 250;
constexpr wchar_t kBackupFilter[] = L"JSON files\0*.json\0All files\0*.*\0";
wchar_t Lower(wchar_t character) {
  return static_cast<wchar_t>(towlower(character));
}
bool EndsWithJson(const std::wstring& name) {
  if (name.size() < 5u) return false;
  const wchar_t* tail = name.c_str() + name.size() - 5;
  return Lower(tail[0]) == L'.' && Lower(tail[1]) == L'j' &&
         Lower(tail[2]) == L's' && Lower(tail[3]) == L'o' &&
         Lower(tail[4]) == L'n';
}
std::wstring BackupFileName(const std::wstring& suggested) {
  std::wstring name = suggested;
  const auto separator = name.find_last_of(L"\\/");
  if (separator != std::wstring::npos) name = name.substr(separator + 1);
  static const std::wstring kInvalid = L"<>:\"/\\|?*";
  std::wstring cleaned;
  for (const wchar_t character : name) {
    if (character >= L' ' && kInvalid.find(character) == std::wstring::npos)
      cleaned.push_back(character);
  }
  while (!cleaned.empty() && (cleaned.back() == L' ' || cleaned.back() == L'.'))
    cleaned.pop_back();
  const auto first = cleaned.find_first_not_of(L' ');
  if (first == std::wstring::npos) cleaned.clear(); else cleaned.erase(0, first);
  if (cleaned.size() > kMaxBackupFileName) cleaned.resize(kMaxBackupFileName);
  if (!EndsWithJson(cleaned)) cleaned += L".json";
  return cleaned.empty() ? L"jingyu-backup.json" : cleaned;
}
std::optional<std::wstring> PromptBackupPath(HWND window, const std::wstring& suggested) {
  std::wstring path(32768, L'\0');
  const std::wstring name = BackupFileName(suggested);
  wcsncpy_s(path.data(), path.size(), name.c_str(), _TRUNCATE);
  OPENFILENAMEW dialog{};
  dialog.lStructSize = sizeof(dialog);
  dialog.hwndOwner = window;
  dialog.lpstrFilter = kBackupFilter;
  dialog.lpstrFile = path.data();
  dialog.nMaxFile = static_cast<DWORD>(path.size());
  dialog.lpstrDefExt = L"json";
  dialog.Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER;
  if (GetSaveFileNameW(&dialog)) {
    path.resize(wcslen(path.c_str()));
    return path;
  }
  if (CommDlgExtendedError() == 0) return std::nullopt;
  throw std::runtime_error("Cannot open backup save dialog");
}
// Write next to the destination, flush, then replace so a crash or full disk
// never leaves a truncated backup that looks like a successful save.
void WriteBackupFile(const std::wstring& path, const std::vector<uint8_t>& bytes) {
  const std::wstring temporary = path + L".jingyu-backup-tmp";
  HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_TEMPORARY, nullptr);
  if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("Cannot create backup file");
  bool writtenAll = true;
  size_t offset = 0;
  while (writtenAll && offset < bytes.size()) {
    const DWORD chunk = static_cast<DWORD>(std::min<size_t>(bytes.size() - offset, static_cast<size_t>(1) << 20));
    DWORD written = 0;
    writtenAll = WriteFile(file, bytes.data() + offset, chunk, &written, nullptr) && written == chunk;
    offset += chunk;
  }
  writtenAll = writtenAll && FlushFileBuffers(file);
  CloseHandle(file);
  if (!writtenAll) {
    DeleteFileW(temporary.c_str());
    throw std::runtime_error("Cannot write backup file");
  }
  if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    DeleteFileW(temporary.c_str());
    throw std::runtime_error("Cannot finalize backup file");
  }
}
}

PlatformIntegration::PlatformIntegration(HWND window, flutter::BinaryMessenger* messenger) : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(messenger, "jingyu/platform", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) { Handle(call, std::move(result)); });
}
PlatformIntegration::~PlatformIntegration() {
  channel_->SetMethodCallHandler(nullptr);
  KillTimer(window_, kTimer);
  if (hotkey_) UnregisterHotKey(window_, kHotkey);
  WTSUnRegisterSessionNotification(window_);
  if (pet_) DestroyWindow(pet_);
  if (tray_) {
    NOTIFYICONDATAW data{}; data.cbSize = sizeof(data); data.hWnd = window_; data.uID = 1;
    Shell_NotifyIconW(NIM_DELETE, &data);
  }
}
void PlatformIntegration::Event(const char* type) {
  channel_->InvokeMethod("event", std::make_unique<Value>(Map{{Value("type"), Value(type)}}));
}
void PlatformIntegration::Show() { ShowWindow(window_, SW_RESTORE); SetForegroundWindow(window_); Event("show"); }
void PlatformIntegration::Lock() {
  locked_ = true; UpdatePet(); Event("lock");
  winrt::Windows::UI::Notifications::ToastNotificationManager::History().Clear(kAumid);
}
void PlatformIntegration::Logout() {
  locked_ = true; pet_visible_ = false; UpdatePet(); Event("logout");
  ClearSession();
  winrt::Windows::UI::Notifications::ToastNotificationManager::History().Clear(kAumid);
}
void PlatformIntegration::Initialize() {
  if (initialized_) return;
  // A previous partial initialization may have left shell resources registered.
  if (pet_) { DestroyWindow(pet_); pet_ = nullptr; }
  if (hotkey_) { UnregisterHotKey(window_, kHotkey); hotkey_ = false; }
  if (tray_) {
    NOTIFYICONDATAW stale{}; stale.cbSize = sizeof(stale); stale.hWnd = window_; stale.uID = 1;
    Shell_NotifyIconW(NIM_DELETE, &stale); tray_ = false;
  }
  Shortcut();
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data); data.hWnd = window_; data.uID = 1;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(data.szTip, L"Jingyu Client");
  tray_ = Shell_NotifyIconW(NIM_ADD, &data) != FALSE;
  hotkey_ = RegisterHotKey(window_, kHotkey, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, 'J') != FALSE;
  WTSRegisterSessionNotification(window_, NOTIFY_FOR_THIS_SESSION);
  WNDCLASSW wc{};
  wc.style = CS_DBLCLKS;
  wc.lpfnWndProc = PetProc; wc.hInstance = GetModuleHandle(nullptr); wc.lpszClassName = L"JingyuPet";
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  RegisterClassW(&wc);
  pet_ = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      wc.lpszClassName, L"", WS_POPUP, 32, 180, 88, 88, nullptr, nullptr, wc.hInstance, this);
  if (!pet_) throw std::runtime_error("Cannot create pet window");
  SetLayeredWindowAttributes(pet_, RGB(255,0,255), 240, LWA_COLORKEY | LWA_ALPHA);
  SetTimer(window_, kTimer, 1000, nullptr);
  initialized_ = true;
}
void PlatformIntegration::SetAutostart(bool enabled) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS)
    throw std::runtime_error("Cannot open user autostart settings");
  LSTATUS status;
  if (enabled) {
    const auto command = L"\"" + Executable() + L"\"";
    status = RegSetValueExW(key, L"JingyuClient", 0, REG_SZ, reinterpret_cast<const BYTE*>(command.c_str()), static_cast<DWORD>((command.size()+1)*sizeof(wchar_t)));
  } else {
    status = RegDeleteValueW(key, L"JingyuClient");
    if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
  }
  RegCloseKey(key);
  if (status != ERROR_SUCCESS) throw std::runtime_error("Cannot update autostart settings");
}
void PlatformIntegration::Toast(const std::string& title, const std::string& body, bool hidden) {
  using namespace winrt::Windows::UI::Notifications;
  auto xml = ToastNotificationManager::GetTemplateContent(ToastTemplateType::ToastText02);
  auto nodes = xml.GetElementsByTagName(L"text");
  nodes.Item(0).AppendChild(xml.CreateTextNode(Wide(title)));
  nodes.Item(1).AppendChild(xml.CreateTextNode(hidden || locked_ || session_locked_ ? L"New message" : Wide(body)));
  // Text nodes safely escape all XML markup from incoming messages.
  ToastNotification notification(xml);
  notification.Tag(L"jingyu-message");
  notification.Group(L"messages");
  ToastNotificationManager::CreateToastNotifier(kAumid).Show(notification);
}
void PlatformIntegration::UpdatePet() {
  if (tray_) {
    NOTIFYICONDATAW data{}; data.cbSize = sizeof(data); data.hWnd = window_; data.uID = 1;
    data.uFlags = NIF_TIP;
    const auto tip = unread_ > 0 ? L"Jingyu Client - " + std::to_wstring(unread_) + L" unread" : std::wstring(L"Jingyu Client");
    wcsncpy_s(data.szTip, tip.c_str(), _TRUNCATE);
    Shell_NotifyIconW(NIM_MODIFY, &data);
  }
  if (!pet_) return;
  bool full = fullscreen_;
  HWND foreground = GetForegroundWindow();
  if (foreground && foreground != pet_ && foreground != window_ && foreground != GetShellWindow() && foreground != GetDesktopWindow()) {
    RECT rect{}; MONITORINFO monitor{sizeof(monitor)};
    if (GetWindowRect(foreground, &rect) && GetMonitorInfoW(MonitorFromWindow(foreground, MONITOR_DEFAULTTONEAREST), &monitor))
      full = full || (rect.left <= monitor.rcMonitor.left && rect.top <= monitor.rcMonitor.top && rect.right >= monitor.rcMonitor.right && rect.bottom >= monitor.rcMonitor.bottom);
  }
  ShowWindow(pet_, pet_visible_ && !locked_ && !session_locked_ && !in_call_ && !full ? SW_SHOWNOACTIVATE : SW_HIDE);
  LONG_PTR style = GetWindowLongPtrW(pet_, GWL_EXSTYLE);
  SetWindowLongPtrW(pet_, GWL_EXSTYLE, click_through_ ? style | WS_EX_TRANSPARENT : style & ~WS_EX_TRANSPARENT);
}
void PlatformIntegration::Handle(const flutter::MethodCall<Value>& call, std::unique_ptr<flutter::MethodResult<Value>> result) {
  try {
    const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    const Map empty;
    const Map& a = args ? *args : empty;
    const std::string& method = call.method_name();
    if (method == "initialize") {
      Initialize();
      result->Success(Value(Map{{Value("platform"), Value("windows")}, {Value("aumid"), Value("com.jingyu.client")}, {Value("tray"), Value(tray_)}, {Value("globalShortcut"), Value(hotkey_)}, {Value("notifications"), Value(true)}})); return;
    }
    if (method == "getDataDirectory") {
      PWSTR local = nullptr;
      Check(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &local), "Cannot find app data");
      const std::wstring path = std::wstring(local) + L"\\JingyuClient"; CoTaskMemFree(local);
      if (!CreateDirectoryW(path.c_str(), nullptr) && GetLastError() != ERROR_ALREADY_EXISTS) throw std::runtime_error("Cannot create app data directory");
      result->Success(Value(Utf8(path))); return;
    }
    if (method == "hasPin") { result->Success(Value(pin_.HasPin())); return; }
    if (method == "configurePin") pin_.Configure(Text(a, "pin"));
    else if (method == "removePin") pin_.Remove();
    else if (method == "unlockPin") {
      const bool ok = pin_.Verify(Text(a, "pin")); if (ok) { locked_ = false; UpdatePet(); }
      result->Success(Value(ok)); return;
    }
    else if (method == "unlockBiometric") { result->Success(Value(false)); return; }
    else if (method == "storeSession") SaveSession(Text(a, "json"));
    else if (method == "readSession") { result->Success(ReadSession()); return; }
    else if (method == "clearSession") ClearSession();
    else if (method == "pickAttachment") {
      const std::string kind = Text(a, "kind");
      if (kind != "image" && kind != "file") throw std::invalid_argument("Unsupported attachment kind");
      static const wchar_t kImageFilter[] =
          L"Images\0*.png;*.jpg;*.jpeg;*.gif;*.webp;*.bmp\0All files\0*.*\0";
      static const wchar_t kAllFilesFilter[] = L"All files\0*.*\0";
      std::wstring path(32768, L'\0');
      OPENFILENAMEW dialog{};
      dialog.lStructSize = sizeof(dialog);
      dialog.hwndOwner = window_;
      dialog.lpstrFilter = kind == "image" ? kImageFilter : kAllFilesFilter;
      dialog.lpstrFile = path.data();
      dialog.nMaxFile = static_cast<DWORD>(path.size());
      dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
      if (GetOpenFileNameW(&dialog)) {
        path.resize(wcslen(path.c_str()));
        const auto separator = path.find_last_of(L"\\/");
        const std::wstring name = separator == std::wstring::npos ? path : path.substr(separator + 1);
        result->Success(Value(Map{
            {Value("path"), Value(Utf8(path))},
            {Value("name"), Value(Utf8(name))},
            {Value("temporary"), Value(false)},
        }));
      } else if (CommDlgExtendedError() == 0) {
        result->Success(Value());
      } else {
        throw std::runtime_error("Cannot open attachment picker");
      }
      return;
    }
    else if (method == "saveBackupFile") {
      const auto* bytesValue = Field(a, "bytes");
      if (!bytesValue || !std::holds_alternative<std::vector<uint8_t>>(*bytesValue))
        throw std::invalid_argument("Missing bytes: bytes");
      const auto& bytes = std::get<std::vector<uint8_t>>(*bytesValue);
      const auto requested = Integer(a, "maxBytes");
      if (!requested || *requested < 1 || *requested > static_cast<int64_t>(kMaxBackupBytes))
        throw std::invalid_argument("Invalid backup byte limit");
      if (bytes.empty()) throw std::invalid_argument("Backup content is empty");
      if (bytes.size() > static_cast<size_t>(*requested))
        throw std::invalid_argument("Backup content exceeds the requested limit");
      const std::wstring suggested = Wide(Text(a, "suggestedName"));
      const auto path = PromptBackupPath(window_, suggested);
      if (!path) { result->Success(Value()); return; }
      WriteBackupFile(*path, bytes);
      const auto separator = path->find_last_of(L"\\/");
      const std::wstring name = separator == std::wstring::npos ? *path : path->substr(separator + 1);
      result->Success(Value(Map{{Value("name"), Value(Utf8(name))},
                               {Value("bytes"), Value(static_cast<int64_t>(bytes.size()))}}));
      return;
    }
    else if (method == "notify") Toast(Text(a, "title"), Text(a, "body"), Flag(a, "hideBody"));
    else if (method == "setAutostart") SetAutostart(Flag(a, "enabled"));
    else if (method == "lock") Lock();
    else if (method == "logout") Logout();
    else if (method == "showWindow") Show();
    else if (method == "hideWindow") ShowWindow(window_, SW_HIDE);
    else if (method == "quit") PostQuitMessage(0);
    else if (method == "setPetState") {
      pet_visible_ = Flag(a, "visible"); locked_ = Flag(a, "locked", locked_);
      fullscreen_ = Flag(a, "fullscreen"); in_call_ = Flag(a, "inCall"); click_through_ = Flag(a, "clickThrough");
      if (const auto* count = Field(a, "unreadCount")) {
        const auto number = count->LongValue(); unread_ = static_cast<int>(std::clamp<int64_t>(number, 0, 999));
      }
      UpdatePet();
      if (pet_) InvalidateRect(pet_, nullptr, FALSE);
    } else { result->NotImplemented(); return; }
    result->Success();
  } catch (const std::invalid_argument& error) { result->Error("invalid_arguments", error.what()); }
  catch (const winrt::hresult_error& error) { result->Error("windows_error", Utf8(error.message().c_str())); }
  catch (const std::exception& error) { result->Error("windows_error", error.what()); }
}
std::optional<LRESULT> PlatformIntegration::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == RegisterWindowMessageW(L"TaskbarCreated") && initialized_) {
    initialized_ = false;
    try { Initialize(); UpdatePet(); } catch (...) { Event("platformError"); }
    return 0;
  }
  if (message == WM_CLOSE && tray_) { ShowWindow(window_, SW_HIDE); return 0; }
  if (message == WM_HOTKEY && wparam == kHotkey) { Show(); Event("shortcut"); return 0; }
  if (message == WM_TIMER && wparam == kTimer) { UpdatePet(); return 0; }
  if (message == WM_WTSSESSION_CHANGE) {
    if (wparam == WTS_SESSION_LOCK) { session_locked_ = true; try { Lock(); } catch (...) { locked_ = true; UpdatePet(); Event("lock"); } }
    if (wparam == WTS_SESSION_UNLOCK) { session_locked_ = false; UpdatePet(); }
    return 0;
  }
  if (message == kTrayMessage) {
    if (lparam == WM_LBUTTONDBLCLK) Show();
    if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, 1, L"Show Jingyu");
      AppendMenuW(menu, MF_STRING, 2, L"Lock");
      AppendMenuW(menu, MF_STRING, 3, L"Log out");
      AppendMenuW(menu, MF_STRING | (click_through_ ? MF_CHECKED : 0), 5, L"Pet click-through");
      AppendMenuW(menu, MF_STRING, 4, L"Exit");
      POINT cursor{}; GetCursorPos(&cursor); SetForegroundWindow(window_);
      const UINT action = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, window_, nullptr);
      DestroyMenu(menu);
      try {
        if (action == 1) Show(); if (action == 2) { Lock(); Show(); }
        if (action == 3) { Logout(); Show(); }
        if (action == 4) PostQuitMessage(0);
        if (action == 5) { click_through_ = !click_through_; UpdatePet(); }
      } catch (...) { Event("lock"); }
    }
    return 0;
  }
  return std::nullopt;
}
LRESULT CALLBACK PlatformIntegration::PetProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<PlatformIntegration*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<PlatformIntegration*>(reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (!self) return DefWindowProcW(hwnd, message, wparam, lparam);
  if (message == WM_LBUTTONDBLCLK) { self->pet_visible_ = false; self->UpdatePet(); ShowWindow(self->window_, SW_HIDE); return 0; }
  if (message == WM_LBUTTONDOWN) { ReleaseCapture(); SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0); self->Event("petClick"); return 0; }
  if (message == WM_EXITSIZEMOVE) {
    RECT rect{}; GetWindowRect(hwnd, &rect); MONITORINFO monitor{sizeof(monitor)};
    GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
    const int left = rect.left - monitor.rcWork.left < monitor.rcWork.right - rect.right ? monitor.rcWork.left : monitor.rcWork.right - 88;
    const int top = std::clamp<int>(rect.top, monitor.rcWork.top, monitor.rcWork.bottom - 88);
    SetWindowPos(hwnd, HWND_TOPMOST, left, top, 88, 88, SWP_NOACTIVATE); return 0;
  }
  if (message == WM_PAINT) {
    PAINTSTRUCT ps{}; HDC dc = BeginPaint(hwnd, &ps); RECT rect{0,0,88,88};
    HBRUSH background = CreateSolidBrush(RGB(255,0,255)); FillRect(dc, &rect, background); DeleteObject(background);
    HBRUSH pet = CreateSolidBrush(RGB(34,166,178)); HGDIOBJ old = SelectObject(dc, pet);
    Ellipse(dc, 8, 20, 78, 78); SelectObject(dc, old); DeleteObject(pet);
    HBRUSH eye = CreateSolidBrush(RGB(255,255,255)); old = SelectObject(dc, eye);
    Ellipse(dc, 47, 34, 56, 43); SelectObject(dc, old); DeleteObject(eye);
    if (self->unread_ > 0) {
      HBRUSH bubble = CreateSolidBrush(RGB(193,47,68)); old = SelectObject(dc, bubble); Ellipse(dc, 47, 0, 87, 32); SelectObject(dc, old); DeleteObject(bubble);
      RECT count{47,0,87,32}; SetBkMode(dc, TRANSPARENT); SetTextColor(dc, RGB(255,255,255));
      std::wstring label = self->unread_ > 99 ? L"99+" : std::to_wstring(self->unread_);
      DrawTextW(dc, label.c_str(), -1, &count, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }
    EndPaint(hwnd, &ps); return 0;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}
