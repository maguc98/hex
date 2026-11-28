import XCTest
@testable import HEX

final class KeyboardStageWaveformPresentationTests: XCTestCase {
    func testKeyboardExtensionUsesRestingWaveformWhenIdle() {
        XCTAssertTrue(
            KeyboardStageWaveformPresentation.usesRestingVisual(
                defersDotScopeUntilActive: true,
                phase: .idle
            )
        )
    }

    func testKeyboardExtensionKeepsRestingWaveformVisibleAfterFailure() {
        XCTAssertTrue(
            KeyboardStageWaveformPresentation.usesRestingVisual(
                defersDotScopeUntilActive: true,
                phase: .failed
            )
        )
    }

    func testRecordingAndProcessingContinueUsingLiveScope() {
        for phase in [DotScopePhase.recording, .processing] {
            XCTAssertFalse(
                KeyboardStageWaveformPresentation.usesRestingVisual(
                    defersDotScopeUntilActive: true,
                    phase: phase
                )
            )
        }
    }

    func testNoiseReductionOffKeepsOriginalLanguageAndStyleLayout() {
        XCTAssertTrue(KeyboardNoiseReductionTopBarPresentation.showsLanguageAndStyle(noiseReductionEnabled: false))
        XCTAssertFalse(KeyboardNoiseReductionTopBarPresentation.showsReferenceWaveform(
            noiseReductionEnabled: false,
            hasReferenceChannel: true
        ))
    }

    func testNoiseReductionOnHidesLanguageAndStyleAndUsesReferenceCapsule() {
        XCTAssertFalse(KeyboardNoiseReductionTopBarPresentation.showsLanguageAndStyle(noiseReductionEnabled: true))
        XCTAssertTrue(KeyboardNoiseReductionTopBarPresentation.showsReferenceWaveform(
            noiseReductionEnabled: true,
            hasReferenceChannel: true
        ))
        XCTAssertTrue(KeyboardNoiseReductionTopBarPresentation.showsReferenceWaitingState(
            noiseReductionEnabled: true,
            hasReferenceChannel: false
        ))
    }

    func testReferenceWaveformIsNotShownWithoutASecondReportedChannel() {
        XCTAssertFalse(KeyboardNoiseReductionTopBarPresentation.showsReferenceWaveform(
            noiseReductionEnabled: true,
            hasReferenceChannel: false
        ))
    }

    func testNoiseReferenceStatusDoesNotClaimToWaitWhileIdle() {
        XCTAssertEqual(
            KeyboardNoiseReductionTopBarPresentation.referenceStatusText(for: .idle),
            "录音时启动辅助声道"
        )
    }

    func testNoiseReferenceStatusDistinguishesConnectingAndUnsupportedInput() {
        XCTAssertEqual(
            KeyboardNoiseReductionTopBarPresentation.referenceStatusText(for: .waiting),
            "等待辅助声道"
        )
        XCTAssertEqual(
            KeyboardNoiseReductionTopBarPresentation.referenceStatusText(for: .unavailable),
            "当前输入未提供辅助声道"
        )
    }

    func testAvailableReferenceChannelHasNoWaitingMessage() {
        XCTAssertEqual(
            KeyboardNoiseReductionTopBarPresentation.referenceStatusText(for: .available),
            "辅助声道已连接"
        )
    }

    func testNativeCaptureRouteHasItsOwnAccurateStatus() {
        XCTAssertEqual(
            KeyboardNoiseReductionTopBarPresentation.referenceStatusText(for: .nativeCapture),
            "Hex 原生录音中"
        )
    }

    func testAppPreviewKeepsLiveScopeAtIdle() {
        XCTAssertFalse(
            KeyboardStageWaveformPresentation.usesRestingVisual(
                defersDotScopeUntilActive: false,
                phase: .idle
            )
        )
    }
}
