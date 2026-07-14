import SwiftUI

/// Claude usage history — daily / weekly / monthly totals with a
/// per-project breakdown, driven by the UsageLog JSONL. Opened from
/// the Window menu (or ⌘⇧U).
struct UsageView: View {
    enum Period: String, CaseIterable, Identifiable {
        case daily = "Daily"
        case weekly = "Weekly"
        case monthly = "Monthly"
        var id: String { rawValue }

        var bucketCount: Int {
            switch self {
            case .daily:   return 14
            case .weekly:  return 8
            case .monthly: return 6
            }
        }

        var calendarComponent: Calendar.Component {
            switch self {
            case .daily:   return .day
            case .weekly:  return .weekOfYear
            case .monthly: return .month
            }
        }
    }

    @State private var period: Period = .daily
    @State private var records: [UsageLog.Record] = []

    private struct Bucket: Identifiable {
        let start: Date
        let label: String
        var inputTokens = 0
        var outputTokens = 0
        var costUsd = 0.0
        var id: Date { start }
    }

    private struct ProjectRow: Identifiable {
        let name: String
        let inputTokens: Int
        let outputTokens: Int
        let costUsd: Double
        var id: String { name }
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("", selection: $period) {
                    ForEach(Period.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                Spacer()
                Button {
                    records = UsageLog.loadAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Reload usage history")
            }

            // Current-period + all-time totals.
            HStack(spacing: 12) {
                statTile(title: currentPeriodTitle,
                         cost: currentBucket?.costUsd ?? 0,
                         input: currentBucket?.inputTokens ?? 0,
                         output: currentBucket?.outputTokens ?? 0)
                statTile(title: "All time",
                         cost: records.reduce(0) { $0 + $1.costUsd },
                         input: records.reduce(0) { $0 + $1.inputTokens },
                         output: records.reduce(0) { $0 + $1.outputTokens })
            }

            // Tokens per bucket, oldest → newest.
            VStack(alignment: .leading, spacing: 6) {
                Text("Tokens per \(period == .daily ? "day" : period == .weekly ? "week" : "month")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                barChart
            }

            // Per-project breakdown over the visible window.
            VStack(alignment: .leading, spacing: 6) {
                Text("By project (last \(period.bucketCount) \(period == .daily ? "days" : period == .weekly ? "weeks" : "months"))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if projectRows.isEmpty {
                    Text(records.isEmpty
                         ? "No usage recorded yet. History starts collecting from this version onward."
                         : "No usage in this window.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 12)
                } else {
                    projectTable
                }
            }

            // Per-model over the window — only once records carry models.
            if !modelRows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("By model (last \(period.bucketCount) \(period == .daily ? "days" : period == .weekly ? "weeks" : "months"))")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(Array(modelRows.enumerated()), id: \.element.id) { idx, row in
                            HStack {
                                Text(row.name.replacingOccurrences(of: "claude-", with: ""))
                                    .font(AppFont.mono(12))
                                Spacer()
                                Text("\(Self.tokens(row.inputTokens)) in · \(Self.tokens(row.outputTokens)) out")
                                    .font(AppFont.mono(11))
                                    .foregroundStyle(.secondary)
                                Text("≈ \(Self.money(row.costUsd))")
                                    .font(AppFont.mono(11.5))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 76, alignment: .trailing)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(idx.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
                }
            }

            // Session/weekly limit data isn't exposed outside the TUI —
            // the real bars live on claude.ai.
            Link("Plan limits on claude.ai", destination: URL(string: "https://claude.ai/settings/usage")!)
                .font(.system(size: 11))
        }
        .padding(20)
        }
        .frame(minWidth: 560, minHeight: 480)
        .onAppear { records = UsageLog.loadAll() }
    }

    private struct ModelRow: Identifiable {
        let name: String
        let inputTokens: Int
        let outputTokens: Int
        let costUsd: Double
        var id: String { name }
    }

    private var modelRows: [ModelRow] {
        guard let windowStart = bucketStarts.first else { return [] }
        var byModel: [String: (input: Int, output: Int, cost: Double)] = [:]
        for r in records where r.ts >= windowStart {
            guard let model = r.model, !model.isEmpty else { continue }
            var agg = byModel[model] ?? (0, 0, 0)
            agg.input += r.inputTokens
            agg.output += r.outputTokens
            agg.cost += r.costUsd
            byModel[model] = agg
        }
        return byModel
            .map { ModelRow(name: $0.key, inputTokens: $0.value.input,
                            outputTokens: $0.value.output, costUsd: $0.value.cost) }
            .sorted { $0.costUsd > $1.costUsd }
    }

    // MARK: - Derived data

    private var calendar: Calendar { Calendar.current }

    /// Bucket starts, oldest → newest, ending at the current period.
    private var bucketStarts: [Date] {
        let component = period.calendarComponent
        guard let currentStart = calendar.dateInterval(of: component, for: Date())?.start
        else { return [] }
        return (0..<period.bucketCount).compactMap {
            calendar.date(byAdding: component, value: -$0, to: currentStart)
        }.reversed()
    }

    private var buckets: [Bucket] {
        let starts = bucketStarts
        guard let windowStart = starts.first else { return [] }
        let component = period.calendarComponent
        let formatter = DateFormatter()
        formatter.dateFormat = period == .monthly ? "MMM" : "d MMM"

        var byStart: [Date: Bucket] = [:]
        for start in starts {
            let label = period == .weekly
                ? "wk \(formatter.string(from: start))"
                : formatter.string(from: start)
            byStart[start] = Bucket(start: start, label: label)
        }
        for r in records where r.ts >= windowStart {
            guard let start = calendar.dateInterval(of: component, for: r.ts)?.start,
                  var b = byStart[start] else { continue }
            b.inputTokens += r.inputTokens
            b.outputTokens += r.outputTokens
            b.costUsd += r.costUsd
            byStart[start] = b
        }
        return starts.compactMap { byStart[$0] }
    }

    private var currentBucket: Bucket? { buckets.last }

    private var currentPeriodTitle: String {
        switch period {
        case .daily:   return "Today"
        case .weekly:  return "This week"
        case .monthly: return "This month"
        }
    }

    private var projectRows: [ProjectRow] {
        guard let windowStart = bucketStarts.first else { return [] }
        var byProject: [String: (input: Int, output: Int, cost: Double)] = [:]
        for r in records where r.ts >= windowStart {
            let name = ProjectNaming.name(forCwd: r.cwd)
            var agg = byProject[name] ?? (0, 0, 0)
            agg.input += r.inputTokens
            agg.output += r.outputTokens
            agg.cost += r.costUsd
            byProject[name] = agg
        }
        return byProject
            .map { ProjectRow(name: $0.key, inputTokens: $0.value.input,
                              outputTokens: $0.value.output, costUsd: $0.value.cost) }
            .sorted { $0.costUsd > $1.costUsd }
    }

    // MARK: - Pieces

    private func statTile(title: String, cost: Double, input: Int, output: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(Self.tokens(input + output)) tokens")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Text("\(Self.tokens(input)) in · \(Self.tokens(output)) out")
                .font(AppFont.mono(11))
                .foregroundStyle(.secondary)
            Text("≈ \(Self.money(cost)) API value")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    private var barChart: some View {
        let data = buckets
        let maxTokens = max(data.map { $0.inputTokens + $0.outputTokens }.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(data) { b in
                let total = b.inputTokens + b.outputTokens
                VStack(spacing: 4) {
                    Text(total > 0 ? Self.tokens(total) : "")
                        .font(AppFont.mono(9))
                        .foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(b.start == data.last?.start
                              ? Color.brandOrange
                              : Color.brandOrange.opacity(0.45))
                        .frame(height: max(3, CGFloat(90 * total / maxTokens)))
                    Text(b.label)
                        .font(AppFont.mono(9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 130)
    }

    private var projectTable: some View {
        VStack(spacing: 0) {
            ForEach(Array(projectRows.enumerated()), id: \.element.id) { idx, row in
                HStack {
                    Text(row.name)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(Self.tokens(row.inputTokens)) in · \(Self.tokens(row.outputTokens)) out")
                        .font(AppFont.mono(11))
                        .foregroundStyle(.secondary)
                    Text("≈ \(Self.money(row.costUsd))")
                        .font(AppFont.mono(11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(idx.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
    }

    // MARK: - Formatting

    private static func money(_ v: Double, compact: Bool = false) -> String {
        if compact && v >= 100 { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }

    private static func tokens(_ n: Int) -> String {
        switch n {
        case ..<1_000:     return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1_000)
        default:           return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }
}
