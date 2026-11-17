#include "pin_store.h"
#include <windows.h>
#include <wincred.h>
#include <bcrypt.h>
#include <wincrypt.h>
#include <array>
#include <algorithm>
#include <stdexcept>
#include <vector>

namespace {
constexpr ULONG kIterations = 600000;
struct Verifier { DWORD version; std::array<BYTE, 32> salt; std::array<BYTE, 32> hash; };
bool Valid(const std::string& pin) {
  return pin.size() >= 4 && pin.size() <= 12 &&
    std::all_of(pin.begin(), pin.end(), [](char c) { return c >= '0' && c <= '9'; });
}
std::array<BYTE,32> Derive(const std::string& pin, const std::array<BYTE,32>& salt) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, BCRYPT_ALG_HANDLE_HMAC_FLAG) < 0)
    throw std::runtime_error("Cannot open PIN KDF");
  std::array<BYTE,32> hash{};
  const NTSTATUS status = BCryptDeriveKeyPBKDF2(algorithm,
    reinterpret_cast<PUCHAR>(const_cast<char*>(pin.data())), static_cast<ULONG>(pin.size()),
    const_cast<PUCHAR>(salt.data()), static_cast<ULONG>(salt.size()), kIterations,
    hash.data(), static_cast<ULONG>(hash.size()), 0);
  BCryptCloseAlgorithmProvider(algorithm, 0);
  if (status < 0) throw std::runtime_error("Cannot derive PIN verifier");
  return hash;
}
}
bool PinStore::HasPin() const {
  PCREDENTIALW credential = nullptr;
  if (!CredReadW(target_.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
    if (GetLastError() == ERROR_NOT_FOUND) return false;
    throw std::runtime_error("Cannot read PIN credential");
  }
  CredFree(credential);
  return true;
}
void PinStore::Configure(const std::string& pin) const {
  if (!Valid(pin)) throw std::invalid_argument("PIN must contain 4 to 12 digits");
  Verifier record{};
  record.version = 1;
  if (BCryptGenRandom(nullptr, record.salt.data(), static_cast<ULONG>(record.salt.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0)
    throw std::runtime_error("Cannot generate PIN salt");
  record.hash = Derive(pin, record.salt);
  DATA_BLOB input{sizeof(record), reinterpret_cast<BYTE*>(&record)}, output{};
  if (!CryptProtectData(&input, L"Jingyu PIN verifier", nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output)) {
    SecureZeroMemory(&record, sizeof(record));
    throw std::runtime_error("Cannot protect PIN verifier");
  }
  CREDENTIALW credential{};
  credential.Type = CRED_TYPE_GENERIC;
  credential.TargetName = const_cast<wchar_t*>(target_.c_str());
  credential.UserName = const_cast<wchar_t*>(L"JingyuClient");
  credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
  credential.CredentialBlobSize = output.cbData;
  credential.CredentialBlob = output.pbData;
  const BOOL ok = CredWriteW(&credential, 0);
  SecureZeroMemory(&record, sizeof(record));
  SecureZeroMemory(output.pbData, output.cbData);
  LocalFree(output.pbData);
  if (!ok) throw std::runtime_error("Cannot save PIN credential");
}
bool PinStore::Verify(const std::string& pin) const {
  if (!Valid(pin)) return false;
  PCREDENTIALW credential = nullptr;
  if (!CredReadW(target_.c_str(), CRED_TYPE_GENERIC, 0, &credential)) {
    if (GetLastError() == ERROR_NOT_FOUND) return false;
    throw std::runtime_error("Cannot read PIN credential");
  }
  DATA_BLOB input{credential->CredentialBlobSize, credential->CredentialBlob}, output{};
  const BOOL ok = CryptUnprotectData(&input, nullptr, nullptr, nullptr, nullptr, CRYPTPROTECT_UI_FORBIDDEN, &output);
  CredFree(credential);
  if (!ok) throw std::runtime_error("Cannot decrypt PIN verifier");
  bool matches = false;
  if (output.cbData == sizeof(Verifier)) {
    auto* record = reinterpret_cast<Verifier*>(output.pbData);
    if (record->version == 1) {
      auto hash = Derive(pin, record->salt);
      BYTE difference = 0;
      for (size_t i=0; i<hash.size(); ++i) difference |= hash[i] ^ record->hash[i];
      matches = difference == 0;
      SecureZeroMemory(hash.data(), hash.size());
    }
  }
  SecureZeroMemory(output.pbData, output.cbData);
  LocalFree(output.pbData);
  return matches;
}
void PinStore::Remove() const {
  if (!CredDeleteW(target_.c_str(), CRED_TYPE_GENERIC, 0) && GetLastError() != ERROR_NOT_FOUND)
    throw std::runtime_error("Cannot remove PIN credential");
}
