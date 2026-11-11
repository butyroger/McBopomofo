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

import Foundation

/// Entries removed by the user in the vocabulary manager, shared by all the
/// devices, so that a device does not bring back what another one has removed
/// from its own file. Each line of the file is the kind, the key and the time.
@objc class RemovedEntries: NSObject {
    @objc static let english = "english"
    @objc static let sentence = "sentence"
    @objc static let temporaryPhrase = "temporary"

    private static var entries: [String: TimeInterval] = [:]
    private static var lastLoaded = Date.distantPast

    private static var path: String {
        (LanguageModelManager.userOverrideModelFolderPath as NSString)
            .appendingPathComponent("removed.txt")
    }

    /// The time the entry was removed, or 0 if it has not been removed.
    @objc static func removedTime(kind: String, key: String) -> TimeInterval {
        loadIfNeeded()
        return entries["\(kind)\t\(key)"] ?? 0
    }

    @objc static func add(kind: String, key: String) {
        loadFiles()
        entries["\(kind)\t\(key)"] = Date().timeIntervalSince1970
        save()
    }

    @objc static func remove(kind: String, key: String) {
        loadFiles()
        if entries.removeValue(forKey: "\(kind)\t\(key)") != nil {
            save()
        }
    }

    private static func loadIfNeeded() {
        if Date().timeIntervalSince(lastLoaded) >= 60 {
            loadFiles()
        }
    }

