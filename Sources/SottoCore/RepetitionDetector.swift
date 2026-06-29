import Foundation

/// Detects repetitive loops of words (5-grams repeating 3 or more times).
/// Lives in SottoCore so it is easily unit-tested.
public func hasRepetitiveLoops(_ text: String) -> Bool {
    let words = text.components(separatedBy: .whitespacesAndNewlines)
        .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
        .filter { !$0.isEmpty }
    
    guard words.count >= 15 else { return false }
    
    var ngrams: [String: Int] = [:]
    for i in 0...(words.count - 5) {
        let ngram = words[i..<(i + 5)].joined(separator: " ")
        ngrams[ngram, default: 0] += 1
        if ngrams[ngram]! >= 3 {
            return true
        }
    }
    return false
}
