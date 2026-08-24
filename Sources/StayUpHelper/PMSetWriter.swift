import Foundation
import StayUpCore

/// root 権限で `pmset` を書き換える唯一の実行点。
///
/// 絶対パスで実行し、環境変数を継承しない（spec §6.4）。
enum PMSetWriter {
    @discardableResult
    static func setDisableSleep(_ enabled: Bool) -> (ok: Bool, message: String?) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", enabled ? "1" : "0"]
        process.environment = [:]

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                return (true, nil)
            }
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, message?.isEmpty == false ? message : "pmset が \(process.terminationStatus) で終了しました")
        } catch {
            return (false, "pmset の起動に失敗しました: \(error.localizedDescription)")
        }
    }

    /// 現在の `SleepDisabled`。読めなければ nil。
    static func sleepDisabled() -> Bool? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.environment = [:]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8)
            else { return nil }

            return PMSetOutput.sleepDisabled(in: output)
        } catch {
            return nil
        }
    }
}
