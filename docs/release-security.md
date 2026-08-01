# Homebrew配布に必要なmacOSセキュリティ対応

調査日: 2026-07-31

## 結論

StayUpの配布は、quarantine属性の除去だけでは成立しない。

Homebrew Caskから通常のmacOS設定で起動できる配布物には、Developer ID署名、Hardened Runtime、AppleのNotarization、公証ticketのstaplingが必要になる。
Homebrewの公式Caskは、GatekeeperまたはSystem Integrity Protectionの無効化や回避を要求するアプリを受け入れない。

StayUpにはroot権限で動くLaunchDaemonがあるため、配布物の署名と公証を済ませても、利用者による管理者承認は別に必要になる。
この承認は「システム設定」の「ログイン項目と機能拡張」で行う。

## quarantine属性の役割

**quarantine属性**は、ファイルがインターネットなど外部から届いたという来歴をmacOSに伝える拡張属性である。
Gatekeeperは、quarantineが付いたアプリの初回起動時に、開発元、Notarization、改変の有無を検査する。

`xattr -d com.apple.quarantine`は、この検査の契機となる属性を削除するだけである。
次の性質は追加されない。

- Developer IDによる開発者の識別
- 改変を検出する正規のコード署名
- Hardened Runtime
- AppleのNotarization ticket
- rootヘルパーを登録するためのTeam ID
- LaunchDaemonを実行するための管理者承認

したがって、quarantine属性の除去はローカル開発時の診断には使えても、公開リリースの手順にはできない。
HomebrewはCaskのquarantineを伝播し、Gatekeeperが更新後のアプリも検査できる状態を保つ。

Appleは、標準のGatekeeper設定でApp Store外のアプリを動かすには、Developer ID署名とNotarizationが必要だと説明している。
Homebrewも、macOS向けCaskがGatekeeperを無効化または回避せずに動くことを要求している。

## 開発者側で必要な準備

開発者はApple Developer Programに加入し、`Developer ID Application`証明書を取得する必要がある。
NotarizationはApp Reviewではなく、Appleによる自動のマルウェア検査と署名検査である。

配布ビルドでは、アプリ本体、CLI、rootヘルパーを同じDeveloper IDで署名する。
すべての実行可能コードでHardened Runtimeとsecure timestampを有効にし、内側のコードから外側のアプリバンドルへ順に署名する。

App SandboxはMac App Storeでは必須だが、Developer IDによる直接配布では必須ではない。
StayUpの直接配布で必要なのはHardened Runtimeである。

## 利用者側で発生する承認

利用者側の承認は、Gatekeeperとrootヘルパーで別々に発生する。

1. ダウンロードしたアプリを初めて開くと、Gatekeeperが署名とNotarizationを確認し、利用者に初回起動の確認を求める。
2. StayUpで「ヘルパーを登録」を実行すると、`SMAppService.daemon`がLaunchDaemonを登録する。
3. LaunchDaemonは、管理者が「ログイン項目と機能拡張」で承認するまで起動しない。

Appleの`SMAppService.register()`の仕様では、LaunchDaemonは管理者の承認を得るまでbootstrapされない。
Notarizationは配布物の信頼性を検査する仕組みであり、この管理者承認を代替しない。

現在の実装は、`SMAppService.Status.requiresApproval`を表示し、該当するシステム設定を開く導線を持っている。
一方、アクセシビリティ、入力監視、画面収録を要求するAPIは現在の実装に見当たらない。
グローバルショートカットはCarbonの`RegisterEventHotKey`を使っており、イベント監視用のevent tapは使っていない。
したがって、現行機能にはこれらのTCC権限を追加する理由がない。

## 現在のリポジトリとの差分

`scripts/build-app.sh`には、Developer ID証明書の選択、Hardened Runtime、secure timestamp、内側から外側への署名、三つの実行ファイルのTeam ID一致確認が実装されている。
この部分はNotarizationの前提を満たす方向になっている。

一方、次の処理はまだ実装されていない。

