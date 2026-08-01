import Foundation

/// root ヘルパーが公開する操作（spec §6.4）。
///
/// **任意コマンド実行の口は作らない。** ここにある 3 つだけが root で動く。
@objc public protocol StayUpHelperProtocol {
    /// `pmset -a disablesleep {0,1}` を実行する。
    /// - Parameter reply: (成功したか, エラーメッセージ)
    func setDisableSleep(_ enabled: Bool, reply: @escaping @Sendable (Bool, String?) -> Void)

    /// 現在の `SleepDisabled` とヘルパーのバージョンを返す。
    /// - Parameter reply: (SleepDisabled が 1 か, ヘルパーのバージョン)
    func queryState(reply: @escaping @Sendable (Bool, String) -> Void)

    /// 生存通知。一定時間途絶えるとヘルパーが自力で復元する（復元保証の層 5）。
    func heartbeat(reply: @escaping @Sendable (Bool) -> Void)
}

public enum HelperConstants {
    /// ヘルパーのバージョン。アプリと不一致なら起動を拒否する。
    public static let version = "1"

    /// heartbeat がこの秒数途絶えたら、ヘルパーは自力で `disablesleep 0` に戻す。
    public static let heartbeatTimeout: TimeInterval = 90

    /// アプリ側が heartbeat を送る間隔。
    public static let heartbeatInterval: TimeInterval = 30
}
