import XCTest
@testable import HEX

final class RecognitionResumeTests: XCTestCase {
    func testCancelsSpeechTaskCreatedDuringCancellationRace() async {
        let resume = RecognitionResume()
        let taskCancelled = expectation(description: "newly created recognition task is cancelled")

        let recognition = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                resume.start(continuation) {
                    // Reproduce cancellation after the continuation is installed but
                    // before the Speech task handle is returned by its factory.
                    resume.cancel()
                    return {
                        taskCancelled.fulfill()
                    }
                }
            }
        }

        do {
            _ = try await recognition.value
            XCTFail("Expected the recognition to be cancelled")
        } catch is CancellationError {
            // Expected: cancellation finishes the waiting transcription immediately.
        } catch {
            XCTFail("Unexpected error: \\(error)")
        }

        await fulfillment(of: [taskCancelled], timeout: 1)
    }

    func testCancellationBeforeStartDoesNotCreateTask() async {
        let resume = RecognitionResume()
        resume.cancel()

        let taskCreated = expectation(description: "task factory is not called")
        taskCreated.isInverted = true

        let recognition = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                resume.start(continuation) {
                    taskCreated.fulfill()
                    return {}
                }
            }
        }

        do {
            _ = try await recognition.value
            XCTFail("Expected the recognition to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \\(error)")
        }

        await fulfillment(of: [taskCreated], timeout: 0.05)
    }
}
