import SwiftUI
import AppKit
import UserNotifications

@main
struct TimeGoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: SessionStore
    @StateObject private var runtime: AppRuntime

    init() {
        let store = SessionStore()
        let wake = WakeMonitor()
        _store = StateObject(wrappedValue: store)
        _runtime = StateObject(wrappedValue: AppRuntime(store: store, wake: wake))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(store)
                .environmentObject(L10n.shared)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
                .environmentObject(L10n.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppRuntime: ObservableObject {
    private let store: SessionStore
    private let wake: WakeMonitor
    private var notificationTask: Task<Void, Never>?
    /// Blocks session-publisher resync while markNotified* is writing flags.
    private var isMutatingNotifyFlags = false

    init(store: SessionStore, wake: WakeMonitor) {
        self.store = store
        self.wake = wake
        Task { await self.start() }
    }

    private func start() async {
        SettingsPanelController.shared.configure(store: store)
        L10n.shared.apply(store.settings.language)

        // Install a stable ~/Applications copy first, then repair login items that may
        // still point at a deleted Xcode DerivedData path (app appears not to launch).
        _ = await NotificationIconRegistrar.syncForNotificationCenter()
        LaunchAtLoginService.shared.sync(withPreferred: store.settings.launchAtLogin)
        MenuBarClock.shared.start()

        // Refresh status only; permission prompts are requested from the settings window.
        await NotificationService.shared.refreshAuthorizationStatus()

        // Auto clock-in on wake/unlock (office computer never leaves the office)
        wake.onEvent = { [weak self] event in
            self?.store.ensureDayBoundaryTimer()
            self?.handlePresence(event)
            self?.checkMissedNotifications()
        }
        wake.start()

        // Resync notifications when session changes
        NotificationService.shared.onWorkNotificationDelivered = { [weak self] id in
            self?.handleSystemDelivered(id)
        }

        scheduleResyncNotifications()
        checkMissedNotifications()
    }

    private func handlePresence(_ event: PresenceEvent) {
        guard !store.hasSessionToday else { return }
        let source: ClockInSource = (event == .wake) ? .wake : .unlock
        store.start(source: source)
        scheduleResyncNotifications()
    }

    private func handleSystemDelivered(_ identifier: String) {
        isMutatingNotifyFlags = true
        defer { isMutatingNotifyFlags = false }

        switch identifier {
        case NotificationService.earlyID:
            if store.session?.notifiedEarly != true {
                store.markNotifiedEarly()
            }
        case NotificationService.targetID:
            if store.session?.notifiedAtTarget != true {
                store.markNotifiedAtTarget()
            }
        default:
            break
        }
    }

    private func scheduleResyncNotifications() {
        notificationTask?.cancel()
        notificationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            self.performResyncNotifications()
        }
    }

    private func performResyncNotifications() {
        let settings = store.settings
        let notifications = NotificationService.shared

        guard settings.notificationsEnabled,
              let leave = store.targetLeaveTime,
              store.hasSessionToday else {
            notifications.cancelPending()
            return
        }

        let wantTarget = settings.notifyWhenDone && store.session?.notifiedAtTarget != true
        let wantEarly = settings.notifyEarlyReminder
            && store.session?.notifiedEarly != true
            && store.session?.notifiedAtTarget != true

        notifications.cancelPending()

        if wantTarget, leave > .now {
            notifications.scheduleTargetNotification(
                at: leave,
                workHours: settings.workHours,
                lunchHours: settings.lunchHours
            )
        }
        if wantEarly {
            let minutes = settings.clampedEarlyReminderMinutes
            let earlyAt = leave.addingTimeInterval(TimeInterval(-minutes * 60))
            if earlyAt > .now {
                notifications.scheduleEarlyNotification(
                    at: earlyAt,
                    leaveTime: leave,
                    minutes: minutes
                )
            }
        }

        checkMissedNotifications()
    }

    private func checkMissedNotifications() {
        let settings = store.settings
        guard settings.notificationsEnabled else { return }
        guard store.hasSessionToday else { return }
        guard let leave = store.targetLeaveTime else { return }

        let notifications = NotificationService.shared
        let grace: TimeInterval = 3
        let now = Date()

        if settings.notifyEarlyReminder,
           store.session?.notifiedEarly != true,
           store.session?.notifiedAtTarget != true {
            let minutes = settings.clampedEarlyReminderMinutes
            let earlyAt = leave.addingTimeInterval(TimeInterval(-minutes * 60))
            if now >= earlyAt.addingTimeInterval(grace) {
                isMutatingNotifyFlags = true
                store.markNotifiedEarly()
                isMutatingNotifyFlags = false
                notifications.cancelEarlyPending()
                notifications.notifyEarlyReminder(leaveTime: leave, minutes: minutes)
            }
        }

        if settings.notifyWhenDone,
           store.session?.notifiedAtTarget != true,
           now >= leave.addingTimeInterval(grace) {
            isMutatingNotifyFlags = true
            store.markNotifiedAtTarget()
            isMutatingNotifyFlags = false
            notifications.cancelPending()
            notifications.notifyTargetReached(
                leaveTime: leave,
                workHours: settings.workHours,
                lunchHours: settings.lunchHours
            )
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Clicking a banner often launches ~/Applications/TimeGo.app even when another
        // TimeGo (e.g. Xcode build) is already running — that adds a second menu-bar icon.
        // Bail out before SwiftUI installs another MenuBarExtra.
        if Self.activateExistingInstanceIfNeeded() {
            _exit(0)
        }

        // Hide Dock without LSUIElement in Info.plist, so Launch Services still
        // registers a real app icon for Notification Center (left-side logo).
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar apps have no windows; without this, macOS may auto-quit overnight.
        ProcessInfo.processInfo.disableAutomaticTermination("TimeGo menu bar stays resident")
        ProcessInfo.processInfo.disableSuddenTermination()
        UNUserNotificationCenter.current().delegate = self
    }

    // nonisolated: UNNotification* types are not Sendable; hop to MainActor with a String id.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let identifier = notification.request.identifier
        await Self.noteDelivered(identifier)
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        await Self.noteDelivered(identifier)
    }

    @MainActor
    private static func noteDelivered(_ identifier: String) {
        NotificationService.shared.noteWorkNotificationDelivered(identifier: identifier)
    }

    /// - Returns: `true` when another TimeGo process already owns this bundle id.
    private static func activateExistingInstanceIfNeeded() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let existing = others.first else { return false }
        existing.activate()
        return true
    }
}
