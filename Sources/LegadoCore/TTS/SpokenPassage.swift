import Foundation

struct SpokenPassage {
    let text: String
    // A shared slice of the paragraph also supports starting playback at a later marker.
    let synthesisText: Substring
    let sentence: NSRange
    let position: Int
    let paragraph: Int
    var isChapterTitle = false

    static func passages(in text: String, reading range: NSRange?) -> [Self] {
        let source = text as NSString
        let requested = range ?? NSRange(location: 0, length: source.length)
        var result: [Self] = []
        var paragraph = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byParagraphs) { _, paragraphRange, _, _ in
            let selected = NSIntersectionRange(requested, NSRange(paragraphRange, in: text))
            guard selected.length > 0 else { return }
            let paragraphText = source.substring(with: selected)
            let countBeforeParagraph = result.count
            text.enumerateSubstrings(in: paragraphRange, options: .bySentences) { _, span, _, _ in
                let raw = NSRange(span, in: text)
                let sentenceText = source.substring(with: raw).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sentenceText.isEmpty else { return }
                let sentence = source.range(of: sentenceText, options: .literal, range: raw)
                let overlap = NSIntersectionRange(requested, sentence)
                guard overlap.length > 0 else { return }
                let excerpt = source.substring(with: overlap)
                var cursor = excerpt.startIndex
                while cursor < excerpt.endIndex {
                    var end = excerpt.index(cursor, offsetBy: 72, limitedBy: excerpt.endIndex) ?? excerpt.endIndex
                    // Keep playback positions within long sentences for page following and seeking.
                    if let limit = excerpt.index(cursor, offsetBy: 44, limitedBy: excerpt.endIndex), limit < excerpt.endIndex {
                        let middle = excerpt.index(cursor, offsetBy: 20)
                        if let split = excerpt[middle..<limit].firstIndex(where: { "，,；;：:、".contains($0) }) {
                            end = excerpt.index(after: split)
                        } else if end < excerpt.endIndex, let space = excerpt[middle..<end].lastIndex(where: \.isWhitespace) {
                            end = excerpt.index(after: space)
                        }
                    }
                    let chunk = String(excerpt[cursor..<end])
                    if chunk.rangeOfCharacter(from: .alphanumerics) != nil {
                        let position = overlap.location + cursor.utf16Offset(in: excerpt)
                        let offset = result.count == countBeforeParagraph ? 0 : position - selected.location
                        let start = String.Index(utf16Offset: offset, in: paragraphText)
                        result.append(Self(text: chunk, synthesisText: paragraphText[start...],
                                           sentence: sentence, position: position, paragraph: paragraph))
                    }
                    cursor = end
                }
            }
            if result.count > countBeforeParagraph { paragraph += 1 }
        }
        return result
    }

    static func chapterPassages(in text: String, reading range: NSRange?, title: String) -> [Self] {
        let body = passages(in: text, reading: range)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = body.first, !title.isEmpty else { return body }

        let source = text as NSString
        let openingLine = source.paragraphRange(for: NSRange(location: first.position, length: 0))
        if source.substring(with: openingLine).trimmingCharacters(in: .whitespacesAndNewlines) == title {
            return body
        }

        // The announcement has no range in the book. Anchor it to the listening start.
        let announcement = passages(in: title, reading: nil).map {
            Self(text: $0.text, synthesisText: $0.synthesisText, sentence: NSRange(location: first.position, length: 0),
                 position: first.position, paragraph: -1 - $0.paragraph, isChapterTitle: true)
        }
        return announcement + body
    }

    static func groupEnd(in passages: [Self], from start: Int) -> Int {
        var end = start + 1
        while end < passages.count && passages[end].paragraph == passages[start].paragraph {
            end += 1
        }
        return end
    }

    // By each group's delivery deadline only the preceding groups are available to play.
    static func playbackReserve(
        in passages: [Self], from start: Int,
        synthesisPerCharacter: Double, playbackPerCharacter: Double, recovering: Bool
    ) -> TimeInterval {
        let limit = recovering ? 36.0 : 16.0
        var preparation = 0.0
        var playback = 0.0
        guard start < passages.count else { return 0 }
        var reserve = recovering ? 6.0 : 0.75
        var index = start
        while index < passages.count && playback < 60 && reserve < limit {
            let end = groupEnd(in: passages, from: index)
            let characters = Double(passages[index].synthesisText.count)
            preparation += characters * synthesisPerCharacter
            reserve = max(reserve, preparation * 1.15 - playback)
            playback += characters * playbackPerCharacter
            index = end
        }
        return min(limit, reserve)
    }

    // For grouped sentences the engine supplies PCM without word timestamps.
    // Locate a quiet 40 ms interval near each expected break, keeping all samples.
    static func splitAudio(_ audio: Data, for group: ArraySlice<Self>) -> [Data] {
        guard group.count > 1 else { return [audio] }
        let step = 480 // 20 ms at the engine's 24 kHz output rate
        let levels: [Float] = audio.withUnsafeBytes { bytes in
            let pcm = bytes.bindMemory(to: Float.self)
            return stride(from: 0, to: pcm.count, by: step).map { start in
                var sum: Float = 0
                for sample in pcm[start..<min(start + step, pcm.count)] { sum += sample * sample }
                return sum / Float(step)
            }
        }
        let weights = group.map { max(1, $0.text.filter { $0.isLetter || $0.isNumber }.count) }
        // A degenerate model output still yields one range per passage or fails at enqueue.
        let frameCount = audio.count / MemoryLayout<Float>.size
        var result: [Data] = []
        var frame = 0
        var weightLeft = weights.reduce(0, +)
        for (index, weight) in weights.dropLast().enumerated() {
            let remaining = weights.count - index - 1
            let expected = frame + (frameCount - frame) * weight / weightLeft
            let radius = min(36_000, min(expected - frame, frameCount - expected) / 2)
            let lo = max(1, (expected - radius) / step)
            let hi = min(levels.count - 1, (expected + radius) / step)
            var cut = expected
            if lo <= hi {
                let window = (lo...hi).min { lhs, rhs in
                    func cost(_ bin: Int) -> Float {
                        let distance = Float(abs(bin * step - expected)) / Float(max(radius, 1))
                        return levels[bin - 1] + levels[bin] + 0.00005 * distance * distance
                    }
                    return cost(lhs) < cost(rhs)
                }!
                cut = window * step
            }
            cut = min(max(frame + 1, cut), max(frame, frameCount - remaining))
            result.append(audio.subdata(in: frame*4..<cut*4))
            frame = cut
            weightLeft -= weight
        }
        result.append(audio.subdata(in: frame*4..<audio.count))
        return result
    }

    static func paragraphPaddingFrames(in audio: Data) -> Int {
        // Top up existing trailing quiet to 400 ms; punctuation often supplies it already.
        let target = 9_600
        let quiet = audio.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Float.self).suffix(target).reversed().prefix { abs($0) < 0.004 }.count
        }
        return target - quiet
    }
}
