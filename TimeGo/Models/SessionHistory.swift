import Foundation

/// An archived daily work session record, persisted to the history store.
struct SessionRecord: Codable, Equatable, Identifiable {
    var id: String { dayKey }

    let dayKey: String
    let startTime: Date
    let endTime: Date?
    let clockOutSource: ClockOutSource?
    let source: ClockInSource
    /// The effective work hours setting at the time of archiving.
    let workHours: Double
    /// The effective lunch hours setting at the time of archiving.
    let lunchHours: Double

    /// Total elapsed time between start and end (0 if endTime is unknown).
    var workedDuration: TimeInterval {
        guard let endTime else { return 0 }
        return max(0, endTime.timeIntervalSince(startTime))
    }

    /// Target work duration based on the recorded setting.
    var targetDuration: TimeInterval {
        workHours * 3600
    }

    /// Wall-clock time from start to leave time (work + lunch).
    var requiredOnSiteDuration: TimeInterval {
        workHours * 3600 + max(0, lunchHours * 3600)
    }

    /// Positive overtime when worked duration exceeds the required on-site duration.
    var overtimeDuration: TimeInterval {
        max(0, workedDuration - requiredOnSiteDuration)
    }

    /// Whether this record has a known end time.
    var isComplete: Bool {
        endTime != nil
    }

    // MARK: - Human-readable date encoding

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return fmt
    }()

    enum CodingKeys: String, CodingKey {
        case dayKey, startTime, endTime, clockOutSource, source, workHours, lunchHours
    }

    /// Memberwise initializer, used by HistoryStore.archive.
    init(dayKey: String, startTime: Date, endTime: Date?, clockOutSource: ClockOutSource?, source: ClockInSource, workHours: Double, lunchHours: Double) {
        self.dayKey = dayKey
        self.startTime = startTime
        self.endTime = endTime
        self.clockOutSource = clockOutSource
        self.source = source
        self.workHours = workHours
        self.lunchHours = lunchHours
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dayKey = try container.decode(String.self, forKey: .dayKey)

        let startString = try container.decode(String.self, forKey: .startTime)
        guard let start = Self.dateFormatter.date(from: startString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .startTime, in: container,
                debugDescription: "Expected date format yyyy-MM-dd HH:mm:ss Z, got \"\(startString)\""
            )
        }
        startTime = start

        if let endString = try container.decodeIfPresent(String.self, forKey: .endTime) {
            guard let end = Self.dateFormatter.date(from: endString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .endTime, in: container,
                    debugDescription: "Expected date format yyyy-MM-dd HH:mm:ss Z, got \"\(endString)\""
                )
            }
            endTime = end
        } else {
            endTime = nil
        }

        clockOutSource = try container.decodeIfPresent(ClockOutSource.self, forKey: .clockOutSource)
        source = try container.decode(ClockInSource.self, forKey: .source)
        workHours = try container.decode(Double.self, forKey: .workHours)
        lunchHours = try container.decode(Double.self, forKey: .lunchHours)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dayKey, forKey: .dayKey)
        try container.encode(Self.dateFormatter.string(from: startTime), forKey: .startTime)
        try container.encodeIfPresent(endTime.map { Self.dateFormatter.string(from: $0) }, forKey: .endTime)
        try container.encodeIfPresent(clockOutSource, forKey: .clockOutSource)
        try container.encode(source, forKey: .source)
        try container.encode(workHours, forKey: .workHours)
        try container.encode(lunchHours, forKey: .lunchHours)
    }
}