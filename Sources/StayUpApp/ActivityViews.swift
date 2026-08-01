import StayUpCore
import StayUpService
import SwiftUI

struct SessionsView: View {
    @Bindable var manager: SessionManager
    @Binding var selection: Set<LeaseID>
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if manager.leases.isEmpty {
                ContentUnavailableView(
                    "実行中のセッションはありません",
                    systemImage: "bolt.horizontal.circle",
                    description: Text("開始すると、どのプロセスがMacを起こしているかを確認できます。")
                )
            } else {
                Table(manager.leases, selection: $selection) {
                    TableColumn("名前") { lease in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lease.label.isEmpty ? lease.client.name : lease.label)
                            if !lease.label.isEmpty, lease.label != lease.client.name {
                                Text(lease.client.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .width(min: 150, ideal: 220)

                    TableColumn("開始") { lease in
                        Text(lease.acquiredAt, style: .time)
                    }
                    .width(min: 80, ideal: 100)

                    TableColumn("残り") { lease in
                        Text(remainingText(for: lease))
                            .monospacedDigit()
                    }
                    .width(min: 80, ideal: 110)

                    TableColumn("連動") { lease in
                        Text(lease.binding?.displayText ?? "—")
                            .foregroundStyle(lease.binding == nil ? .secondary : .primary)
                    }
                    .width(min: 100, ideal: 150)

                    TableColumn("更新") { lease in
                        Text(lease.renewCount.formatted())
                    }
                    .width(55)
                }
                .onDeleteCommand(perform: releaseSelection)
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Text("\(manager.leases.count)件のセッション")
                        Spacer()
                        if !selection.isEmpty {
                            Text("⌫で選択項目を解除")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.bar)
                }
            }
        }
        .onReceive(tick) { now = $0 }
        .onChange(of: manager.leases) {
            let liveIDs = Set(manager.leases.map(\.id))
            selection.formIntersection(liveIDs)
        }
    }

    private func remainingText(for lease: Lease) -> String {
        guard let remaining = lease.remainingSeconds(at: now) else { return "無期限" }
        return DurationParsing.formatShort(seconds: remaining)
    }

    private func releaseSelection() {
        let ids = selection
        selection.removeAll()
        Task {
            for id in ids {
                _ = await manager.release(
                    id: id,
                    requestedBy: .interactive(trigger: .window)
                )
            }
        }
    }
}

private struct HistoryRow: Identifiable {
    let id: Int
    let event: HistoryEvent
}

struct HistoryView: View {
    @Bindable var manager: SessionManager
    @State private var rows: [HistoryRow] = []
    private let store = HistoryStore()

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    "履歴はまだありません",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("セッションの開始と解除がここに記録されます。")
                )
            } else {
                Table(rows) {
                    TableColumn("日時") { row in
                        Text(row.event.ts.formatted(date: .abbreviated, time: .shortened))
                    }
                    .width(min: 130, ideal: 160)

                    TableColumn("イベント") { row in
                        Label(eventLabel(row.event.event), systemImage: eventSymbol(row.event.event))
                    }
                    .width(min: 120, ideal: 150)

                    TableColumn("クライアント") { row in
                        Text(row.event.client ?? "—")
                    }
                    .width(min: 100, ideal: 150)

                    TableColumn("理由") { row in
                        Text(reasonText(row.event.reason))
                            .foregroundStyle(row.event.reason == nil ? .secondary : .primary)
                    }

                    TableColumn("継続") { row in
                        Text(row.event.duration.map(DurationParsing.format) ?? "—")
                    }
                    .width(min: 70, ideal: 90)
                }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Text("最新\(rows.count)件")
                        Spacer()
                        Text("開始・解除・自動復元を記録")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.bar)
                }
            }
        }
        .task { reload() }
        .onChange(of: manager.leases) { reload() }
    }

    private func reload() {
        rows = store.recentEvents(limit: 300).enumerated().map {
            HistoryRow(id: $0.offset, event: $0.element)
        }
    }

    private func eventLabel(_ event: HistoryEvent.Kind) -> String {
        switch event {
        case .acquire: "開始"
        case .release: "解除"
        case .suppressionStarted: "抑止開始"
        case .suppressionEnded: "抑止終了"
        case .globalStop: "自動解除"
        case .helperError: "ヘルパーエラー"
        case .orphanDetected: "残留を検出"
        }
    }

    private func eventSymbol(_ event: HistoryEvent.Kind) -> String {
        switch event {
        case .acquire, .suppressionStarted: "play.fill"
        case .release, .suppressionEnded: "stop.fill"
        case .globalStop: "shield.fill"
        case .helperError, .orphanDetected: "exclamationmark.triangle.fill"
        }
    }

    private func reasonText(_ reason: String?) -> String {
        guard let reason else { return "—" }
        return ReleaseReason(rawValue: reason)?.localizedDescription ?? reason
    }
}
