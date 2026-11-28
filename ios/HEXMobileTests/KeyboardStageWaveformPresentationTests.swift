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

    func testAppPreviewKeepsLiveScopeAtIdle() {
        XCTAssertFalse(
            KeyboardStageWaveformPresentation.usesRestingVisual(
                defersDotScopeUntilActive: false,
                phase: .idle
            )
        )
    }
}
