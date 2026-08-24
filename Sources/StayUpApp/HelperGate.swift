import AppKit
import StayUpService
import SwiftUI

/// ヘルパーの登録から承認までを扱う部品。
///
/// 承認は macOS のシステム設定側で行われ、こちらへ通知は来ない。
/// そのため表示されているあいだ、状態を繰り返し見に行く。
///
/// 完了と見なすのは、登録記録が `.enabled` になったときではなく、
/// 実際にヘルパーへ往復できたときである。
/// 登録が残ったまま実体が失われることがあり、記録だけを信じると
/// 有効と表示したまま抑止が効かない状態を通してしまう。
struct HelperGate: View {
    let helper: HelperClient
    @Binding var isReachable: Bool

    @State private var status: HelperStatus = .notRegistered
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            action

            Text("ヘルパーはスリープ設定の切り替えだけを行い、任意のコマンドは実行できません。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                if isReachable { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var action: some View {
        switch status {
        case .notRegistered:
            Button("ヘルパーを登録") {
                do {
                    try helper.register()
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
                Task { await refresh() }
            }
            .buttonStyle(.borderedProminent)

        case .requiresApproval:
            VStack(spacing: 10) {
                Button("システム設定を開く") {
                    helper.openLoginItemsSettings()
                }
                .buttonStyle(.borderedProminent)

                waiting("承認を待っています")
            }

        case .enabled where isReachable:
            Label("ヘルパーが応答しました", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)

        case .enabled:
            VStack(spacing: 10) {
                waiting("ヘルパーへの接続を確認しています")

                Button("システム設定を開く") {
                    helper.openLoginItemsSettings()
                }
            }

        case .unavailable:
            EmptyView()
        }
    }

    private func waiting(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var title: String {
        if isReachable { return "設定が完了しました" }
        switch status {
        case .notRegistered: return "ふたを閉じても動かし続ける"
        case .requiresApproval: return "macOSで承認してください"
        case .enabled: return "ヘルパーの応答を待っています"
        case .unavailable: return "ヘルパーを利用できません"
        }
    }

    private var message: String {
        if isReachable {
            return "ふたを閉じたときのスリープも抑止できます。"
        }
        switch status {
        case .notRegistered:
            return """
                ふたを閉じたときのスリープを抑止するには、root権限で動くヘルパーが要ります。
                ターミナルでsudoを実行する必要はありません。
                """
        case .requiresApproval:
            return """
                「ログイン項目と機能拡張」でStayUpをオンにしてください。
                オンにすると、この画面が自動で進みます。
                """
        case .enabled:
            return "登録は済んでいますが、ヘルパーからの応答がまだありません。"
        case .unavailable(let reason):
            return reason
        }
    }

    /// 登録状態を読み直し、`.enabled` なら実際に往復して確かめる。
    private func refresh() async {
        status = helper.status
        guard status == .enabled else {
            isReachable = false
            return
        }
        isReachable = await helper.queryState() != nil
    }
}

/// 設定を後から見直すためのシート。
struct HelperSetupView: View {
    let helper: HelperClient

    @Environment(\.dismiss) private var dismiss
    @State private var isReachable = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: isReachable ? "checkmark.shield.fill" : "laptopcomputer.and.arrow.down")
                .font(.system(size: 48))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isReachable ? Color.green : Color.accentColor)

            HelperGate(helper: helper, isReachable: $isReachable)
        }
        .padding(36)
        .frame(width: 540)
        .frame(minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(isReachable ? "完了" : "あとで") {
                    dismiss()
                }
            }
        }
    }
}
