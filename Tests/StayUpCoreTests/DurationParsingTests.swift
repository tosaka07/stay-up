import Foundation
import Testing

@testable import StayUpCore

@Suite("Duration パース（awake.sh 互換）")
struct DurationParsingTests {
    @Test("数字のみは秒として扱う", arguments: [("3600", 3600), ("1", 1), ("90", 90)])
    func plainSeconds(input: String, expected: Int) throws {
        #expect(try DurationParsing.seconds(from: input) == expected)
    }

    @Test(
        "h/m/s の組み合わせ",
        arguments: [
            ("1h", 3600),
            ("30m", 1800),
            ("45s", 45),
            ("1h30m", 5400),
            ("2h15m30s", 8130),
            ("1m30s", 90),
        ]
    )
    func unitCombinations(input: String, expected: Int) throws {
        #expect(try DurationParsing.seconds(from: input) == expected)
    }

    @Test("前後の空白は無視する")
    func trimsWhitespace() throws {
        #expect(try DurationParsing.seconds(from: "  1h  ") == 3600)
    }

    @Test(
        "不正な表記は弾く",
        arguments: ["", "abc", "1h30", "-5", "h", "1x", "30m1h", "1h1h"]
    )
    func rejectsMalformed(input: String) {
        #expect(throws: DurationParsing.ParseError.self) {
            try DurationParsing.seconds(from: input)
        }
    }

    @Test("0 は正の値でないので弾く")
    func rejectsZero() {
        #expect(throws: DurationParsing.ParseError.self) {
            try DurationParsing.seconds(from: "0")
        }
        #expect(throws: DurationParsing.ParseError.self) {
            try DurationParsing.seconds(from: "0m")
        }
    }

    @Test("Int に収まらない数値は不正として弾く")
    func rejectsOverflow() {
        let huge = String(repeating: "9", count: 100)
        #expect(throws: DurationParsing.ParseError.malformed(huge)) {
            try DurationParsing.seconds(from: huge)
        }
        #expect(throws: DurationParsing.ParseError.malformed("\(huge)h")) {
            try DurationParsing.seconds(from: "\(huge)h")
        }
    }

    @Test("表示形式")
    func formatting() {
        #expect(DurationParsing.format(seconds: 0) == "0s")
        #expect(DurationParsing.format(seconds: -1) == "0s")
        #expect(DurationParsing.format(seconds: 45) == "45s")
        #expect(DurationParsing.format(seconds: 90) == "1m 30s")
        #expect(DurationParsing.format(seconds: 5400) == "1h 30m 00s")
        #expect(DurationParsing.format(seconds: 90_061) == "1d 01h 01m")
        #expect(DurationParsing.formatShort(seconds: 0) == "0m")
        #expect(DurationParsing.formatShort(seconds: -1) == "0m")
        #expect(DurationParsing.formatShort(seconds: 45) == "45s")
        #expect(DurationParsing.formatShort(seconds: 5400) == "1:30")
        #expect(DurationParsing.formatShort(seconds: 300) == "5m")
    }
}