- `notarytool submit --wait`によるNotarization
- NotarizationログとAccepted状態の確認
- `.app`への`stapler staple`と`stapler validate`
- `spctl --assess`によるGatekeeper評価
- staple済みアプリから作る最終ZIPまたはDMG
- リリース成果物のSHA-256作成
- GitHub Releaseなどの不変なダウンロードURL
- Homebrew Cask定義
- quarantine付きの実際のダウンロード経路を使う回帰試験

2026-07-31に存在した`build/StayUp.app`は、ad-hoc署名、Team IDなし、arm64単体だった。
このビルドはrootヘルパーを登録できず、`spctl`のGatekeeper評価にも合格しない。
ただし、配布用のDeveloper ID証明書を指定してビルドした結果ではなく、ローカルに残っていた開発ビルドの状態である。

`HelperClient.unregister()`は実装されているが、アプリの画面から呼ばれていない。
Caskでアプリを削除する前に、`disablesleep`を確実に`0`へ戻してLaunchDaemonを登録解除できる導線が必要になる。
アップグレード時には登録状態を維持し、明示的なアンインストール時だけ安全に解除する設計を検証する必要がある。

## 推奨するリリース手順

ZIPで配布する場合は、次の順序にする。

1. リリース版をビルドする。
2. rootヘルパー、CLI、アプリを同じ`Developer ID Application`証明書で署名する。
3. 一時ZIPを作り、`xcrun notarytool submit --wait`でAppleへ送る。
4. Acceptedを確認し、Notarizationログの警告も確認する。
5. `xcrun stapler staple`でticketを`.app`へ付ける。
6. `xcrun stapler validate`と`spctl --assess --type execute`で検証する。
7. staple済みの`.app`から最終ZIPを作り直す。
8. 最終ZIPのSHA-256を計算し、バージョン固定のGitHub Releaseへ公開する。
9. CaskからそのURLとSHA-256を参照する。
10. クリーンなmacOS 26環境で、インストール、初回起動、ヘルパー承認、動作、アップグレード、アンインストールを確認する。

ZIPそのものにはticketをstapleできない。
そのため、Notarizationに送った一時ZIPをそのまま最終成果物にせず、ticketを付けた`.app`から最終ZIPを作り直す。
DMGを使う場合はDMGにもticketをstapleできる。

## Homebrewでの配布形態

StayUpはGUIアプリとCLIを同じアプリバンドルに含むため、FormulaよりCaskが適している。
Formulaでソースからビルドすると、Homebrewのビルド環境に開発者のDeveloper ID秘密鍵を渡せず、rootヘルパーが必要とする署名済み配布物を作れない。

Caskでは、`app "StayUp.app"`でアプリを`/Applications`へ置き、`binary "#{appdir}/StayUp.app/Contents/MacOS/stay-up"`でCLIをHomebrewの`bin`へリンクできる。

最初は開発者が管理するthird-party tapで配布するのが現実的である。
公式`homebrew/cask`には、公開実績、保守状態、知名度に関する受け入れ基準がある。
作者自身がGitHubプロジェクトを申請する場合の通常基準は、90 forks、90 watchers、225 starsのいずれかであり、リポジトリ作成から30日未満の申請も通常は受け入れられない。

## 一次情報

- [Apple Developer ID](https://developer.apple.com/support/developer-id/)
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Apple: Resolving common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
- [Apple: Preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)
- [Apple Platform Security: Gatekeeper and runtime protection](https://support.apple.com/guide/security/gatekeeper-and-runtime-protection-sec5599b66df/web)
- [Apple Platform Security: App code signing process in macOS](https://support.apple.com/guide/security/app-code-signing-process-in-macos-sec3ad8e6e53/web)
- [Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple: SMAppService.register()](https://developer.apple.com/documentation/servicemanagement/smappservice/register())
- [Homebrew: Adding Software to Homebrew](https://docs.brew.sh/Adding-Software-to-Homebrew)
- [Homebrew: Acceptable Casks](https://docs.brew.sh/Acceptable-Casks)
- [Homebrew: Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)
- [Homebrew: Package Acceptance Policy](https://docs.brew.sh/Package-Acceptance-Policy)
- [Homebrew: Cask quarantine implementation](https://docs.brew.sh/rubydoc/Cask/Quarantine.html)
