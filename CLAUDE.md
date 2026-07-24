# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TimeGo is a macOS menu-bar app (SwiftUI + AppKit) for tracking flexible work hours. It auto-clocks-in when you connect to company Wi-Fi/IP (or unlock/wake at the office), counts down to a leave time (work hours + lunch), and sends a notification when you can leave. Deployment target: macOS 13.0+ (tested on macOS 13.7.8 + Xcode 15.4).

- Bundle ID: `com.mdpi.TimeGo`
- No third-party dependencies — pure Apple frameworks (SwiftUI, AppKit, Network, CoreWLAN, CoreLocation, UserNotifications, ServiceManagement).
- Ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`); no App Store, distributed via GitHub Releases zip.
- App sandbox **disabled** (entitlements) — required for `SMAppService` login items.

## Build & Run

```bash
# Build (debug, ad-hoc signed)
xcodebuild -project TimeGo.xcodeproj -scheme TimeGo -configuration Debug \
  -destination "platform=macOS" CODE_SIGN_IDENTITY="-" build

# Build + package a release zip (signs, notarizes nothing, outputs to dist/)
./scripts/package_release.sh
```

There is no XCTest target. The only automated check is a standalone Swift script that exercises the network-matching logic:

```bash
swift scripts/test_network_clockin.swift
```

## Architecture

### App entry & lifecycle (`TimeGo/TimeGoApp.swift`)

- `TimeGoApp` (`@main`) injects three `@StateObject`s — `SessionStore`, `NetworkMonitor`, `AppRuntime` — and declares a `MenuBarExtra` scene (`MenuBarView` + `MenuBarLabel`).
- `AppRuntime` (`@MainActor`) is the startup orchestrator: configures `SettingsPanelController`, applies language, syncs the stable `~/Applications` copy + login item, starts `MenuBarClock`, then creates and starts `AutoClockInService`.
- `AppDelegate` handles single-instance enforcement (activates existing TimeGo and `_exit(0)` to avoid duplicate menu-bar icons), sets `.accessory` activation policy (no Dock icon, but real app icon for Notification Center), disables automatic termination (so macOS doesn't quit it overnight), and routes notification delivery callbacks.

### State model

All mutable state lives in `@MainActor ObservableObject` services exposed to views via `.environmentObject(...)`. The Combine pipeline is the primary wiring mechanism.

- **`SessionStore`** — single source of truth. `@Published settings: AppSettings` and `@Published session: WorkSession?`. Persists both to `UserDefaults` as JSON (keys `app.settings`, `work.session`). Owns a midnight timer that clears the previous day's session. Derived: `hasSessionToday`, `workedDuration`, `targetLeaveTime`, `remainingDuration`, `overtimeDuration`, `isPastTarget`, `isInEarlyReminderWindow`.
- **`AppSettings`** (struct, `Codable`) — workHours, lunchHours, companySSIDs, companyIPPrefixes, notification prefs, requireCompanyNetworkForWake, launchAtLogin, language, companyOAURL. `requiredOnSiteDuration = work + lunch`.
- **`WorkSession`** (struct, `Codable`) — dayKey (`yyyy-MM-dd`), startTime, source (`manual`/`unlock`/`wake`/`network`), and two notification-sent flags.

### Auto clock-in pipeline

`AutoClockInService` subscribes to `NetworkMonitor.$snapshot`, `WakeMonitor.onEvent`, `SessionStore.$settings`, and `$session` via Combine sinks:

1. **Network** → `NetworkClockInGate` (rising-edge: fires only on the off→on transition of "is on company network", and only if no session today and network rules exist) → `store.start(source: .network)`.
2. **Wake/unlock** (`WakeMonitor` observes `NSWorkspace.didWakeNotification` and `com.apple.screenIsUnlocked`) → if no session today and (no network rules, or already on company network when `requireCompanyNetworkForWake`) → `store.start`.
3. After any start, `scheduleResyncNotifications()` re-arms the two pending notifications (target + early).

`CompanyNetworkMatcher` is a pure function: matches if SSID is in the company list (case-insensitive) OR any local IPv4 has a company prefix. `NetworkMonitor` refreshes on NWPath updates + a 300s poll, reads SSID via `CWWiFiClient` (requires location auth), and enumerates IPv4s via `getifaddrs` (filters `en*`/`bridge*`/`wlan0`).

### Notifications

`NotificationService` (`UNUserNotificationCenter`, singleton) schedules two `UNCalendarNotificationTrigger` requests with stable IDs (`timego.target.reached`, `timego.target.early`). `checkMissedNotifications()` posts at most one immediate banner when a scheduled fire was missed (e.g. Mac was asleep). Delivery callbacks flow `AppDelegate` → `NotificationService.noteWorkNotificationDelivered` → `AutoClockInService.handleSystemDelivered` → `store.markNotified*`, guarded by `isMutatingNotifyFlags` to avoid feedback loops with the `$session` sink.

### Other services

- **`SettingsPanelController`** — owns a non-deactivating `NSPanel` hosting `SettingsView`. Temporarily flips `NSApp.setActivationPolicy(.regular)` to show a real window, back to `.accessory` on close.
- **`LaunchAtLoginService`** — wraps `SMAppService.mainApp`; `sync(withPreferred:)` repairs `.notFound` registrations (stale DerivedData path).
- **`NotificationIconRegistrar`** — copies the running bundle to `~/Applications/TimeGo.app` and calls `LSRegisterURL` so Notification Center resolves a real app icon (Xcode DerivedData builds show a gray square otherwise).
- **`LocationAuthService`** — `CLLocationManager` for Wi-Fi SSID access.
- **`L10n`** — `nonisolated(unsafe)` singleton with zh/en string tables; `t(key)` / `t(key, args...)`. Effective code `zh-Hans` or `en`.

### Views

- `MenuBarLabel` — menu-bar title (icon + remaining/overtime via `DurationFormat.short`).
- `MenuBarView` — the popover: progress ring, stats, time controls, network status, footer. Uses `PanelLiveClock` (1 Hz) while open.
- `SettingsView` — language, OA URL, hours, notifications, network. Saves via `store.updateSettings`.
- `HourMinuteField` — tap-to-edit `HH:mm` control with hour→minute autofocus.
- `DurationFormat` — `clock` (H:MM:SS), `short` (H:MM, ceiling-rounded), `time`/`timeWithSeconds` (formatters).
- `TimeGoTheme` — accent/overtime colors, dark-aware `ink`, panel background gradient, reusable components (`SoftDivider`, `MetaRow`, `PermissionBadge`, button styles).

## Conventions

- All services are `@MainActor`; the whole app runs on the main actor. `L10n.shared` is `nonisolated(unsafe)` — always read on main actor in practice.
- UserDefaults persistence is JSON-encoded structs, not raw values.
- Localization keys live in the zh/en tables in `Localization.swift`; add to both tables for any new string.
- Commit messages are in Chinese.
- `scripts/` contains the release packager and the network-matcher sanity check — not part of the Xcode target.

### Swift concurrency (Xcode 15.4+)

Xcode 15.4 enables stricter Swift concurrency checking. `Timer` and notification-center closures are `@Sendable` — capturing `self` (even weakly) in the outer closure triggers `reference to captured var 'self' in concurrently-executing code`. Fix pattern:

```swift
// ❌ Error
Timer(timeInterval: 1, repeats: true) { [weak self] _ in
    Task { @MainActor in self?.doWork() }
}
// ✅ Correct
Timer(timeInterval: 1, repeats: true) { _ in
    Task { @MainActor [weak self] in self?.doWork() }
}
```

`SWIFT_STRICT_CONCURRENCY = minimal` does NOT fix this — the code must change.

### macOS 13 API restrictions

The deployment target is macOS 13.0. These SwiftUI APIs are **macOS 14+ only** and must be avoided:

- `.onChange(of:initial:_:)` — use `.onChange(of:) { newValue in }` (single param)
- `.onKeyPress(_:action:)` — use `.onSubmit` or `NSEvent` monitors instead
