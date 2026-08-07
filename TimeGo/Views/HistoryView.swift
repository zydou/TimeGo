import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var historyStore: HistoryStore
    @EnvironmentObject private var l10n: L10n
    @ObservedObject private var liveClock = PanelLiveClock.shared

    var onClose: (() -> Void)?

    var body: some View {
        // Refresh the view while the panel is open.
        let _ = liveClock.now

        ZStack {
            TimeGoTheme.panelBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 22)
                    .padding(.top, 18)
                    .padding(.bottom, 12)

                SoftDivider()
                    .padding(.horizontal, 22)

                if historyStore.records.isEmpty {
                    emptyState
                } else {
                    columnHeaders
                        .padding(.horizontal, 26)
                        .padding(.top, 14)
                        .padding(.bottom, 6)

                    recordsList
                }
            }
        }
        .frame(width: 520, height: 480)
        .id(l10n.code)
        .onAppear { liveClock.retain() }
        .onDisappear { liveClock.release() }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(l10n.t("history.title"))
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(TimeGoTheme.ink)
                Spacer()
                monthPicker
            }
            if let total = summaryLine {
                HStack {
                    Text(total)
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(TimeGoTheme.secondary)
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
    }

    private var summaryLine: String? {
        let completed = historyStore.filteredRecords.filter(\.isComplete)
        guard !completed.isEmpty else { return nil }
        let totalOvertime = completed.reduce(0.0) { $0 + $1.overtimeDuration }
        let days = completed.count
        let avg = completed.reduce(0.0) { $0 + $1.workedDuration } / Double(days)
        return l10n.t("history.summary", "\(days)", DurationFormat.short(avg), DurationFormat.short(totalOvertime))
    }

    private var monthPicker: some View {
        Picker("", selection: $historyStore.selectedMonth) {
            Text(l10n.t("history.allMonths")).tag("")
            ForEach(historyStore.availableMonths, id: \.self) { month in
                Text(monthLabel(for: month)).tag(month)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
    }

    private func monthLabel(for month: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM"
        guard let date = fmt.date(from: month + "-01") else { return month }
        let df = DateFormatter()
        df.locale = l10n.locale
        df.setLocalizedDateFormatFromTemplate("yMMMM")
        return df.string(from: date)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(TimeGoTheme.secondary.opacity(0.5))
            Text(l10n.t("history.empty"))
                .font(.system(.body, design: .rounded).weight(.medium))
                .foregroundStyle(TimeGoTheme.secondary)
            Text(l10n.t("history.emptyHint"))
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(TimeGoTheme.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Text(l10n.t("history.date"))
                .frame(width: 120, alignment: .leading)
            Spacer().frame(width: 8)
            Text(l10n.t("history.clockIn"))
                .frame(width: 60, alignment: .trailing)
            Spacer().frame(width: 20)
            Text(l10n.t("history.clockOut"))
                .frame(width: 60, alignment: .trailing)
            Spacer().frame(width: 12)
            Text(l10n.t("history.duration"))
                .frame(width: 70, alignment: .trailing)
            Spacer().frame(width: 12)
            Text(l10n.t("history.overtime"))
                .frame(width: 60, alignment: .trailing)
        }
        .font(.system(.caption2, design: .rounded).weight(.semibold))
        .foregroundStyle(TimeGoTheme.secondary)
        .textCase(.uppercase)
        .tracking(0.5)
        .padding(.horizontal, 4)
    }

    private var recordsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(historyStore.filteredRecords) { record in
                    RecordRow(record: record)
                    if record.dayKey != historyStore.filteredRecords.last?.dayKey {
                        SoftDivider()
                            .padding(.horizontal, 4)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 4)
        }
    }
}

private struct RecordRow: View {
    let record: SessionRecord

    private var dateDisplay: (date: String, weekday: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        if let date = fmt.date(from: record.dayKey) {
            let wf = DateFormatter()
            wf.locale = L10n.shared.locale
            wf.dateFormat = "EEE"
            return (record.dayKey, wf.string(from: date))
        }
        return (record.dayKey, "")
    }

    var body: some View {
        HStack(spacing: 0) {
            // Date + weekday
            HStack(spacing: 4) {
                Text(dateDisplay.date)
                Text(dateDisplay.weekday)
                    .foregroundStyle(TimeGoTheme.secondary)
            }
            .font(.system(.caption, design: .rounded).weight(.medium))
            .foregroundStyle(TimeGoTheme.ink)
            .frame(width: 120, alignment: .leading)

            Spacer().frame(width: 8)

            // Clock-in
            Text(DurationFormat.time.string(from: record.startTime))
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(TimeGoTheme.ink)
                .frame(width: 60, alignment: .trailing)

            // Arrow
            Text("→")
                .font(.caption)
                .foregroundStyle(TimeGoTheme.secondary)
                .frame(width: 20)

            // Clock-out
            Text(record.isComplete
                 ? DurationFormat.time.string(from: record.endTime!)
                 : "—")
                .font(.system(.subheadline, design: .rounded).weight(.medium))
                .foregroundStyle(record.isComplete ? TimeGoTheme.ink : TimeGoTheme.secondary)
                .frame(width: 60, alignment: .trailing)

            Spacer().frame(width: 12)

            // Duration
            Text(record.isComplete
                 ? DurationFormat.clock(record.workedDuration)
                 : "—")
                .font(.system(.subheadline, design: .rounded).monospacedDigit())
                .foregroundStyle(TimeGoTheme.ink)
                .frame(width: 70, alignment: .trailing)

            Spacer().frame(width: 12)

            // Overtime
            HStack(spacing: 2) {
                if record.isComplete && record.overtimeDuration > 0 {
                    Text("+")
                        .font(.caption)
                    Text(DurationFormat.short(record.overtimeDuration))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold).monospacedDigit())
                } else if record.isComplete {
                    Text("0:00")
                        .font(.system(.caption, design: .rounded))
                } else {
                    Text("—")
                        .font(.system(.subheadline, design: .rounded))
                }
            }
            .foregroundStyle(record.overtimeDuration > 0 ? TimeGoTheme.overtime : TimeGoTheme.secondary)
            .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
    }
}