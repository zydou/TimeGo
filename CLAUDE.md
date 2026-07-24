# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

TimeGo is a macOS menu-bar app (SwiftUI + AppKit) for tracking flexible work hours. It auto-clocks-in when you unlock/wake your Mac, counts down to a leave time (work hours + lunch), and sends a notification when you can leave. Deployment target: macOS 13.0+ (tested on macOS 13.7.8 + Xcode 15.4).

- Bundle ID: `com.mdpi.TimeGo`
- No third-party dependencies — pure Apple frameworks (SwiftUI, AppKit, UserNotifications, ServiceManagement).
- Ad-hoc signed (`CODE_SIGN_IDENTITY = "-"`); no App Store, distributed via GitHub Releases zip.
- App sandbox **disabled** (entitlements) — required for `SMAppService` login items.
- Universal binary: supports both Intel (x86_64) and Apple Silicon (arm64).

## Build & Run

```bash
# Build (debug, ad-hoc signed)
xcodebuild -project TimeGo.xcodeproj -scheme TimeGo -configuration Debug \
  -destination "platform=macOS" CODE_SIGN_IDENTITY="-" build

# Build + package a release zip (universal binary, outputs to dist/)
./scripts/package_release.sh
```

## Architecture

### App entry & lifecycle (`TimeGo/TimeGoApp.swift`)

- `TimeGoApp` (`@main`) injects two `@StateObject`s — `SessionStore`, `AppRuntime` — and declares a `MenuBarExtra` scene (`MenuBarView` + `MenuBarLabel`).
- `AppRuntime` (`@MainActor`) is the startup orchestrator: configures `SettingsPanelController`, applies language, syncs the stable `~/Applications` copy + login item, starts `MenuBarClock`, then sets up wake/unlock auto clock-in and notification scheduling.
- `AppDelegate` handles single-instance enforcement (activates existing TimeGo and `_exit(0)` to avoid duplicate menu-bar icons), sets `.accessory` activation policy (no Dock icon, but real app icon for Notification Center), disables automatic termination (so macOS doesn't quit it overnight), and routes notification delivery callbacks.

### State model

All mutable state lives in `@MainActor ObservableObject` services exposed to views via `.environmentObject(...)`.

- **`SessionStore`** — single source of truth. `@Published settings: AppSettings` and `@Published session: WorkSession?`. Persists both to `UserDefaults` as JSON (keys `app.settings`, `work.session`). Owns a midnight timer that clears the previous day's session. Derived: `hasSessionToday`, `workedDuration`, `targetLeaveTime`, `remainingDuration`, `overtimeDuration`, `isPastTarget`, `isInEarlyReminderWindow`.
- **`AppSettings`** (struct, `Codable`) — workHours, lunchHours, notification prefs, launchAtLogin, language, companyOAURL. `requiredOnSiteDuration = work + lunch`.
- **`WorkSession`** (struct, `Codable`) — dayKey (`yyyy-MM-dd`), startTime, source (`manual`/`unlock`/`wake`), and two notification-sent flags.

### Auto clock-in

Simple wake/unlock-based auto clock-in:

1. `WakeMonitor` observes `NSWorkspace.didWakeNotification` and `com.apple.screenIsUnlocked`
2. On either event, if no session today → `store.start(source: .wake)` or `store.start(source: .unlock)`
3. After any start, `scheduleResyncNotifications()` re-arms the two pending notifications (target + early)

### Notifications

`NotificationService` (`UNUserNotificationCenter`, singleton) schedules two `UNCalendarNotificationTrigger` requests with stable IDs (`timego.target.reached`, `timego.target.early`). `checkMissedNotifications()` posts at most one immediate banner when a scheduled fire was missed (e.g. Mac was asleep). Delivery callbacks flow `AppDelegate` → `NotificationService.noteWorkNotificationDelivered` → `AppRuntime.handleSystemDelivered` → `store.markNotified*`, guarded by `isMutatingNotifyFlags` to avoid feedback loops.

### Other services

- **`SettingsPanelController`** — owns a non-deactivating `NSPanel` hosting `SettingsView`. Temporarily flips `NSApp.setActivationPolicy(.regular)` to show a real window, back to `.accessory` on close.
- **`LaunchAtLoginService`** — wraps `SMAppService.mainApp`; `sync(withPreferred:)` repairs `.notFound` registrations (stale DerivedData path).
- **`NotificationIconRegistrar`** — copies the running bundle to `~/Applications/TimeGo.app` and calls `LSRegisterURL` so Notification Center resolves a real app icon (Xcode DerivedData builds show a gray square otherwise).
- **`L10n`** — singleton with zh/en string tables; `t(key)` / `t(key, args...)`. Effective code `zh-Hans` or `en`.

### Views

- `MenuBarLabel` — menu-bar title (icon + remaining/overtime via `DurationFormat.short`).
- `MenuBarView` — the popover: progress ring, stats, time controls, footer. Uses `PanelLiveClock` (1 Hz) while open.
- `SettingsView` — language, OA URL, hours, notifications. Saves via `store.updateSettings`.
- `HourMinuteField` — tap-to-edit `HH:mm` control with hour→minute autofocus.
- `DurationFormat` — `clock` (H:MM:SS), `short` (H:MM, ceiling-rounded), `time`/`timeWithSeconds` (formatters).
- `TimeGoTheme` — accent/overtime colors, dark-aware `ink`, panel background gradient, reusable components (`SoftDivider`, `MetaRow`, `PermissionBadge`, button styles).

## Conventions

- All services are `@MainActor`; the whole app runs on the main actor. `L10n.shared` is a plain `static let` — always read on main actor in practice.
- UserDefaults persistence is JSON-encoded structs, not raw values.
- Localization keys live in the zh/en tables in `Localization.swift`; add to both tables for any new string.
- Commit messages are in Chinese.
- `scripts/` contains the release packager — not part of the Xcode target.
- **Commit message pitfall**: Do NOT use `git commit -m "$(cat <<'EOF' ... EOF)"` — the `EOF` delimiter and `)` can leak into the commit message when executed via Claude Code's Bash tool. This is a known issue with how the tool processes heredocs, not related to shell configuration. Use a plain string with `-m "..."` instead.

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
