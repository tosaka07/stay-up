import Testing

@testable import StayUpCore

@Suite("pmset -g の解釈")
struct PMSetOutputTests {
    /// 実際の `pmset -g` の出力。**値はタブ区切り**で来る。
    ///
    /// 半角スペースだけで分割していたため、この行が一度も一致していなかった。
    /// 実物をそのまま置いて、同じ取りこぼしが再発しないようにする。
    private static let realOutput = """
        System-wide power settings:
        Currently in use:
         standby              1
         Sleep On Power Button 1
         hibernatefile        /var/vm/sleepimage
         powernap             1
         networkoversleep     0
         disksleep            10
         standbydelayhigh     86400
         sleep                1 (sleep prevented by coreaudiod)
         hibernatemode        3
         ttyskeepawake        1
         displaysleep         10
         SleepDisabled\t\t0
         tcpkeepalive         1
         highstandbythreshold 50
         standbydelaylow      10800
        """

    @Test("タブ区切りの SleepDisabled=0 を読める")
    func readsTabSeparatedZero() {
        #expect(PMSetOutput.sleepDisabled(in: Self.realOutput) == false)
    }

    @Test("タブ区切りの SleepDisabled=1 を読める")
    func readsTabSeparatedOne() {
        let output = Self.realOutput.replacingOccurrences(
            of: "SleepDisabled\t\t0",
            with: "SleepDisabled\t\t1"
        )
        #expect(PMSetOutput.sleepDisabled(in: output) == true)
    }

    @Test("スペース区切りでも読める")
    func readsSpaceSeparated() {
        #expect(PMSetOutput.sleepDisabled(in: " SleepDisabled       1") == true)
    }

    @Test("該当行がなければ nil を返す")
    func returnsNilWhenAbsent() {
        // nil は「読めなかった」であって「0」ではない。
        // 0 と混同すると、抑止されていないと誤って判断する。
        #expect(PMSetOutput.sleepDisabled(in: " displaysleep\t\t10") == nil)
    }

    @Test("値が欠けている行は nil を返す")
    func returnsNilWhenValueMissing() {
        #expect(PMSetOutput.sleepDisabled(in: "SleepDisabled") == nil)
    }

    @Test("空の出力は nil を返す")
    func returnsNilForEmptyOutput() {
        #expect(PMSetOutput.sleepDisabled(in: "") == nil)
    }
}
