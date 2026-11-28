import Foundation
import XCTest
@testable import HEX

final class WhisperAudioProcessorTests: XCTestCase {
    private func pcm(_ samples: [Int16]) -> Data {
        samples.withUnsafeBytes { Data($0) }
    }

    private func samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    func testQuietSamplesReceiveTheConfiguredGain() {
        let input: [Int16] = [0, 2_000, -2_000, 4_000, -4_000]
        let output = samples(WhisperAudioProcessor.amplify(pcm(input)))

        XCTAssertEqual(output[0], 0)
        XCTAssertEqual(output[1], 4_800)
        XCTAssertEqual(output[2], -4_800)
        XCTAssertEqual(output[3], 9_600)
        XCTAssertEqual(output[4], -9_600)
    }

    func testLoudSamplesAreSoftLimitedInsteadOfHardClipped() {
        let input: [Int16] = [15_000, -15_000, Int16.max, Int16.min]
        let output = samples(WhisperAudioProcessor.amplify(pcm(input)))

        XCTAssertEqual(output.count, input.count)
        XCTAssertGreaterThan(output[0], input[0])
        XCTAssertLessThan(output[1], input[1])
        XCTAssertGreaterThan(output[2], 25_000)
        XCTAssertLessThan(output[2], 30_000)
        XCTAssertGreaterThan(output[3], -30_000)
        XCTAssertLessThan(output[3], -25_000)
    }

    func testOutputRemainsMonotonicAcrossTheSoftKnee() {
        let input: [Int16] = [7_000, 9_000, 12_000, 16_000, 24_000, Int16.max]
        let output = samples(WhisperAudioProcessor.amplify(pcm(input)))

        for pair in zip(output, output.dropFirst()) {
            XCTAssertLessThan(pair.0, pair.1)
        }
    }

    func testFloatSamplesUseTheSameSoftLimitedWhisperGain() {
        let quiet = WhisperAudioProcessor.amplify(Float(2_000) / 32_768)
        XCTAssertEqual(quiet, Float(4_800) / 32_768, accuracy: 0.0001)

        let loud = WhisperAudioProcessor.amplify(1)
        XCTAssertLessThanOrEqual(loud, Float(30_000) / 32_768)
        XCTAssertGreaterThan(loud, 0.8)
    }

    func testOddTrailingByteAndInvalidGainArePreserved() {
        let input = Data([0x10, 0x00, 0xA5])
        let output = WhisperAudioProcessor.amplify(input)

        XCTAssertEqual(output.count, input.count)
        XCTAssertEqual(output.last, 0xA5)
        XCTAssertEqual(WhisperAudioProcessor.amplify(input, gain: 0), input)
    }
}
