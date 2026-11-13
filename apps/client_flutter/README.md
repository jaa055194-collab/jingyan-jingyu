# M11 Flutter client shell — incomplete draft

Android/Windows Flutter shell with local package dependencies, durable client controllers and native adapters. This is not a usable release: the current host lacks invitation/device-login, conversation-list, character and room-persistence contracts. Connection deliberately reports unavailable. See [acceptance record](requirements-traceability.md) for all remaining items.

Run with Flutter3.50 / Dart3.14, Android SDK36/JDK21 or Visual Studio2022 C++ BuildTools:

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --debug
flutter build apk --debug
```

On Windows use a short checkout path (for example subst a drive) to avoid MSBuild MAX_PATH. Device PIN/session credentials use OS native protected storage; application snapshots go to the platform app directory. Trusted host identity requires server configuration `JINGYU_HOST_ACCOUNT_ID` and `JINGYU_HOST_DEVICE_ID` matching an authenticated administrator. Defaults fail closed.

No actual Before/After captures or device acceptance are available. Native adapter availability does not mean all notification/pet/call/share runtime events are connected. Do not merge or publish as completed M11.
