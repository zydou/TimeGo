import Foundation

/// Persists and retrieves daily session history as a JSON file in Application Support.
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [SessionRecord] = []
    /// Empty string means "all months".
    @Published var selectedMonth: String = ""

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "com.mdpi.TimeGo"
        let dir = appSupport.appendingPathComponent(bundleID, isDirectory: true)
        fileURL = dir.appendingPathComponent("session_history.json")
        load()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([SessionRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded.sorted { $0.dayKey > $1.dayKey }
    }

    private func save() {
        guard let data = try? encoder.encode(records) else { return }
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Archive a completed session. Replaces any existing record for the same dayKey.
    func archive(session: WorkSession, workHours: Double, lunchHours: Double) {
        let record = SessionRecord(
            dayKey: session.dayKey,
            startTime: session.startTime,
            endTime: session.endTime,
            clockOutSource: session.clockOutSource,
            source: session.source,
            workHours: workHours,
            lunchHours: lunchHours
        )
        if let index = records.firstIndex(where: { $0.dayKey == session.dayKey }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records.sort { $0.dayKey > $1.dayKey }
        save()
    }

    /// Returns the record for a specific day, if one exists.
    func record(for dayKey: String) -> SessionRecord? {
        records.first { $0.dayKey == dayKey }
    }

    /// Reload records from disk. Safe to call while the app is running.
    func reload() {
        load()
    }

    /// The most recent 365 records (≈1 year).
    var recentRecords: [SessionRecord] {
        Array(records.prefix(365))
    }

    /// Records filtered by the selected month, or all recent records.
    var filteredRecords: [SessionRecord] {
        guard !selectedMonth.isEmpty else { return recentRecords }
        return recentRecords.filter { $0.dayKey.hasPrefix(selectedMonth) }
    }

    /// Unique year-month strings (yyyy-MM) present in records, newest first.
    var availableMonths: [String] {
        let months = Set(records.map { String($0.dayKey.prefix(7)) })
        return months.sorted(by: >)
    }
}