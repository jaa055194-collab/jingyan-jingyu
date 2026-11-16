# M11 Flutter client shell — incomplete draft

Android/Windows Flutter shell with local package dependencies, durable client controllers and native adapters. New/existing account onboarding calls the host's invitation redemption/device login APIs, stores credentials through native protected storage, and isolates local snapshots by host/account/device. Access-token renewal preserves pending messages. This remains an incomplete draft: character/room persistence, attachment and native event integrations are unfinished. See [acceptance record](requirements-traceability.md).

Run with Flutter3.50 / Dart3.14, Android SDK36/JDK21 or Visual Studio2022 C++ BuildTools:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --debug
flutter build apk --debug
```

On Windows use a short checkout path (for example subst a drive) to avoid MSBuild MAX_PATH. Device PIN/session credentials use OS native protected storage; application snapshots go to the platform app directory. Trusted host identity requires server configuration `JINGYU_HOST_ACCOUNT_ID` and `JINGYU_HOST_DEVICE_ID` matching an authenticated administrator. Defaults fail closed.

Actual Before/After captures for the credential-onboarding increment are in [evidence](evidence/README.md); the earlier whole-shell comparison and image-capable visual review remain missing. No real-device acceptance is claimed. Native adapter availability does not mean all notification/pet/call/share events are connected. PR #8 requires explicit owner consent before merge; do not publish as completed M11.
