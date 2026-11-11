// Copyright (c) 2026 and onwards The McBopomofo Authors.
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use,
// copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following
// conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

import AppKit

/// English words for the completions of a word typed in the smart English
/// mode: the words the user has typed first, and then the system dictionary.
@objc class EnglishWords: NSObject {
    private static let minimumLength = 3
    private static let maximumCompletions = 20
    private static let reloadInterval: TimeInterval = 60

    /// The counts of the words typed on this device, and on all devices.
    private static var localCounts: [String: Int]?
    private static var counts: [String: Int] = [:]
    private static var lastLoaded = Date.distantPast

    /// Remembers the words, such as those just committed.
    @objc static func record(_ words: [String]) {
        loadIfNeeded()
        var changed = false
        for word in words where word.count >= minimumLength {
            localCounts?[word, default: 0] += 1
            counts[word, default: 0] += 1
            changed = true
        }
        if changed {
            save()
        }
    }

    @objc static func completions(for word: String) -> [String] {
        guard word.count >= 2 else {
            return []
        }
        loadIfNeeded()
        let lowercased = word.lowercased()
        let byCount = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        // Typed words that start with the word, such as ChatGPT for "chat",
        // and then those that contain the letters in order, such as
        // associated for "aocd".
        let typed =
            byCount.map(\.key).filter { $0.lowercased().hasPrefix(lowercased) }
            + byCount.map(\.key).filter {
                $0.first?.lowercased() == lowercased.first.map(String.init)
                    && isSubsequence(lowercased, of: $0.lowercased())
            }
        // A word typed once may be a typo, so it comes after the dictionary.
        let frequent = typed.filter { (counts[$0] ?? 0) >= 2 }
        let once = typed.filter { (counts[$0] ?? 0) < 2 }

        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (word as NSString).length)
        var results = frequent
        results += checker.completions(
            forPartialWordRange: range, in: word, language: "en", inSpellDocumentWithTag: 0) ?? []
        results += once
        results += checker.guesses(
            forWordRange: range, in: word, language: "en", inSpellDocumentWithTag: 0) ?? []

        let capitalized = word.first?.isUppercase ?? false
        var seen: Set<String> = [word]
        var unique: [String] = []
        for result in results {
            // Only single words, which the composing buffer can hold.
            guard result.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                continue
            }
            var candidate = result
            if capitalized && candidate == candidate.lowercased() {
                candidate = candidate.prefix(1).uppercased() + candidate.dropFirst()
            }
            if seen.insert(candidate).inserted {
                unique.append(candidate)
            }
            if unique.count >= maximumCompletions {
                break
            }
        }
        return unique
    }

    /// Well-known words with uppercase letters after the first one, whose
    /// case is fixed even if they have never been typed.
    private static let wellKnownMixedCaseWords: [String: String] = {
        let words = [
            "iPhone", "iPad", "iPod", "iMac", "iCloud", "iMessage", "iTunes", "iOS", "iPadOS",
            "macOS", "watchOS", "tvOS", "visionOS", "AirPods", "AirDrop", "AirPlay", "AirTag",
            "MacBook", "FaceTime", "AppleCare", "HomePod", "CarPlay",
            "OpenAI", "ChatGPT", "DeepSeek", "GitHub", "GitLab", "YouTube", "LinkedIn", "PayPal",
            "WhatsApp", "TikTok", "WeChat", "PowerPoint", "OneDrive", "OneNote", "SharePoint",
            "FileMaker", "JavaScript", "TypeScript", "PostgreSQL", "MySQL", "MariaDB", "SQLite",
            "MongoDB", "WordPress", "WooCommerce", "PlayStation", "SmartThings", "DevOps",
            "eBay", "eSIM", "McDonald", "LaTeX", "PhD", "VoIP",
        ]
        var result: [String: String] = [:]
        for word in words {
            result[word.lowercased()] = word
        }
        return result
    }()

    /// Whether a word has an uppercase letter after the first one, but is not
    /// all uppercase, like iPhone and OpenAI, but not Apple or NASA.
    private static func isMixedCase(_ word: String) -> Bool {
        word.dropFirst().contains(where: \.isUppercase) && word != word.uppercased()
    }

    /// The case to use for a word typed in lowercase, like "iPhone" for
    /// "iphone": the word typed most often in that case, or a well-known one.
    @objc static func preferredCase(for word: String) -> String? {
        guard word.count >= 2, word == word.lowercased() else {
            return nil
        }
        loadIfNeeded()
        // A word typed only once may be a typo.
        let typed = counts.filter { $0.value >= 2 && $0.key.lowercased() == word && isMixedCase($0.key) }
        if let best = typed.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
            return best.key
        }
        return wellKnownMixedCaseWords[word]
    }

    private static func isSubsequence(_ letters: String, of word: String) -> Bool {
        var iterator = word.makeIterator()
        for letter in letters {
            var found = false
            while let c = iterator.next() {
                if c == letter {
                    found = true
                    break
                }
            }
            if !found {
                return false
            }
        }
        return true
    }

    // Each line of a file is a word, a tab, and the count.
    private static func read(_ path: String) -> [String: Int] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }
        var result: [String: Int] = [:]
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            if parts.count == 2, let count = Int(parts[1]) {
                result[String(parts[0])] = count
            }
        }
        return result
    }

    private static func loadIfNeeded() {
        if localCounts != nil && Date().timeIntervalSince(lastLoaded) < reloadInterval {
            return
        }
        let localPath = LanguageModelManager.englishWordsDataPath
        if localCounts == nil {
            localCounts = read(localPath)
        }
        var merged = localCounts ?? [:]
        let folder = LanguageModelManager.englishWordsFolderPath
        let filenames = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        for filename in filenames
        where filename.hasSuffix(".txt") && filename != (localPath as NSString).lastPathComponent {
            for (word, count) in read((folder as NSString).appendingPathComponent(filename)) {
                merged[word, default: 0] += count
            }
        }
        counts = merged
        lastLoaded = Date()
    }

    private static func save() {
        guard let localCounts else {
            return
        }
        let content = localCounts.map { "\($0.key)\t\($0.value)\n" }.sorted().joined()
        let path = LanguageModelManager.englishWordsDataPath
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
