import Foundation
import StayUpCore

/// 設定の永続化（spec §9）。
///
/// 履歴と違って「常に全体を読み書きする小さな値」なので `UserDefaults` に置く。
public struct SettingsStore: @unchecked Sendable {
    // UserDefaults 自体はスレッドセーフだが Sendable 宣言を持たない
    private let defaults: UserDefaults
    private let key = "settings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Settings {
        guard let data = defaults.data(forKey: key),
              let settings = try? ControlCoding.makeDecoder().decode(Settings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    public func save(_ settings: Settings) {
        guard let data = try? ControlCoding.makeEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
