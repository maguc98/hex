import XCTest
@testable import HEX

final class SpokenPunctuationTests: XCTestCase {
    func testChineseSpokenPunctuationUsesFullWidthMarksWithoutSpaces() {
        XCTAssertEqual(
            SpokenPunctuation.format("你好 逗号 世界", language: "zh-CN"),
            "你好，世界"
        )
        XCTAssertEqual(
            SpokenPunctuation.format("真的 句号 不是 问号", language: "zh-CN"),
            "真的。不是？"
        )
    }

    func testTraditionalChineseSpokenPunctuation() {
        XCTAssertEqual(
            SpokenPunctuation.format("你好 逗點 世界", language: "zh-TW"),
            "你好，世界"
        )
        XCTAssertEqual(
            SpokenPunctuation.format("真的 感嘆號", language: "zh-TW"),
            "真的！"
        )
    }

    func testChineseSpokenQuotesAndParenthesesDoNotAddSpaces() {
        XCTAssertEqual(
            SpokenPunctuation.format("他说 开引号 你好 关引号", language: "zh-CN"),
            "他说“你好”"
        )
        XCTAssertEqual(
            SpokenPunctuation.format("打开 左括号 设置 右括号", language: "zh-CN"),
            "打开（设置）"
        )
    }
}
