import AppKit
import StayUpService
import SwiftUI

/// 初回起動時のウォークスルー。
///
/// 黙って `degraded` で動かすと、利用者はふたを閉じて初めて設定が要ることに気付く。
/// 起動直後に一度だけ、何ができて何の設定が要るかを通しで見せる。
struct WelcomeView: View {
    let helper: HelperClient

    @Environment(\.dismiss) private var dismiss
    @State private var page = Page.welcome
    @State private var isHelperReachable = false
    @State private var launchAtLogin = false
    @State private var loginItemError: String?

    enum Page: Int, CaseIterable {
        case welcome
        case helper
        case loginItem
        case ready
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 40)

            footer
        }
        .frame(width: 560, height: 480)
        .task { launchAtLogin = LoginItem.isEnabled }
    }

    // MARK: - ページ

    @ViewBuilder
    private var content: some View {
        switch page {
        case .welcome: welcomePage
        case .helper: helperPage
        case .loginItem: loginItemPage
        case .ready: readyPage
        }
    }

    private var welcomePage: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 8) {
                Text("StayUpへようこそ")
                    .font(.title.weight(.semibold))
                Text("ふたを閉じたままMacを動かし続けるための常駐アプリです。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                feature(
                    "moon.zzz",
                    "必要な間だけ抑止する",
                    "長いビルドが動いているあいだだけスリープを止め、終われば元に戻します。"
                )
                feature(
                    "arrow.triangle.2.circlepath",
                    "解除し忘れが起きない",
                    "要求元が落ちても、期限が切れても、抑止は自動で解除されます。"
                )
                feature(
                    "terminal",
                    "コマンドから使える",
                    "stay-up run -- <command> で、実行中だけ起こしておけます。"
                )
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private var helperPage: some View {
        VStack(spacing: 20) {
            Image(systemName: isHelperReachable ? "checkmark.shield.fill" : "laptopcomputer.and.arrow.down")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isHelperReachable ? Color.green : Color.accentColor)

            HelperGate(helper: helper, isReachable: $isHelperReachable)
        }
    }

    private var loginItemPage: some View {
        VStack(spacing: 20) {
            Image(systemName: "power")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("ログイン時に起動する")
                    .font(.title3.weight(.semibold))
                Text("""
                    常駐して待つアプリなので、ログイン時に自動で起動しておくと\
                    使いたいときにそのまま使えます。
                    """)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Toggle("ログイン時に起動", isOn: launchAtLoginBinding)
                .toggleStyle(.switch)

            if let loginItemError {
                Label(loginItemError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            Text("あとから設定画面で変更できます。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var readyPage: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.green)

            VStack(spacing: 8) {
                Text("準備ができました")
                    .font(.title3.weight(.semibold))
                Text(isHelperReachable
                    ? "ふたを閉じてもスリープしません。"
                    : "現在はアイドルスリープだけを抑止します。ふたを閉じるとスリープします。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            VStack(alignment: .leading, spacing: 14) {
                // 「あとで」を選んだ人が、どこへ戻ればよいか分かるようにする。
                if !isHelperReachable {
                    feature(
                        "gearshape",
                        "あとからヘルパーを登録する",
                        "概要タブに案内が出ています。そこの「設定…」からいつでも登録できます。"
                    )
                }
                feature(
                    "menubar.arrow.up.rectangle",
                    "メニューバーから始める",
                    "アイコンから期間を選んで開始します。⌃⌥⌘1 でも始められます。"
                )
                feature(
                    "stethoscope",
                    "困ったら診断する",
                    "stay-up doctor で、ヘルパーと権限と現在の設定を確認できます。"
                )
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 足回り

    private var footer: some View {
        // ドットは全体の中央に固定する。
        // 左右に Spacer を置くと、両側のボタン幅の差だけ中心がずれる。
        ZStack {
            pageIndicator

            HStack {
                if page != .welcome {
                    Button("戻る") { back() }
                }

                Spacer()

                trailingAction
            }
        }
        .padding(20)
        .background(.bar)
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Page.allCases, id: \.rawValue) { item in
                Circle()
                    .fill(item == page ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }

    @ViewBuilder
    private var trailingAction: some View {
        switch page {
        case .ready:
            Button("はじめる") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

        case .helper:
            // 承認が済むまで先へ進ませない。
            // ただし塞ぎ切らない。ヘルパーなしでも degraded で使えるので、
            // 選ばなかった人を締め出すのは筋が違う。
            HStack(spacing: 12) {
                Button("あとで") { advance() }
                    .buttonStyle(.link)

                Button("次へ") { advance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isHelperReachable)
                    .keyboardShortcut(.defaultAction)
            }

        default:
            Button("次へ") { advance() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func advance() {
        guard let next = Page(rawValue: page.rawValue + 1) else { return }
        withAnimation(.snappy(duration: 0.2)) { page = next }
    }

    private func back() {
        guard let previous = Page(rawValue: page.rawValue - 1) else { return }
        withAnimation(.snappy(duration: 0.2)) { page = previous }
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
}
