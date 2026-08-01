import Foundation

/// `state.json` の中身（spec §11.2）。
///
/// クラッシュ復帰と孤児検出のためのスナップショット。
/// 「前回どうなっていたか」を知るために使うが、リースを自動復活させるためのものではない。
public struct PersistedState: Sendable, Codable, Equatable {
    public var v: Int
    public var updatedAt: Date
    public var leases: [Lease]
    /// 最後に `disablesleep 1` を設定した時刻。孤児判定の材料。
    public var disableSleepSetAt: Date?

    public init(leases: [Lease], disableSleepSetAt: Date?, updatedAt: Date = Date()) {
        self.v = ControlProtocol.version
        self.updatedAt = updatedAt
        self.leases = leases
        self.disableSleepSetAt = disableSleepSetAt
    }

    public static let empty = PersistedState(leases: [], disableSleepSetAt: nil)
}

/// 現在のリース台帳を単一 JSON ファイルに保存する。
///
/// 一時ファイルに書いて `rename(2)` で原子的に置換するため、
/// 途中で落ちても壊れた state が残らない（spec §11.2）。
public final class StateStore: @unchecked Sendable {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public init(fileURL: URL = StayUpPaths.stateFile) {
        self.fileURL = fileURL
        let encoder = ControlCoding.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = ControlCoding.makeDecoder()
    }

    /// 読めない・壊れている場合は空として扱い、呼び出し側が警告を出せるよう nil を返す。
    public func load() -> PersistedState? {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(PersistedState.self, from: data)
    }

    /// state.json が存在するかどうか（load が nil のとき、不在か破損かを区別する）。
    public var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false))
    }

    @discardableResult
    public func save(_ state: PersistedState) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try encoder.encode(state)
            let tempURL = directory.appending(path: ".state.\(ProcessInfo.processInfo.processIdentifier).tmp")

            try data.write(to: tempURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path(percentEncoded: false))
            // rename(2) は同一ボリューム内で原子的。既存ファイルを壊さずに置換する。
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func clear() -> Bool {
        save(.empty)
    }
}