    private static func loadFiles() {
        var result: [String: TimeInterval] = [:]
        let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            if parts.count == 3, let time = TimeInterval(parts[2]) {
                result["\(parts[0])\t\(parts[1])"] = time
            }
        }
        entries = result
        lastLoaded = Date()
    }

    private static func save() {
        let content = entries.map { "\($0.key)\t\(Int($0.value))\n" }.sorted().joined()
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Sentences the user types often. A sentence sent three times is remembered,
/// and then the rest of it is suggested after typing its beginning, to be
/// taken with Tab. Each device writes its own file in the "sentences" folder
/// of the learning folder, and the files of all devices are merged.
@objc class CommonSentences: NSObject {
    struct Entry {
        var count: Int
        var lastUsed: TimeInterval
        /// Added by the user, which is never forgotten.
        var pinned: Bool
    }

    static let threshold = 3
    static let minimumLength = 6
    static let maximumLength = 40
    private static let minimumPrefixLength = 2
    private static let reloadInterval: TimeInterval = 60

    private static var localEntries: [String: Entry]?
    private static var mergedEntries: [String: Entry] = [:]
    private static var lastLoaded = Date.distantPast

    private static var folderPath: String {
        (LanguageModelManager.userOverrideModelFolderPath as NSString)
            .appendingPathComponent("sentences")
    }

    private static var localPath: String {
        (folderPath as NSString).appendingPathComponent(
            (LanguageModelManager.englishWordsDataPath as NSString).lastPathComponent)
    }

    /// The length of a sentence, counting an English word or a number as one.
    static func length(of sentence: String) -> Int {
        var count = 0
        var inWord = false
        for character in sentence {
            if character.isASCII && (character.isLetter || character.isNumber) {
                if !inWord {
                    count += 1
                    inWord = true
                }
            } else {
                inWord = false
                if !character.isWhitespace {
                    count += 1
                }
            }
        }
        return count
    }

    /// Whether a sentence can be remembered: 6 to 40 characters or words,
    /// without any punctuation.
    static func isValid(_ sentence: String) -> Bool {
        let length = length(of: sentence)
        return length >= minimumLength && length <= maximumLength
            && sentence.rangeOfCharacter(from: separators) == nil
    }

    private static let separators = CharacterSet.punctuationCharacters
        .union(.symbols).union(.newlines).union(CharacterSet(charactersIn: "\t"))

    /// How long a sentence is kept without being used. The more it has been
    /// used, the longer it is kept: three months, and one more for every
    /// three more times.
    private static func lifetime(of entry: Entry) -> TimeInterval {
        90 * 86400 + TimeInterval(max(0, entry.count - threshold) / 3) * 30 * 86400
    }

    private static func isAlive(_ sentence: String, _ entry: Entry, now: TimeInterval) -> Bool {
        if RemovedEntries.removedTime(kind: RemovedEntries.sentence, key: sentence) >= entry.lastUsed {
            return false
        }
        return entry.pinned || now - entry.lastUsed <= lifetime(of: entry)
    }

    /// Remembers the sentences in the text just committed.
    @objc static func record(_ text: String) {
        guard Preferences.commonSentencesEnabled else {
            return
        }
        let sentences = text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { isValid($0) }
        guard !sentences.isEmpty else {
            return
        }
        loadIfNeeded()
        let now = Date().timeIntervalSince1970
        for sentence in sentences {
            var entry = localEntries?[sentence] ?? Entry(count: 0, lastUsed: now, pinned: false)
            entry.count += 1
            entry.lastUsed = now
            localEntries?[sentence] = entry
            var merged = mergedEntries[sentence] ?? Entry(count: 0, lastUsed: now, pinned: false)
            merged.count += 1
            merged.lastUsed = now
            mergedEntries[sentence] = merged
        }
        save()
    }

    /// The rest of a remembered sentence that starts with the text, which is
    /// what has been typed since the beginning or the last punctuation.
    @objc static func completion(forTypedText text: String) -> String? {
        guard Preferences.commonSentencesEnabled else {
            return nil
        }
        var prefix = text
        if let range = prefix.rangeOfCharacter(from: separators, options: .backwards) {
            prefix = String(prefix[range.upperBound...])
        }
        prefix = String(prefix.drop(while: { $0.isWhitespace }))
        guard prefix.count >= minimumPrefixLength else {
            return nil
        }
        loadIfNeeded()
        let now = Date().timeIntervalSince1970
        let best = mergedEntries
            .filter {
                ($0.value.pinned || $0.value.count >= threshold) && $0.key.count > prefix.count
                    && $0.key.hasPrefix(prefix) && isAlive($0.key, $0.value, now: now)
            }
            .max {
                $0.value.count != $1.value.count
                    ? $0.value.count < $1.value.count : $0.value.lastUsed < $1.value.lastUsed
            }
        guard let best else {
            return nil
        }
        return String(best.key.dropFirst(prefix.count))
    }

    // MARK: - Vocabulary manager

    /// The sentences of all the devices, remembered or not yet.
    static func allEntries() -> [(sentence: String, entry: Entry)] {
        loadFiles()
        let now = Date().timeIntervalSince1970
        return mergedEntries.filter { isAlive($0.key, $0.value, now: now) }
            .map { (sentence: $0.key, entry: $0.value) }
            .sorted {
                $0.entry.count != $1.entry.count
                    ? $0.entry.count > $1.entry.count : $0.entry.lastUsed > $1.entry.lastUsed
            }
    }

    /// Adds a sentence by the user, which is remembered at once and never
    /// forgotten.
    static func add(_ sentence: String) {
        loadFiles()
        RemovedEntries.remove(kind: RemovedEntries.sentence, key: sentence)
        let now = Date().timeIntervalSince1970
        var entry = localEntries?[sentence] ?? Entry(count: 0, lastUsed: now, pinned: true)
        entry.count = max(entry.count, threshold)
        entry.lastUsed = now
        entry.pinned = true
        localEntries?[sentence] = entry
        save()
        loadFiles()
    }

    static func remove(_ sentence: String) {
        loadFiles()
        localEntries?.removeValue(forKey: sentence)
        save()
        RemovedEntries.add(kind: RemovedEntries.sentence, key: sentence)
        loadFiles()
    }

    // MARK: - Files

    // Each line is the sentence, the count, the time last used, and 1 if it
    // has been added by the user.
    private static func read(_ path: String) -> [String: Entry] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }
        var result: [String: Entry] = [:]
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3, let count = Int(parts[1]), let time = TimeInterval(parts[2])
            else {
                continue
            }
            result[String(parts[0])] = Entry(
                count: count, lastUsed: time, pinned: parts.count >= 4 && parts[3] == "1")
        }
        return result
    }

    private static func loadIfNeeded() {
        if localEntries != nil && Date().timeIntervalSince(lastLoaded) < reloadInterval {
            return
        }
        loadFiles()
    }

    private static func loadFiles() {
        if localEntries == nil {
            localEntries = read(localPath)
        }
        var merged = localEntries ?? [:]
        let filenames = (try? FileManager.default.contentsOfDirectory(atPath: folderPath)) ?? []
        for filename in filenames
        where filename.hasSuffix(".txt") && filename != (localPath as NSString).lastPathComponent {
            for (sentence, entry) in read((folderPath as NSString).appendingPathComponent(filename)) {
                var existing = merged[sentence] ?? Entry(count: 0, lastUsed: 0, pinned: false)
                existing.count += entry.count
                existing.lastUsed = max(existing.lastUsed, entry.lastUsed)
                existing.pinned = existing.pinned || entry.pinned
                merged[sentence] = existing
            }
        }
        mergedEntries = merged
        lastLoaded = Date()
    }

    private static func save() {
        guard let localEntries else {
            return
        }
        let now = Date().timeIntervalSince1970
        // Forget the sentences that have not been used for a long time.
        let content = localEntries
            .filter { $0.value.pinned || now - $0.value.lastUsed <= lifetime(of: $0.value) }
            .map {
                "\($0.key)\t\($0.value.count)\t\(Int($0.value.lastUsed))\t\($0.value.pinned ? 1 : 0)\n"
            }
            .sorted().joined()
        let path = localPath
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
