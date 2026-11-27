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

    func testAppPreviewKeepsLiveScopeAtIdle() {
        XCTAssertFalse(
            KeyboardStageWaveformPresentation.usesRestingVisual(
                defersDotScopeUntilActive: false,
                phase: .idle
            )
        )
    }
}
