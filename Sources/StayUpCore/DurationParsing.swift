import Foundation

/// `awake.sh` と互換の duration 表記を扱う。
///
/// - `1h`, `30m`, `45s`, `1h30m`, `2h15m30s`
/// - 数字のみは秒として扱う（`3600` == `1h`）
public enum DurationParsing {
    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case empty
        case malformed(String)
        case notPositive(String)

        public var description: String {
            switch self {
            case .empty:
                "duration が空です"
            case .malformed(let input):
                "不正な duration です: '\(input)' (1h, 30m, 45s, 1h30m、または正の整数秒)"
            case .notPositive(let input):
                "duration は正の値である必要があります: '\(input)'"
            }
        }
    }

    /// 秒数を返す。
    public static func seconds(from input: String) throws -> Int {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        // 数字のみ = 秒
        if trimmed.allSatisfy(\.isNumber) {
            guard let value = Int(trimmed) else { throw ParseError.malformed(input) }
            guard value > 0 else { throw ParseError.notPositive(input) }
            return value
        }

        var total = 0
        var digits = ""
        var seenUnits = Set<Character>()
        // 単位は h > m > s の順にのみ現れてよい。
        let order: [Character: Int] = ["h": 0, "m": 1, "s": 2]
        var lastOrder = -1

        for ch in trimmed {
            if ch.isNumber {
                digits.append(ch)
                continue
            }
            guard let rank = order[ch], !digits.isEmpty, !seenUnits.contains(ch), rank > lastOrder else {
                throw ParseError.malformed(input)
            }
            guard let value = Int(digits) else { throw ParseError.malformed(input) }
            switch ch {
            case "h": total += value * 3600
            case "m": total += value * 60
            default: total += value
            }
            seenUnits.insert(ch)
            lastOrder = rank
            digits = ""
        }

        // 単位のない末尾の数字は許さない（"1h30" のような曖昧な表記を弾く）
        guard digits.isEmpty else { throw ParseError.malformed(input) }
        guard total > 0 else { throw ParseError.notPositive(input) }
        return total
    }

    /// 人間向けの表示（`1h 23m 04s`）。
    public static func format(seconds: Int) -> String {
        guard seconds > 0 else { return "0s" }
        let d = seconds / 86400
        let h = (seconds % 86400) / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if d > 0 { return String(format: "%dd %02dh %02dm", d, h, m) }
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }

    /// メニューバー向けの短い表示（`1:23`）。
    public static func formatShort(seconds: Int) -> String {
        guard seconds > 0 else { return "0m" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return String(format: "%d:%02d", h, m) }
        if m > 0 { return "\(m)m" }
        return "\(seconds)s"
    }
}
