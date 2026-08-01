import StayUpCore
import StayUpService
import SwiftUI

struct OverviewView: View {
    @Bindable var manager: SessionManager
    let helperStatus: HelperStatus
    let onConfigureHelper: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    StatusHero(manager: manager, now: context.date)

                    if helperStatus != .enabled {
                        HelperNotice(
                            status: helperStatus,
                            onConfigure: onConfigureHelper
                        )
                    }

                    if !manager.warnings.isEmpty {
                        WarningList(warnings: manager.warnings)
                    }

                    OperatingConditionsSummary(manager: manager)

                    ActiveSessionSummary(manager: manager, now: context.date)
                }
                .frame(maxWidth: 820)
                .padding(32)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.top, for: .initialOffset)
        }
    }
}

private struct StatusHero: View {
    let manager: SessionManager
    let now: Date

    var body: some View {
        GroupBox {
            HStack(spacing: 22) {
                Image(systemName: symbol)
                    .font(.system(size: 44, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(accent)
                    .frame(width: 58)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(headline)
                        .font(.title2.weight(.semibold))

                    Text(detail)
                        .foregroundStyle(.secondary)

                    if manager.isActive {
                        HStack(spacing: 6) {
                            Label(
                                "\(manager.leases.count)件のセッション",
                                systemImage: "bolt.horizontal.fill"
                            )
                            if let started = manager.suppressionStartedAt {
                                Text("·")
                                Text(started, style: .relative)
                            }
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                    }
                }

                Spacer(minLength: 20)

                StatePill(manager: manager)
            }
            .padding(12)
        }
    }

    private var headline: String {
        switch manager.state {
        case .idle: "Macは通常どおりスリープします"
        case .activating: "スリープ抑止を開始しています"
        case .active: "Macを起こしたままにしています"
        case .deactivating: "スリープ設定を戻しています"
        case .degraded: "一部のスリープだけを抑止しています"
        }
    }

    private var detail: String {
        guard manager.isActive else {
            return "必要なときはツールバーの「開始」を選んでください。"
        }
        if manager.capability == .idleOnly {
            return "アイドルスリープは抑止中ですが、ふたを閉じるとスリープします。"
        }
        guard let endsAt = manager.statusSnapshot().endsAt else {
            return "ふたを閉じてもスリープしません。終了時刻は設定されていません。"
        }
        let remaining = max(0, Int(endsAt.timeIntervalSince(now).rounded()))
        return "ふたを閉じてもスリープしません。あと\(DurationParsing.format(seconds: remaining))です。"
    }

    private var symbol: String {
        switch manager.state {
        case .idle, .deactivating: "moon.zzz.fill"
        case .activating: "hourglass"
        case .active: "bolt.horizontal.fill"
        case .degraded: "exclamationmark.triangle.fill"
        }
    }

    private var accent: Color {
        switch manager.state {
        case .active: .green
        case .degraded: .orange
        case .activating, .deactivating: .blue
        case .idle: .secondary
        }
    }
}

private struct StatePill: View {
    let manager: SessionManager

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: .capsule)
    }

    private var label: String {
        switch manager.state {
        case .idle: "オフ"
        case .activating: "開始中"
        case .active: "オン"
        case .deactivating: "解除中"
        case .degraded: "制限あり"
        }
    }

    private var color: Color {
        switch manager.state {
        case .active: .green
        case .degraded: .orange
        case .activating, .deactivating: .blue
        case .idle: .secondary
        }
    }
}

private struct HelperNotice: View {
    let status: HelperStatus
    let onConfigure: () -> Void

    var body: some View {
        GroupBox {
            HStack(spacing: 14) {
                Image(systemName: "laptopcomputer.trianglebadge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text("ふたを閉じたまま使うには設定が必要です")
                        .font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("設定…", action: onConfigure)
            }
            .padding(8)
        }
    }

    private var message: String {
        switch status {
        case .notRegistered:
            "ヘルパーを登録すると、クラムシェルスリープも抑止できます。"
        case .requiresApproval:
            "macOSの「ログイン項目と機能拡張」で承認してください。"
        case .unavailable(let reason):
            reason
        case .enabled:
            ""
        }
    }
}

private struct WarningList: View {
    let warnings: [String]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

private struct OperatingConditionsSummary: View {
    let manager: SessionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("動作条件")
                .font(.headline)

            GroupBox {
                HStack(alignment: .top, spacing: 0) {
                    ConditionItem(
                        title: "電源",
                        symbol: powerSymbol,
                        value: powerValue
                    )

                    Divider()
                        .padding(.horizontal, 18)

                    ConditionItem(
                        title: "画面",
                        symbol: "display",
                        value: manager.settings.keepDisplayAwake
                            ? "スリープを抑止"
                            : "通常どおりスリープ"
                    )

                    Divider()
                        .padding(.horizontal, 18)

                    ConditionItem(
                        title: "自動解除",
                        symbol: "checkmark.shield.fill",
                        value: safetyValue
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }

    private var powerValue: String {
        let source = switch manager.battery.source {
        case .ac: "電源アダプタ"
        case .battery: "バッテリー"
        case .unknown: "電源不明"
        }
        guard let percent = manager.battery.percent else { return source }
        return "\(source) / \(percent)%"
    }

    private var powerSymbol: String {
        manager.battery.source == .ac ? "powerplug.fill" : "battery.75percent"
    }

    private var safetyValue: String {
        let battery = manager.settings.batteryThreshold.map { "\($0)%以下" }
        let duration = manager.settings.maxTotalDurationSeconds.map(readableDuration)
        let values = [battery, duration].compactMap { $0 }
        return values.isEmpty ? "自動解除なし" : values.joined(separator: " / ")
    }

    private func readableDuration(_ seconds: Int) -> String {
        if seconds.isMultiple(of: 3600) {
            return "\(seconds / 3600)時間"
        }
        if seconds.isMultiple(of: 60) {
            return "\(seconds / 60)分"
        }
        return DurationParsing.format(seconds: seconds)
    }
}

private struct ConditionItem: View {
    let title: String
    let symbol: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.medium))
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActiveSessionSummary: View {
    let manager: SessionManager
    let now: Date

    var body: some View {
        let leases = manager.leases
        let visibleLeases = Array(leases.prefix(5))
        let hiddenLeaseCount = leases.count - visibleLeases.count

        VStack(alignment: .leading, spacing: 10) {
            Text("現在のセッション")
                .font(.headline)

            GroupBox {
                if leases.isEmpty {
                    ContentUnavailableView(
                        "実行中のセッションはありません",
                        systemImage: "moon.zzz",
                        description: Text("StayUpを開始するか、CLIから要求するとここに表示されます。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(visibleLeases.enumerated()), id: \.element.id) { index, lease in
                            SessionSummaryRow(lease: lease, now: now)
                            if index < visibleLeases.count - 1 {
                                Divider()
                            }
                        }

                        if hiddenLeaseCount > 0 {
                            Divider()
                            Text("ほか\(hiddenLeaseCount)件")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
    }
}

private struct SessionSummaryRow: View {
    let lease: Lease
    let now: Date

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: lease.client.isInteractive ? "person.fill" : "terminal.fill")
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(lease.label.isEmpty ? lease.client.name : lease.label)
                Text(lease.client.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(remainingText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
    }

    private var remainingText: String {
        guard let remaining = lease.remainingSeconds(at: now) else { return "無期限" }
        return "あと\(DurationParsing.formatShort(seconds: remaining))"
    }
}
