import Foundation

/// `pmset -g` の出力を読む。
///
/// **値はタブ区切りで来る**。実際の 1 行はこうなっている。
///
/// ```
/// " SleepDisabled\t\t0\n"
/// ```
///
/// 半角スペースだけで分割すると行全体が 1 要素になり、一度も一致しない。
/// サービスとヘルパーの双方が同じ判定を使うため、ここに 1 つだけ置く。
public enum PMSetOutput {
    /// `SleepDisabled` の値。該当行がなければ nil。
    ///
    /// nil は「読めなかった」であって「0」ではない。
    /// 呼び出し側は両者を区別すること。
    public static func sleepDisabled(in output: String) -> Bool? {
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[0] == "SleepDisabled" else { continue }
            return parts[1] == "1"
        }
        return nil
    }
}
