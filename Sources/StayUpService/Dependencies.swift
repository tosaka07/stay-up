import Foundation
import StayUpCore

/// アイドルスリープ抑止（root 不要な層）。
public protocol SleepAssertionHolding: AnyObject, Sendable {
    func acquire(keepDisplayAwake: Bool, preventDiskSleep: Bool)
    func releaseAll()
}

/// クラムシェルスリープ抑止（root ヘルパー経由の層）。
///
/// **接続の維持そのものが復元保証**なので、実装は接続断を必ず通知すること。
public protocol PrivilegedSleepControlling: AnyObject, Sendable {
    /// 使える状態か。false のとき呼び出し側は degraded で続行する。
    var isAvailable: Bool { get }
    var onConnectionLost: (@Sendable () -> Void)? { get set }

    func setDisableSleep(_ enabled: Bool) async -> Result<Void, ControlError>
    func disconnect()
}

/// 電源と熱の観測。
public protocol PowerObserving: AnyObject, Sendable {
    func read() -> PowerReading
    var isThermalCritical: Bool { get }
    func startMonitoring(onChange: @escaping @Sendable (PowerReading) -> Void)
    func stopMonitoring()
}

/// リースのバインド対象が現在も生きているかを判定するOS境界。
public protocol ProcessWatching: Sendable {
    func isAlive(_ binding: LeaseBinding) -> Bool
}

/// PID終了をイベント駆動で通知するOS境界。
public protocol ProcessExitObserving: AnyObject, Sendable {
    @discardableResult
    func observe(pid: pid_t, onExit: @escaping @Sendable (pid_t) -> Void) -> Bool
    func cancel(pid: pid_t)
    func cancelAll()
}

/// システム全体の `disablesleep` 状態を読むOS境界。
public protocol SleepStateReading: Sendable {
    func isSleepDisabled() -> Bool?
}

public struct PMSetSleepStateReader: SleepStateReading {
    public init() {}

    public func isSleepDisabled() -> Bool? {
        PMSet.sleepDisabled()
    }
}

extension AssertionController: SleepAssertionHolding {}

extension HelperClient: PrivilegedSleepControlling {
    public var isAvailable: Bool { status == .enabled }
}

extension PowerMonitor: PowerObserving {}

extension ProcessWatcher: ProcessWatching {}

extension ProcessExitObserver: ProcessExitObserving {}
