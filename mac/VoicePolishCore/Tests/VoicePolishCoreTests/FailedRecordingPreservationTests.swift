import XCTest
@testable import VoicePolishCore

/// 识别失败时「录音已存进历史」只能在真的存上之后才说（以前安排了后台保存就当成功）。
/// 只测存不上的分支：存得上的分支会写真实历史文件，这里不碰。
final class FailedRecordingPreservationTests: XCTestCase {

    private func makePipeline() -> VoicePolishPipeline {
        VoicePolishPipeline(aiPolisher: AIPolisher(), cloudTranscriber: CloudASRTranscriber())
    }

    func testNoAudioSaverReportsNotSaved() {
        let pipeline = makePipeline()
        pipeline.audioSaver = nil
        let done = expectation(description: "completion")
        pipeline.preserveFailedRecording(samples: [Float](repeating: 0.1, count: 16000), startedAt: Date()) { saved in
            XCTAssertFalse(saved)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testAudioSaveFailureReportsNotSaved() {
        let pipeline = makePipeline()
        var saverCalled = false
        pipeline.audioSaver = { _, _ in saverCalled = true; return nil }
        let done = expectation(description: "completion")
        pipeline.preserveFailedRecording(samples: [Float](repeating: 0.1, count: 16000), startedAt: Date()) { saved in
            XCTAssertFalse(saved)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertTrue(saverCalled)
    }
}
