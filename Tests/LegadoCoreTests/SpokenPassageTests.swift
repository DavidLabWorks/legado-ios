import Foundation
import Testing
@testable import LegadoCore

struct SpokenPassageTests {
    @Test func zipVoicePronouncesNumbersInChinese() {
        #expect(SpokenPassage.zipVoiceText(for: "12") == "十二")
        #expect(SpokenPassage.zipVoiceText(for: "😀第１２章，2026年，编号007。") == "😀第十二章，二零二六年，编号零零七。")
        #expect(SpokenPassage.zipVoiceText(for: "1,024人，增长3.50%。") == "一千零二十四人，增长百分之三点五零。")
        #expect(SpokenPassage.zipVoiceText(for: "过去12年。") == "过去十二年。")
    }

    @Test func repeatedSentencesKeepTheirOwnUTF16Offsets() {
        let text = "  “出发了！”\r\n\r\n他推开门。   他推开门。"
        let passages = SpokenPassage.passages(in: text, reading: nil)
        #expect(passages.map(\.text) == ["“出发了！”", "他推开门。", "他推开门。"])
        #expect(passages.map(\.sentence) == [
            (text as NSString).range(of: "“出发了！”"),
            (text as NSString).range(of: "他推开门。"),
            (text as NSString).range(of: "他推开门。", options: .backwards)
        ])
    }

    @Test func pageClipsTheAudioButHighlightsTheSentenceInTheChapter() {
        let text = "😀他推开门，向前走了两步。\n还有下一句。"
        let page = (text as NSString).range(of: "向前走了两步。")
        let passages = SpokenPassage.passages(in: text, reading: page)
        #expect(passages.map(\.text) == ["向前走了两步。"])
        #expect(passages.first?.position == page.location)
        #expect(passages.first?.sentence == (text as NSString).range(of: "😀他推开门，向前走了两步。"))
    }

    @Test func longSentenceCanStartAtItsFirstNaturalBreakAfterTwentyCharacters() {
        let lines = ["窗外的雨已经停了很久，", "他听见巷子深处传来脚步声，", "悄悄走到窗前，", "远处山上的雾还没有散开，", "门前的树叶挂着水珠。"]
        let passages = SpokenPassage.passages(in: lines.joined(), reading: nil)
        #expect(passages.first?.text == lines[0] + lines[1])
        #expect(passages.map(\.text).joined() == lines.joined())
    }

    @Test func sentenceGroupsRespectParagraphsAndCharacterBudget() {
        let passages = SpokenPassage.passages(in: "天亮了。他推开门。\r\n风停了。\n\n她走了。", reading: nil)
        #expect(passages.count == 4)
        #expect(passages.map(\.paragraph) == [0, 0, 1, 2])
        #expect(SpokenPassage.groupEnd(in: passages, from: 0, characterLimit: 24) == 2)
        #expect(SpokenPassage.groupEnd(in: passages, from: 0, characterLimit: 5) == 1)
        #expect(SpokenPassage.groupEnd(in: passages, from: 2, characterLimit: 60) == 3)
    }

    @Test func groupedAudioKeepsEveryFrameAndChangesHighlightDuringThePause() {
        let passages = SpokenPassage.passages(in: "他推开门。她看着他。", reading: nil)
        let samples = [Float](repeating: 0.2, count: 10_560)
                    + [Float](repeating: 0, count: 2_880)
                    + [Float](repeating: 0.4, count: 10_560)
        let audio = samples.withUnsafeBytes { Data($0) }
        let clips = SpokenPassage.splitAudio(audio, for: passages[...])
        #expect(clips.count == 2)
        #expect((10_560...13_440).contains(clips[0].count / 4))
        #expect(clips[0] + clips[1] == audio)
    }

    @Test func paragraphPauseTopsUpExistingSilenceOnlyOnce() {
        let samples = [Float](repeating: 0.2, count: 480) + [Float](repeating: 0, count: 2_400)
        var audio = samples.withUnsafeBytes { Data($0) }
        SpokenPassage.finishParagraph(&audio)
        #expect(audio.count == (480 + 9_600) * 4)
        SpokenPassage.finishParagraph(&audio)
        #expect(audio.count == (480 + 9_600) * 4)
    }

    @Test func longSentenceKeepsOneHighlightAcrossChunks() {
        let text = String(repeating: "门口的树叶挂着水珠，", count: 10) + "天亮了。"
        let passages = SpokenPassage.passages(in: text, reading: nil)
        #expect(passages.count > 1)
        #expect(passages.map(\.text).joined() == text)
        #expect(passages.allSatisfy { $0.sentence == NSRange(location: 0, length: text.utf16.count) })
        for passage in passages {
            let range = NSRange(location: passage.position, length: passage.text.utf16.count)
            #expect((text as NSString).substring(with: range) == passage.text)
        }
    }

    @Test func playbackReserveCoversShortOpeningFollowedBySlowLongPassage() {
        let text = "我们走了。\n再会。\n" + String(repeating: "他", count: 38) + "。"
        let passages = SpokenPassage.passages(in: text, reading: nil)
        let reserve = SpokenPassage.playbackReserve(in: passages, from: 1, synthesisPerCharacter: 0.32, playbackPerCharacter: 0.18, recovering: false)
        // The third passage must be ready by the time the second has finished playing.
        #expect(SpokenPassage.playbackReserve(in: passages, from: 1, synthesisPerCharacter: 2, playbackPerCharacter: 0.18, recovering: true) == 36)
        #expect(reserve >= 42 * 0.32 - 3 * 0.18)
        #expect(SpokenPassage.playbackReserve(in: passages, from: 1, synthesisPerCharacter: 0.05, playbackPerCharacter: 0.18, recovering: false) == 6)
        #expect(SpokenPassage.playbackReserve(in: passages, from: passages.count, synthesisPerCharacter: 1, playbackPerCharacter: 1, recovering: false) == 0)
    }
}
