import StayUpCore
import StayUpService
import SwiftUI

struct IntegrationsView: View {
    @Bindable var manager: SessionManager

    var body: some View {
        Form {
            Section {
                Picker("外部クライアントからの要求", selection: $manager.settings.clientPolicy) {
                    Text("確認してから許可").tag(ClientPolicy.ask)
                    Text("常に許可").tag(ClientPolicy.allow)
                    Text("拒否（読み取り専用）").tag(ClientPolicy.deny)
                }

                Picker(
                    "クライアントごとの上限",
                    selection: $manager.settings.maxLeasesPerClient
                ) {
                    ForEach(maxLeaseOptions, id: \.self) { count in
                        Text("\(count)件").tag(count)
                    }
                }
            } header: {
                Text("アクセス")
            } footer: {
                Text("外部クライアント名は識別用です。信頼できないスクリプトには許可しないでください。")
            }

            Section("承認済みクライアント") {
                if manager.settings.approvedClients.isEmpty {
                    Text("承認済みのクライアントはありません")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.settings.approvedClients, id: \.self) { name in
                        HStack {
                            Label(name, systemImage: "terminal")
                            Spacer()
                            Button(role: .destructive) {
                                manager.settings.approvedClients.removeAll { $0 == name }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("\(name)の承認を取り消す")
                        }
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("コマンドをStayUpで実行", systemImage: "terminal")
                        .font(.headline)
                    Text("stay-up run --owner build -- make release")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text("プロセスが終了すると、セッションも自動的に解除されます。")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } header: {
                Text("CLI")
            }
        }
        .formStyle(.grouped)
    }

    private var maxLeaseOptions: [Int] {
        var values = [1, 2, 4, 8, 16, 32, 64]
        let current = manager.settings.maxLeasesPerClient
        if !values.contains(current) {
            values.append(current)
        }
        return values.sorted()
    }
}

struct SettingsView: View {
    @Bindable var manager: SessionManager

    var body: some View {
        Form {
            Section {
                Picker("既定の期間", selection: $manager.settings.defaultDurationSeconds) {
                    Text("30分").tag(30 * 60 as Int?)
                    Text("1時間").tag(60 * 60 as Int?)
                    Text("2時間").tag(2 * 60 * 60 as Int?)
                    Text("無期限").tag(nil as Int?)
                }

                Toggle(
                    "メニューバーに残り時間を表示",
                    isOn: $manager.settings.showRemainingInMenuBar
                )
            } header: {
                Text("一般")
            }

            Section {
                Toggle(
                    "ディスプレイもスリープさせない",
                    isOn: $manager.settings.keepDisplayAwake
                )
                Toggle(
                    "ディスクの省電力も抑止",
                    isOn: $manager.settings.preventDiskSleep
                )
            } header: {
                Text("抑止する範囲")
            } footer: {
                Text("通常はどちらもオフで十分です。必要な範囲だけ有効にすると消費電力を抑えられます。")
            }

            Section {
                Toggle("バッテリー残量で自動解除", isOn: batteryLimitEnabled)
                if let threshold = manager.settings.batteryThreshold {
                    Picker(
                        "解除する残量",
                        selection: Binding(
                            get: { threshold },
                            set: { manager.settings.batteryThreshold = $0 }
                        )
                    ) {
                        ForEach(batteryThresholdOptions, id: \.self) { value in
                            Text("\(value)%").tag(value)
                        }
                    }
                }

                Toggle("継続時間に上限を設ける", isOn: durationLimitEnabled)
                if manager.settings.maxTotalDurationSeconds != nil {
                    Picker("上限", selection: $manager.settings.maxTotalDurationSeconds) {
                        Text("4時間").tag(4 * 60 * 60 as Int?)
                        Text("8時間").tag(8 * 60 * 60 as Int?)
                        Text("12時間").tag(12 * 60 * 60 as Int?)
                        Text("24時間").tag(24 * 60 * 60 as Int?)
                    }
                }
            } header: {
                Text("安全な自動解除")
            } footer: {
                Text("外部クライアントの要求より優先され、条件に達するとすべてのセッションを解除します。")
            }

            Section("履歴") {
                Picker("保持期間", selection: $manager.settings.logRetentionDays) {
                    ForEach(logRetentionOptions, id: \.self) { days in
                        Text(days == 365 ? "1年" : "\(days)日").tag(days)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var batteryLimitEnabled: Binding<Bool> {
        Binding(
            get: { manager.settings.batteryThreshold != nil },
            set: { manager.settings.batteryThreshold = $0 ? 20 : nil }
        )
    }

    private var durationLimitEnabled: Binding<Bool> {
        Binding(
            get: { manager.settings.maxTotalDurationSeconds != nil },
            set: { manager.settings.maxTotalDurationSeconds = $0 ? 12 * 60 * 60 : nil }
        )
    }

    private var batteryThresholdOptions: [Int] {
        var values = [5, 10, 15, 20, 25, 30, 40, 50]
        if let current = manager.settings.batteryThreshold, !values.contains(current) {
            values.append(current)
        }
        return values.sorted()
    }

    private var logRetentionOptions: [Int] {
        var values = [7, 14, 30, 60, 90, 180, 365]
        let current = manager.settings.logRetentionDays
        if !values.contains(current) {
            values.append(current)
        }
        return values.sorted()
    }
}

struct DiagnosticsView: View {
    @Bindable var manager: SessionManager
    let helperStatus: HelperStatus
    let onConfigureHelper: () -> Void
    let onRefreshHelper: () -> Void

    @State private var pmsetOutput = ""
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GroupBox("ヘルパー") {
                    HStack(spacing: 12) {
                        Image(systemName: helperStatus == .enabled
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill")
                            .foregroundStyle(helperStatus == .enabled ? .green : .orange)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(helperStatus.localizedDescription)
                            Text(helperStatus == .enabled
                                ? "ふたを閉じたときのスリープも抑止できます。"
                                : "現在はアイドルスリープだけを抑止できます。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if helperStatus != .enabled {
                            Button("設定…", action: onConfigureHelper)
                        }
                    }
                    .padding(8)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("電源管理の状態", systemImage: "waveform.path.ecg")
                                .font(.headline)
                            Spacer()
                            Button {
                                reload()
                                onRefreshHelper()
                            } label: {
                                Label("再読み込み", systemImage: "arrow.clockwise")
                            }
                            .disabled(isLoading)
                        }

                        ScrollView(.vertical) {
                            Text(pmsetOutput.isEmpty ? "読み込み中…" : pmsetOutput)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                        .frame(minHeight: 220)
                        .background(.background.secondary, in: .rect(cornerRadius: 8))
                    }
                    .padding(8)
                }

                GroupBox {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "lifepreserver.fill")
                            .font(.title2)
                            .foregroundStyle(.red)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("緊急復元")
                                .font(.headline)
                            Text("すべてのセッションを破棄し、StayUpが変更したスリープ設定を元に戻します。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("スリープ設定を復元", role: .destructive) {
                            Task { await manager.forceRestore() }
                        }
                    }
                    .padding(8)
                }
            }
            .frame(maxWidth: 820)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.top, for: .initialOffset)
        .task { reload() }
    }

    private func reload() {
        isLoading = true
        pmsetOutput = [PMSet.raw(["-g"]), PMSet.assertions()]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        isLoading = false
    }
}

struct HelperSetupView: View {
    let helper: HelperClient

    @Environment(\.dismiss) private var dismiss
    @State private var status: HelperStatus = .notRegistered
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: status == .enabled
                ? "checkmark.shield.fill"
                : "laptopcomputer.and.arrow.down")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(status == .enabled ? Color.green : Color.accentColor)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            setupAction

            Text("ヘルパーはスリープ設定の切り替えだけを行い、任意のコマンドは実行できません。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(36)
        .frame(width: 540)
        .frame(minHeight: 360)
        .task { refresh() }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(status == .enabled ? "完了" : "閉じる") {
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private var setupAction: some View {
        switch status {
        case .notRegistered:
            Button("ヘルパーを登録") {
                do {
                    try helper.register()
                    errorMessage = nil
                    refresh()
                } catch {
                    errorMessage = error.localizedDescription
                    refresh()
                }
            }
            .buttonStyle(.borderedProminent)

        case .requiresApproval:
            HStack {
                Button("システム設定を開く") {
                    helper.openLoginItemsSettings()
                }
                .buttonStyle(.borderedProminent)

                Button("状態を再確認") {
                    refresh()
                }
            }

        case .enabled:
            Button("完了") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)

        case .unavailable:
            Button("状態を再確認") {
                refresh()
            }
        }
    }

    private var title: String {
        switch status {
        case .notRegistered: "ふたを閉じても起動を続ける"
        case .requiresApproval: "macOSで承認してください"
        case .enabled: "設定が完了しました"
        case .unavailable: "ヘルパーを利用できません"
        }
    }

    private var message: String {
        switch status {
        case .notRegistered:
            "初回だけヘルパーを登録します。ターミナルでsudoを実行する必要はありません。"
        case .requiresApproval:
            "「ログイン項目と機能拡張」でStayUpを許可したあと、状態を再確認してください。"
        case .enabled:
            "StayUpは、ふたを閉じたときのスリープも抑止できます。"
        case .unavailable(let reason):
            reason
        }
    }

    private func refresh() {
        status = helper.status
    }
}
