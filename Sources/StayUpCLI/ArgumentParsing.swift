import Foundation
import StayUpCore

/// CLI の引数解析。
///
/// `awake.sh` のフラグ（`-t`, `-b`, `start`, `stop`, `status`）を互換で受け付ける。
struct ParsedArguments {
    enum Command {
        case run(command: [String])
        case acquire
        case renew
        case release
        case releaseAll
        case list
        case status
        case wait
        case doctor
        case toggle
        case help
        case version
    }

    var command: Command = .toggle
    var owner: String?
    var label: String?
    var reason: String?
    var ttlSeconds: Int?
    var leaseID: LeaseID?
    var leaseFilePath: String?
    var bindPID: pid_t?
    var bindName: String?
    var ifNotExists = false
    var json = false
    /// `awake.sh` 互換の `-b`。現状はグローバル設定なので警告のみ出す。
    var batteryThreshold: Int?

    static func parse(_ arguments: [String]) throws -> ParsedArguments {
        var parsed = ParsedArguments()
        var index = 0
        var sawSubcommand = false

        func next(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else {
                throw CLIError.usage("\(flag) には値が必要です")
            }
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]

            // `--` 以降は run のコマンド本体
            if argument == "--" {
                let rest = Array(arguments[(index + 1)...])
                guard !rest.isEmpty else { throw CLIError.usage("-- の後にコマンドが必要です") }
                parsed.command = .run(command: rest)
                return parsed
            }

            switch argument {
            case "-h", "--help":
                parsed.command = .help
                return parsed
            case "--version":
                parsed.command = .version
                return parsed

            case "run", "acquire", "renew", "release", "list", "status", "wait", "doctor":
                guard !sawSubcommand else { throw CLIError.usage("サブコマンドが重複しています: \(argument)") }
                sawSubcommand = true
                parsed.command = switch argument {
                case "run": .run(command: [])
                case "acquire": .acquire
                case "renew": .renew
                case "release": .release
                case "list": .list
                case "status": .status
                case "wait": .wait
                default: .doctor
                }

            // awake.sh 互換
            case "start":
                guard !sawSubcommand else { throw CLIError.usage("サブコマンドが重複しています: start") }
                sawSubcommand = true
                parsed.command = .acquire
            case "stop":
                guard !sawSubcommand else { throw CLIError.usage("サブコマンドが重複しています: stop") }
                sawSubcommand = true
                parsed.command = .releaseAll

            case "--owner":
                parsed.owner = try next(argument)
            case "--label":
                parsed.label = try next(argument)
            case "--reason":
                parsed.reason = try next(argument)
            case "-t", "--ttl", "--timeout":
                parsed.ttlSeconds = try DurationParsing.seconds(from: try next(argument))
            case "-b", "--battery":
                parsed.batteryThreshold = Int(try next(argument).replacingOccurrences(of: "%", with: ""))
            case "--lease-file":
                parsed.leaseFilePath = try absolutePath(try next(argument))
            case "--bind-pid":
                let raw = try next(argument)
                guard let pid = pid_t(raw) else { throw CLIError.usage("--bind-pid が数値ではありません: \(raw)") }
                parsed.bindPID = pid
            case "--bind-name":
                parsed.bindName = try next(argument)
            case "--if-not-exists":
                parsed.ifNotExists = true
            case "--json":
                parsed.json = true

            default:
                if argument.hasPrefix("--ttl=") {
                    parsed.ttlSeconds = try DurationParsing.seconds(from: String(argument.dropFirst(6)))
                } else if argument.hasPrefix("--owner=") {
                    parsed.owner = String(argument.dropFirst(8))
                } else if argument.hasPrefix("--label=") {
                    parsed.label = String(argument.dropFirst(8))
                } else if argument.hasPrefix("--lease-file=") {
                    parsed.leaseFilePath = try absolutePath(String(argument.dropFirst(13)))
                } else if argument.hasPrefix("-") {
                    throw CLIError.usage("不明な引数です: \(argument)")
                } else if parsed.leaseID == nil, sawSubcommand {
                    // renew / release の位置引数は lease ID
                    parsed.leaseID = LeaseID(rawValue: argument)
                } else {
                    throw CLIError.usage("予期しない引数です: \(argument)")
                }
            }
            index += 1
        }

        return parsed
    }

    /// バインドの指定を 1 つにまとめる。
    var binding: LeaseBinding? {
        if let bindPID { return .pid(bindPID) }
        if let bindName { return .processName(bindName) }
        if let leaseFilePath { return .leaseFile(path: leaseFilePath) }
        return nil
    }

    private static func absolutePath(_ path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        return URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: expanded)
            .standardizedFileURL
            .path(percentEncoded: false)
    }
}

enum CLIError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let message): message
        }
    }
}

let usageText = """
stay-up — ふたを閉じても Mac をスリープさせないための常駐アプリの CLI

Usage:
  stay-up run [opts] -- <command...>   コマンドの実行中だけ抑止する（最も安全）
  stay-up acquire [opts]               リースを取得し lease ID を stdout に出す
  stay-up renew <id> [--ttl 30m]       TTL を延長する（ハートビート）
  stay-up release <id>                 リースを解放する
  stay-up list [--json]                有効なリース一覧
  stay-up status [--json]              全体状態
  stay-up wait                         全リースが消えるまでブロックする
  stay-up doctor                       ヘルパー・権限・pmset を診断する
  stay-up                              引数なしはトグル

Options:
  --owner <name>       クライアント名。UI と履歴に出る
  --label <text>       人間可読な説明
  --reason <text>      承認プロンプトに出す理由
  -t, --ttl <dur>      TTL（1h, 30m, 45s, 1h30m, または秒）
  --bind-pid <pid>     PID にバインド。消滅で自動解放
  --bind-name <name>   プロセス名にバインド
  --lease-file <path>  リースファイルにバインドし、ID をそこに書く
  --if-not-exists      同じリースファイルのリースがあれば再利用する（冪等）
  --json               機械可読な出力
  -h, --help           このヘルプ

awake.sh 互換:
  stay-up start -t 1h        acquire と同じ
  stay-up stop               全リースを解放

Exit codes:
  0 成功 / 2 未接続 / 3 リース不明 / 4 アプリ起動不可 / 5 拒否 / 6 上限超過 / 7 引数不正
"""
