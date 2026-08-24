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
    let onShowWelcome: () -> Void

    /// macOS 側の登録状態を写したもの。真実は OS にあるので、操作のたびに読み直す。
    @State private var launchAtLogin = false
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle("ログイン時に起動", isOn: launchAtLoginBinding)
                if let loginItemError {
                    Label(loginItemError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                Toggle(
                    "メニューバーに残り時間を表示",
                    isOn: $manager.settings.showRemainingInMenuBar
                )

                LabeledContent("はじめかた") {
                    Button("ウォークスルーを開く", action: onShowWelcome)
                }
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
        .task { launchAtLogin = LoginItem.isEnabled }
    }

    /// 書き込んだあと必ず OS から読み直す。
    /// 失敗しても表示だけ切り替わる、という嘘を作らないため。
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { newValue in
                loginItemError = LoginItem.setEnabled(newValue)
                launchAtLogin = LoginItem.isEnabled
            }
        )
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
    @State private var isConfirmingUninstall = false
    @State private var isUninstalling = false
    @State private var uninstallMessage: String?
    @State private var uninstallFailed = false

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

                // 登録済みのときだけ出す。入り口があって出口がない状態を作らない。
                if helperStatus == .enabled || helperStatus == .requiresApproval {
                    GroupBox {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "trash.fill")
                                .font(.title2)
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("ヘルパーの登録を解除")
                                    .font(.headline)
                                Text("""
                                    スリープ設定を元に戻してから、rootヘルパーを登録解除します。\
                                    以降はふたを閉じるとスリープします。
                                    """)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)

                                if let uninstallMessage {
                                    Label(
                                        uninstallMessage,
                                        systemImage: uninstallFailed
                                            ? "exclamationmark.triangle.fill"
                                            : "checkmark.circle.fill"
                                    )
                                    .font(.callout)
                                    .foregroundStyle(uninstallFailed ? Color.red : Color.green)
                                }
                            }

                            Spacer()

                            Button("登録を解除", role: .destructive) {
                                isConfirmingUninstall = true
                            }
                            .disabled(isUninstalling)
                        }
                        .padding(8)
                    }
                    .confirmationDialog(
                        "ヘルパーの登録を解除しますか？",
                        isPresented: $isConfirmingUninstall,
                        titleVisibility: .visible
                    ) {
                        Button("登録を解除", role: .destructive) {
                            Task { await uninstall() }
                        }
                        Button("キャンセル", role: .cancel) {}
                    } message: {
                        Text("""
                            実行中のセッションはすべて破棄されます。\
                            ふたを閉じてもスリープしない設定は使えなくなります。
                            """)
                    }
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

    /// 順序の保証は `SessionManager.uninstallHelper()` が持つ。
    /// ここは確認・進行中の抑止・結果表示だけを担当する。
    private func uninstall() async {
        isUninstalling = true
        defer { isUninstalling = false }

        switch await manager.uninstallHelper() {
        case .success:
            uninstallFailed = false
            uninstallMessage = "登録を解除しました。システム設定から項目が消えるまで数秒かかることがあります。"
        case .failure(let error):
            uninstallFailed = true
            uninstallMessage = error.message
        }

        reload()
        onRefreshHelper()
    }
}
