import Foundation
import StayUpCore

// MARK: - 出力ヘルパー

func printError(_ message: String) {
    FileHandle.standardError.write(Data("stay-up: \(message)\n".utf8))
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = ControlCoding.makeEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

/// 失敗をどう扱うか。
///
/// **抑止は本来の作業の付随物なので、`nonFatal` なら終了コード 0 を返す。**
/// ヘルパー未設定や承認拒否で `npm test` が落ちるのは本末転倒（spec §16）。
func exit(with error: ControlError) -> Never {
    printError(error.message)
    exit(error.nonFatal ? 0 : Int32(error.code))
}

func exitFatal(with error: ControlError) -> Never {
    printError(error.message)
    exit(Int32(error.code))
}

// MARK: - コマンドの実装

let client = ControlClient()

func describe(_ lease: LeaseSnapshot, now: Date = Date()) -> String {
    var parts = ["\(lease.owner)"]
    if !lease.label.isEmpty, lease.label != lease.owner {
        parts.append("(\(lease.label))")
    }
    if let expiresAt = lease.expiresAt {
        let remaining = max(0, Int(expiresAt.timeIntervalSince(now).rounded()))
        parts.append("あと \(DurationParsing.format(seconds: remaining))")
    } else {
        parts.append("無期限")
    }
    if let binding = lease.binding {
        parts.append("[\(binding)]")
    }
    return parts.joined(separator: " ")
}

func runAcquire(_ arguments: ParsedArguments, autoLaunch: Bool = true) -> LeaseSnapshot? {
    let options = AcquireOptions(
        owner: arguments.owner,
        label: arguments.label,
        ttlSeconds: arguments.ttlSeconds,
        binding: arguments.binding,
        leaseFilePath: arguments.leaseFilePath,
        ifNotExists: arguments.ifNotExists,
        reason: arguments.reason,
        clientPID: getpid()
    )

    switch client.send(.acquire(options), autoLaunch: autoLaunch) {
    case .failure(let error):
        exit(with: error)
    case .success(let response):
        switch response {
        case .acquired(let lease, _, let warning):
            if let warning { printError(warning) }
            return lease
        case .failure(let error):
            exit(with: error)
        default:
            printError("予期しない応答です")
            exit(Int32(ControlErrorCode.generic.rawValue))
        }
    }
}

/// `stay-up run -- <command>`
///
/// 子プロセスの生存がそのままリースの生存になるので、解放漏れが原理的に起きない。
func runWrapped(_ arguments: ParsedArguments, command: [String]) -> Never {
    guard let executable = resolveExecutable(command[0]) else {
        printError("コマンドが見つかりません: \(command[0])")
        exit(127)
    }

    // 自分自身の PID にバインドする。run が死ねばリースも消える。
    var acquireArguments = arguments
    acquireArguments.bindPID = getpid()
    acquireArguments.leaseFilePath = nil
    if acquireArguments.label == nil {
        acquireArguments.label = command.joined(separator: " ")
    }
    let lease = runAcquire(acquireArguments)

    let process = Process()
    process.executableURL = executable
    process.arguments = Array(command.dropFirst())

    // シグナルを子に転送する。Ctrl+C で親だけ死ぬのを防ぐ。
    let forwarded: [Int32] = [SIGINT, SIGTERM, SIGHUP]
    var sources: [DispatchSourceSignal] = []
    for number in forwarded {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler {
            if process.isRunning { kill(process.processIdentifier, number) }
        }
        source.resume()
        sources.append(source)
    }

    do {
        try process.run()
    } catch {
        printError("実行に失敗しました: \(error.localizedDescription)")
        exit(126)
    }
    process.waitUntilExit()

    for source in sources { source.cancel() }

    // 明示的に解放する（早く解放するための最適化。PID バインドがあるので必須ではない）
    if let lease {
        _ = client.send(.release(id: lease.id, leaseFilePath: nil, owner: arguments.owner), autoLaunch: false)
    }

    // 終了コードとシグナルを透過する
    if process.terminationReason == .uncaughtSignal {
        exit(128 + process.terminationStatus)
    }
    exit(process.terminationStatus)
}

func resolveExecutable(_ name: String) -> URL? {
    if name.contains("/") {
        let url = URL(filePath: name)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        .split(separator: ":")
    for directory in paths {
        let candidate = URL(filePath: String(directory)).appending(path: name)
        if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) {
            return candidate
        }
    }
    return nil
}

// MARK: - ディスパッチ

let rawArguments = Array(CommandLine.arguments.dropFirst())
let arguments: ParsedArguments
do {
    arguments = try ParsedArguments.parse(rawArguments)
} catch {
    printError("\(error)")
    printError("'stay-up --help' で使い方を確認してください。")
    exit(Int32(ControlErrorCode.invalidArgument.rawValue))
}

if arguments.batteryThreshold != nil {
    printError("-b/--battery はグローバル設定です。StayUp の設定画面で変更してください（この指定は無視されます）")
}

switch arguments.command {
case .help:
    print(usageText)

case .version:
    print("stay-up \(HelperConstants.version) (protocol v\(ControlProtocol.version))")

case .run(let command):
    guard !command.isEmpty else {
        printError("run には -- に続けてコマンドが必要です")
        exit(Int32(ControlErrorCode.invalidArgument.rawValue))
    }
    runWrapped(arguments, command: command)

case .acquire:
    if let lease = runAcquire(arguments) {
        if arguments.json {
            printJSON(lease)
        } else {
            print(lease.id.rawValue)
        }
    }

case .renew:
    let request = ControlRequest.renew(
        id: arguments.leaseID,
        leaseFilePath: arguments.leaseFilePath,
        ttlSeconds: arguments.ttlSeconds,
        owner: arguments.owner
    )
    switch client.send(request, autoLaunch: false) {
    case .failure(let error):
        exit(with: error)
    case .success(.renewed(let lease)):
        if arguments.json { printJSON(lease) }
    case .success(.failure(let error)):
        exit(with: error)
    case .success:
        printError("予期しない応答です")
        exit(Int32(ControlErrorCode.generic.rawValue))
    }

case .release:
    let request = ControlRequest.release(
        id: arguments.leaseID,
        leaseFilePath: arguments.leaseFilePath,
        owner: arguments.owner
    )
    switch client.send(request, autoLaunch: false) {
    case .failure(let error):
        exit(with: error)
    case .success(.released(let count)):
        if !arguments.json, count > 0 { print("解放しました") }
    case .success(.failure(let error)):
        // 既に失効しているのは正常なケース
        exit(with: error)
    case .success:
        break
    }
    // リースファイルは解放後に片付ける
    if let path = arguments.leaseFilePath {
        try? FileManager.default.removeItem(atPath: path)
    }

case .releaseAll:
    switch client.send(.releaseAll(owner: arguments.owner), autoLaunch: false) {
    case .failure(let error):
        exit(with: error)
    case .success(.released(let count)):
        print("\(count) 件のリースを解放しました")
    default:
        break
    }

case .list:
    switch client.send(.list, autoLaunch: false) {
    case .failure(let error):
        exit(with: error)
    case .success(.list(let leases)):
        if arguments.json {
            printJSON(leases)
        } else if leases.isEmpty {
            print("リースはありません")
        } else {
            for lease in leases {
                print("\(lease.id)  \(describe(lease))")
            }
        }
    default:
        break
    }

case .status:
    switch client.send(.status, autoLaunch: false) {
    case .failure(let error):
        // 未接続なら「抑止していない」と等価。JSON でも一貫した形を返す。
        if arguments.json {
            printJSON(StatusSnapshot(
                state: .idle, capability: .idleOnly, leases: [],
                activeSince: nil, endsAt: nil, endsReason: nil,
                battery: BatterySnapshot(percent: nil, source: "unknown"),
                warnings: [error.message]
            ))
            exit(0)
        }
        exit(with: error)
    case .success(.status(let snapshot)):
        if arguments.json {
            printJSON(snapshot)
        } else {
            let stateText = snapshot.state == "idle" ? "停止中" : "抑止中"
            print("stay-up: \(stateText) (\(snapshot.leaseCount) リース)")
            if snapshot.capability == "idleOnly", snapshot.leaseCount > 0 {
                print("  警告: ふたを閉じるとスリープします（ヘルパー未設定）")
            }
            if let endsAt = snapshot.endsAt {
                let remaining = max(0, Int(endsAt.timeIntervalSinceNow.rounded()))
                print("  あと \(DurationParsing.format(seconds: remaining)) (\(snapshot.endsReason ?? "-"))")
            }
            for lease in snapshot.leases {
                print("  - \(describe(lease))")
            }
            if let percent = snapshot.battery.percent {
                print("  バッテリー \(percent)% (\(snapshot.battery.source))")
            }
            for warning in snapshot.warnings {
                print("  ! \(warning)")
            }
        }
    default:
        break
    }

case .wait:
    switch client.send(.wait, autoLaunch: false) {
    case .failure(let error): exit(with: error)
    default: break
    }

case .doctor:
    switch client.send(.doctor) {
    case .failure(let error):
        exitFatal(with: error)
    case .success(.doctor(let report)):
        if arguments.json {
            printJSON(report)
        } else {
            var allOK = true
            for check in report.checks {
                print("\(check.ok ? "✓" : "✗") \(check.name): \(check.detail)")
                if let remedy = check.remedy {
                    print("    → \(remedy)")
                    allOK = false
                }
            }
            if !allOK { exit(1) }
        }
    default:
        break
    }

case .toggle:
    let options = AcquireOptions(
        owner: arguments.owner,
        label: arguments.label,
        ttlSeconds: arguments.ttlSeconds,
        clientPID: getpid()
    )
    switch client.send(.toggle(options)) {
    case .failure(let error):
        exit(with: error)
    case .success(.acquired(let lease, _, let warning)):
        if let warning { printError(warning) }
        print("抑止を開始しました: \(describe(lease))")
    case .success(.released(let count)):
        print("\(count) 件のリースを解放しました")
    case .success(.failure(let error)):
        exit(with: error)
    default:
        break
    }
}
