import Foundation
import NaturalLanguage

// iA's Syntax Highlight. Bit values match iA's `Editor Syntax Control` mask.
struct PartOfSpeech: OptionSet, Hashable {
    let rawValue: Int
    static let adjective = PartOfSpeech(rawValue: 1)
    static let verb = PartOfSpeech(rawValue: 2)
    static let noun = PartOfSpeech(rawValue: 4)
    static let adverb = PartOfSpeech(rawValue: 8)
    static let conjunction = PartOfSpeech(rawValue: 16)
    static let all: PartOfSpeech = [.adjective, .verb, .noun, .adverb, .conjunction]

    init(rawValue: Int) { self.rawValue = rawValue }

    init?(_ tag: NLTag) {
        switch tag {
        case .adjective: self = .adjective
        case .verb: self = .verb
        case .noun: self = .noun
        case .adverb: self = .adverb
        case .conjunction: self = .conjunction
        default: return nil
        }
    }
}

enum Linguistics {
    // Reused across paragraphs: creating these costs more than running them. Main thread only.
    private static let recognizer = NLLanguageRecognizer()
    private static let tagger = NLTagger(tagSchemes: [.lexicalClass])

    static func language(of text: String) -> NLLanguage? {
        recognizer.reset()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    // Word tokens with lexical class for one paragraph. NLTagger has no zh-Hant model, so Traditional
    // Chinese is converted to Simplified first; the transform is character-for-character, so ranges carry over.
    static func tokens(in text: String, language: NLLanguage?) -> [(NSRange, NLTag?)] {
        var source = text
        var language = language
        if language == .traditionalChinese,
           let simplified = text.applyingTransform(StringTransform("Hant-Hans"), reverse: false),
           simplified.utf16.count == text.utf16.count {
            source = simplified
            language = .simplifiedChinese
        }
        tagger.string = source
        if let language { tagger.setLanguage(language, range: source.startIndex..<source.endIndex) }
        var result: [(NSRange, NLTag?)] = []
        tagger.enumerateTags(in: source.startIndex..<source.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            result.append((NSRange(range, in: source), tag))
            return true
        }
        return result
    }

    static func partsOfSpeech(_ tokens: [(NSRange, NLTag?)]) -> [(NSRange, PartOfSpeech)] {
        tokens.compactMap { range, tag in tag.flatMap(PartOfSpeech.init).map { (range, $0) } }
    }
}
