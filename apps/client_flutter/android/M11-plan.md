# M11 Android implementation plan

Goal: Android shell hooks for FR-09/11 and M11 without new dependencies.
Architecture: jingyu/platform MethodChannel coordinates Flutter with a remoteMessaging foreground service, incoming share intents, persistent call ids, Android notifications and native authentication. Dart owns the WebSocket and conversation selection.
Constraints: Android native files only; no commits; native verification through assembleDebug as delegated. Device permission/ROM behavior requires device validation.

- [x] Add manifest permissions, incoming SEND/SEND_MULTIPLE filters and service/receiver registration.
- [x] Implement channel initialize, PIN/biometric hooks, foreground service, outbound chooser and inbound shares.
- [x] Implement 30-second active-process call deadline, persistent call_id idempotence and best-effort AlarmManager process fallback, with 可能漏接 notification copy and private previews.
- [x] Run assembleDebug, inspect changes, and report exact build result and device limitations.

Interfaces: channel jingyu/platform; initialize returns platform, notificationPermission, biometricAvailable, pendingShare; shareReceived callback carries text/subject/mimeType/uris. hasPin/configurePin/unlockPin/unlockBiometric; setForegroundService(enabled); setMissedCall(callId,callerName,state,hidePreview); showShare(text,subject).
Review focus: notification denial must not crash; repeated calls must not reset deadline; answered calls must cancel timeout; shared URI read grants persist only where offered; existing PIN cannot be replaced without session authentication.

Native auth additions: removePin/lock/logout, getDataDirectory, storeSession(json)/readSession/clearSession. PIN accepts 4–12 ASCII digits and uses a salted verifier with 120,000 key-derivation iterations; five failed attempts trigger 30-second backoff. Session JSON uses AES-GCM Android Keystore. minSdk26; backup disabled.

Validation: manifest XML parses; git diff --check clean. No adb devices attached. Final `flutter build apk --debug` succeeded (86.5s, exit0), producing build/app/outputs/flutter-apk/app-debug.apk. Final combined assembleDebug also succeeded (54 actionable tasks, 17 executed, 37 up-to-date; 41s). Earlier compile failure from incorrect BiometricPrompt import was fixed; concurrent Dart helper export failure was fixed by parent. Explicit gradlew -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=7890 -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=7890 plus -Pkotlin.compiler.execution.strategy=in-process bypassed network and Kotlin-daemon environment issues.

Device acceptance still required: Android13 notification permission allow/deny; foreground service while screen off; incoming text share and conversation selection (Dart); biometric cancel/success/background; answered vs 30-second missed timeout; replayed call_id. Process-alive timeout uses monotonic clock and Handler. Process-death alarm is inexact under ROM/doze restrictions; notifications explicitly say 可能漏接. No overlay/fullscreen incoming call UI, notification quick reply, video background lifecycle, or binary URI import provided by this bridge. Service keeps the running Flutter WebSocket process eligible; it does not create a headless engine after Activity destruction.
