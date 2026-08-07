import Foundation

@MainActor
final class SessionStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var settings: AppSettings
    @Published private(set) var session: WorkSession?

    private let defaults: UserDefaults
    private var dayBoundaryTimer: Timer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    static let sessionKey = "work.session"

    /// Session from a previous day that was cleared during init, waiting to be archived.
    private(set) var clearedYesterdaySession: WorkSession?

    /// Called when a session from a previous day is about to be discarded.
    var onArchiveSession: ((WorkSession) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: AppSettings.storageKey),
           let decoded = try? decoder.decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }

        if let data = defaults.data(forKey: Self.sessionKey),
           let decoded = try? decoder.decode(WorkSession.self, from: data) {
            session = decoded
            // Capture stale session before reconcileDayBoundary clears it
            if session?.dayKey != WorkSession.dayKey(for: .now) {
                clearedYesterdaySession = session
            }
        }

        reconcileDayBoundary()
        startDayBoundaryTimer()
    }

    var hasSessionToday: Bool {
        guard let session else { return false }
        return session.dayKey == WorkSession.dayKey(for: .now)
    }

    var startTime: Date? {
        hasSessionToday ? session?.startTime : nil
    }

    var workedDuration: TimeInterval {
        guard let startTime else { return 0 }
        return max(0, Date().timeIntervalSince(startTime))
    }

    var targetLeaveTime: Date? {
        guard let startTime else { return nil }
        return startTime.addingTimeInterval(settings.requiredOnSiteDuration)
    }

    var remainingDuration: TimeInterval {
        guard let targetLeaveTime else { return settings.requiredOnSiteDuration }
        return targetLeaveTime.timeIntervalSince(.now)
    }

    var overtimeDuration: TimeInterval {
        max(0, -remainingDuration)
    }

    var isPastTarget: Bool {
        remainingDuration <= 0 && hasSessionToday
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        var next = settings
        mutate(&next)
        settings = next
        persistSettings()
    }

    @discardableResult
    func start(at date: Date = .now, source: ClockInSource) -> Bool {
        reconcileDayBoundary()
        let day = WorkSession.dayKey(for: date)
        session = WorkSession(dayKey: day, startTime: date, source: source)
        persistSession()
        return true
    }

    /// - Parameter asManualSource: When correcting an existing session's time, keep the
    ///   original source unless the user explicitly marks it manual.
    func setStartTime(_ date: Date, asManualSource: Bool = true) {
        reconcileDayBoundary()
        if var current = session, current.dayKey == WorkSession.dayKey(for: date) {
            let sameMinute = Calendar.current.isDate(current.startTime, equalTo: date, toGranularity: .minute)
            if sameMinute { return }
            current.startTime = date
            if asManualSource {
                current.source = .manual
            }
            current.notifiedAtTarget = false
            current.notifiedEarly = false
            session = current
        } else {
            session = WorkSession(
                dayKey: WorkSession.dayKey(for: date),
                startTime: date,
                source: .manual
            )
        }
        persistSession()
    }

    func clearToday() {
        session = nil
        persistSession()
    }

    /// Record the end of the current session. Always overwrites any previous endTime.
    @discardableResult
    func endSession(at date: Date = .now, source: ClockOutSource) -> Bool {
        guard var current = session, current.dayKey == WorkSession.dayKey(for: date) else { return false }
        current.endTime = date
        current.clockOutSource = source
        session = current
        persistSession()
        return true
    }

    func markNotifiedAtTarget() {
        guard var current = session, current.dayKey == WorkSession.dayKey(for: .now) else { return }
        current.notifiedAtTarget = true
        session = current
        persistSession()
    }

    func markNotifiedEarly() {
        guard var current = session, current.dayKey == WorkSession.dayKey(for: .now) else { return }
        current.notifiedEarly = true
        session = current
        persistSession()
    }

    /// True when remaining time has reached the early-reminder mark (N:00 or less),
    /// and leave time has not been reached yet.
    var isInEarlyReminderWindow: Bool {
        guard settings.notifyEarlyReminder else { return false }
        guard hasSessionToday, remainingDuration > 0 else { return false }
        let lead = TimeInterval(settings.clampedEarlyReminderMinutes * 60)
        return remainingDuration <= lead
    }

    private func startDayBoundaryTimer() {
        scheduleNextDayBoundary()
    }

    /// Fires once near 06:00:01 (day boundary), then reschedules.
    private func scheduleNextDayBoundary() {
        dayBoundaryTimer?.invalidate()
        let cal = Calendar.current
        guard let next = cal.nextDate(
            after: Date(),
            matching: DateComponents(hour: WorkSession.dayBoundaryHour, minute: 0, second: 1),
            matchingPolicy: .nextTime
        ) else { return }
        let delay = max(5, next.timeIntervalSinceNow)
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            Task { @MainActor [weak self] in
                self?.reconcileDayBoundary()
                self?.scheduleNextDayBoundary()
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        dayBoundaryTimer = timer
    }

    /// Archives the previous day's session (if any) and clears it after the 06:00 day boundary.
    private func reconcileDayBoundary() {
        guard let session, session.dayKey != WorkSession.dayKey(for: .now) else { return }
        // Notify the observer (e.g. AppRuntime) to archive this session before discarding it.
        onArchiveSession?(session)
        clearedYesterdaySession = nil
        self.session = nil
        persistSession()
    }

    /// Re-arm the day-boundary timer after wake (system may have deferred it).
    func ensureDayBoundaryTimer() {
        scheduleNextDayBoundary()
    }

    private func persistSettings() {
        if let data = try? encoder.encode(settings) {
            defaults.set(data, forKey: AppSettings.storageKey)
        }
    }

    private func persistSession() {
        if let session, let data = try? encoder.encode(session) {
            defaults.set(data, forKey: Self.sessionKey)
        } else {
            defaults.removeObject(forKey: Self.sessionKey)
        }
    }
}
