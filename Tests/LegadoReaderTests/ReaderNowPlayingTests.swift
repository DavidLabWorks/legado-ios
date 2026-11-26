import MediaPlayer
import XCTest
@testable import Legado

@MainActor
final class ReaderNowPlayingTests: XCTestCase {
    func testPublishesChapterBeforeFirstBufferAndTracksPlayback() async throws {
        try XCTSkipUnless(OfflineVoicePack.zipvoice.isInstalled, "需要安装 ZipVoice 才能测试真实朗读。")
        let speech = ReaderSpeechController()
        defer { speech.stop() }
        let center = MPNowPlayingInfoCenter.default()
        let size = CGSize(width: 72, height: 96)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let cover = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        speech.configure(speechRate: 8, bookName: "测试书名", chapterTitle: "第一章", author: "作者",
                         coverAddress: "data:image/png;base64," + cover.base64EncodedString())
        let chapter = String(repeating: "窗外下起了小雨。\n", count: 10)
        speech.speak(chapter)
        XCTAssertTrue(speech.isSpeaking, speech.errorMessage ?? "")
        let info = try XCTUnwrap(center.nowPlayingInfo)
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "第一章")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "测试书名")
        XCTAssertNotNil(info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        XCTAssertGreaterThan(info[MPMediaItemPropertyPlaybackDuration] as? Double ?? 0, 0)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        for _ in 0..<300 where speech.isPreparingAudio {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(try XCTUnwrap(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double), 1.3, accuracy: 0.001)
        let artwork = try XCTUnwrap(center.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        XCTAssertEqual(artwork.bounds.size, size)
        XCTAssertEqual(artwork.image(at: CGSize(width: 48, height: 48))?.size, CGSize(width: 48, height: 48))
        try await Task.sleep(nanoseconds: 300_000_000)
        speech.pauseOrResume()
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertGreaterThan(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double ?? 0, 0)
        speech.pauseOrResume()
        XCTAssertGreaterThan(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double ?? 0, 0)
        speech.configure(speechRate: 5, bookName: "测试书名", chapterTitle: "第二章")
        speech.speak(chapter)
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "第二章")
        speech.stop()
        XCTAssertNil(center.nowPlayingInfo)
    }
}
