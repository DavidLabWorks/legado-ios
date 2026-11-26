import Foundation

struct SpokenPassage {
    let text: String
    let sentence: NSRange
    let position: Int
    let paragraph: Int

    private static let numeral = try! NSRegularExpression(
        pattern: #"([0-9０-９]+(?:,[0-9０-９]{3}(?![0-9０-９]))*)(?:[.．]([0-9０-９]+))?([%％年]?)"#
    )
    private static let chineseNumbers: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .spellOut
        return formatter
    }()

    // ZipVoice skips digit strings during lexicon lookup. Keep all reader offsets in the source text.
    static func zipVoiceText(for text: String) -> String {
        let source = text as NSString
        let matches = numeral.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        let digits = Array("零一二三四五六七八九")
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            let integer = source.substring(with: match.range(at: 1)).compactMap(\.wholeNumberValue)
            let fraction = match.range(at: 2)
            let suffix = source.substring(with: match.range(at: 3))
            let isYear = suffix == "年" && fraction.location == NSNotFound && integer.count == 4
            var words: String
            // Preserve leading zeros and spell long digit sequences without rounding.
            if !isYear, integer.first != 0, integer.count <= 15,
               let cardinal = chineseNumbers.string(from: NSNumber(value: integer.reduce(Int64(0)) { $0 * 10 + Int64($1) })) {
                words = cardinal.replacingOccurrences(of: "〇", with: "零")
            } else {
                words = String(integer.map { digits[$0] })
            }
            if fraction.location != NSNotFound {
                words += "点" + String(source.substring(with: fraction).compactMap(\.wholeNumberValue).map { digits[$0] })
            }
            if suffix == "年" { words += suffix }
            if suffix == "%" || suffix == "％" { words = "百分之" + words }
            result.replaceCharacters(in: match.range, with: words)
        }
        return result as String
    }

    static func passages(in text: String, reading range: NSRange?) -> [Self] {
        let source = text as NSString
        let requested = range ?? NSRange(location: 0, length: source.length)
        var result: [Self] = []
        var paragraph = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byParagraphs) { _, paragraphRange, _, _ in
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
                    // Split unusually long sentences at a clause boundary to limit cold-start time.
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
                        result.append(Self(text: chunk, sentence: sentence, position: overlap.location + cursor.utf16Offset(in: excerpt), paragraph: paragraph))
                    }
                    cursor = end
                }
            }
            if result.count > countBeforeParagraph { paragraph += 1 }
        }
        return result
    }

    // Send adjacent sentences from the same paragraph through one synthesis pass.
    // A clipped page or an already split long sentence keeps its own playback marker.
    static func groupEnd(in passages: [Self], from start: Int, characterLimit: Int) -> Int {
        let first = passages[start]
        var end = start + 1
        var characters = first.text.count
        guard first.text.utf16.count == first.sentence.length else { return end }
        while end < passages.count && end - start < 4 {
            let next = passages[end]
            guard next.paragraph == first.paragraph, next.text.utf16.count == next.sentence.length,
                  characters + next.text.count <= characterLimit else { break }
            characters += next.text.count
            end += 1
        }
        return end
    }

    // By each group's delivery deadline only the preceding groups are available to play.
    static func playbackReserve(
        in passages: [Self], from start: Int,
        synthesisPerCharacter: Double, playbackPerCharacter: Double, recovering: Bool
    ) -> TimeInterval {
        guard start < passages.count else { return 0 }
        var index = start
        var preparation = 0.0
        var playback = 0.0
        let limit = recovering ? 36.0 : 16.0
        var reserve = 6.0
        while index < passages.count && playback < 60 && reserve < limit {
            let end = groupEnd(in: passages, from: index, characterLimit: 60)
            let characters = Double(passages[index..<end].reduce(0) { $0 + $1.text.count })
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

    static func finishParagraph(_ audio: inout Data) {
        // Top up existing trailing quiet to 400 ms; punctuation often supplies it already.
        let target = 9_600
        let quiet = audio.withUnsafeBytes { bytes in
            bytes.bindMemory(to: Float.self).suffix(target).reversed().prefix { abs($0) < 0.004 }.count
        }
        audio.append(Data(count: (target - quiet) * MemoryLayout<Float>.size))
    }
}
