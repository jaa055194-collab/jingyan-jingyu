#include "pin_store.h"
#include <iostream>
#include <stdexcept>

int main() {
  // Isolated target: this test never changes the application's real credential.
  PinStore store(L"com.jingyu.client.test.pin");
  store.Remove();
  if (store.HasPin() || store.Verify("1234")) return 1;
  store.Configure("123456");
  if (!store.HasPin() || !store.Verify("123456") || store.Verify("654321")) return 2;
  store.Configure("9876");
  if (store.Verify("123456") || !store.Verify("9876")) return 3;
  bool rejected = false;
  try { store.Configure("12ab"); } catch (const std::invalid_argument&) { rejected = true; }
  if (!rejected || !store.Verify("9876")) return 4;
  store.Remove();
  if (store.HasPin()) return 5;
  std::cout << "PIN credential roundtrip, rejection, replacement and removal passed\n";
}
