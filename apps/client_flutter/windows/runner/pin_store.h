#ifndef RUNNER_PIN_STORE_H_
#define RUNNER_PIN_STORE_H_
#include <string>

// Only a DPAPI-protected salted verifier is persisted in Windows Credential Manager.
class PinStore {
 public:
  explicit PinStore(std::wstring target = L"com.jingyu.client.pin") : target_(std::move(target)) {}
  bool HasPin() const;
  void Configure(const std::string& pin) const;
  bool Verify(const std::string& pin) const;
  void Remove() const;
 private:
  std::wstring target_;
};
#endif
