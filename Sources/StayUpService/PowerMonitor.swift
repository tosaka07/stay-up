import Foundation
import IOKit.ps
import StayUpCore

public enum PowerSource: String, Sendable {
    case ac
    case battery
    case unknown
}

public struct PowerReading: Sendable, Equatable {
    public let percent: Int?
    public let source: PowerSource

    public init(percent: Int?, source: PowerSource) {
        self.percent = percent
        self.source = source
    }

    public var snapshot: BatterySnapshot {
        BatterySnapshot(percent: percent, source: source.rawValue)
    }
}

/// バッテリー残量・電源ソース・熱状態の監視（spec §7.2 / §7.5）。
///
/// ポーリングせず、`IOPSNotificationCreateRunLoopSource` の通知で駆動する。
public final class PowerMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var runLoopSource: CFRunLoopSource?
    private var onChange: (@Sendable (PowerReading) -> Void)?

    public init() {}

    /// 現在の電源状態を読む。
    public func read() -> PowerReading {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return PowerReading(percent: nil, source: .unknown)
        }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                as? [String: Any]
            else { continue }

            let capacity = info[kIOPSCurrentCapacityKey] as? Int
            let max = info[kIOPSMaxCapacityKey] as? Int
            let state = info[kIOPSPowerSourceStateKey] as? String

            let percent: Int? =
                if let capacity, let max, max > 0 {
                    Int((Double(capacity) / Double(max) * 100).rounded())
                } else {
                    capacity
                }

            let powerSource: PowerSource =
                switch state {
                case kIOPSACPowerValue: .ac
                case kIOPSBatteryPowerValue: .battery
                default: .unknown
                }

            return PowerReading(percent: percent, source: powerSource)
        }

        // 電源が見つからない = デスクトップ機。常に AC 扱い。
        return PowerReading(percent: nil, source: .ac)
    }

    /// 熱状態が危険域か。
    public var isThermalCritical: Bool {
        ProcessInfo.processInfo.thermalState == .critical
    }

    /// 電源状態の変化を監視する。
    public func startMonitoring(onChange handler: @escaping @Sendable (PowerReading) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard runLoopSource == nil else { return }
        self.onChange = handler

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.notifyChange()
        }, context)?.takeRetainedValue() else {
            return
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    public func stopMonitoring() {
        lock.lock()
        defer { lock.unlock() }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            runLoopSource = nil
        }
        onChange = nil
    }

    private func notifyChange() {
        lock.lock()
        let handler = onChange
        lock.unlock()
        handler?(read())
    }
}

/// `pmset` の読み取り。書き込みは root ヘルパーの仕事。
public enum PMSet {
    /// `pmset -g` の `SleepDisabled` の値。読めなければ nil。
    public static func sleepDisabled() -> Bool? {
        guard let output = run(["-g"]) else { return nil }
        return PMSetOutput.sleepDisabled(in: output)
    }

    /// `pmset -g assertions` の生出力（診断タブ用）。
    public static func assertions() -> String? {
        run(["-g", "assertions"])
    }

    public static func raw(_ arguments: [String]) -> String? {
        run(arguments)
    }

    private static func run(_ arguments: [String]) -> String? {
        let process = Process()
        // 絶対パスで実行し、環境変数を継承しない（spec §6.4）
        process.executableURL = URL(filePath: "/usr/bin/pmset")
        process.arguments = arguments
        process.environment = [:]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
