import Foundation

/// `CheckedContinuation` を高々 1 度だけ再開させる箱。
///
/// 「先に応答したほうを採用し、遅れて来たほうは捨てる」ための最小の道具。
/// タスクグループは離脱時に子タスクの完了を待つため、
/// **キャンセルに応じない処理を打ち切る用途には使えない**。
/// `NSAlert.runModal()` のような処理を見捨てるにはこの形が要る。
final class OneShotContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    /// 最初の 1 回だけ実際に再開する。2 回目以降は捨てる。
    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
