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
import SwiftUI

private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// The kinds of vocabulary managed in the window.
enum VocabularyKind: Int, CaseIterable, Identifiable {
    case phrases, excluded, english, sentences, temporary, templates

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .phrases: return L("Chinese Phrases")
        case .excluded: return L("Excluded Phrases")
        case .english: return L("English Words")
        case .sentences: return L("Common Sentences")
        case .temporary: return L("Temporary Phrases")
        case .templates: return L("Text Templates")
        }
    }

    var help: String {
        switch self {
        case .phrases:
            return L("Phrases added here come first in the candidates. The reading is filled in automatically, and can be changed for a character with more than one reading.")
        case .excluded:
            return L("Phrases listed here never appear in the candidates, such as excluding 你 to have 妳 first.")
        case .english:
            return L("Words typed twice or more, or added here, come first in the English completions with Tab.")
        case .sentences:
            return L("A sentence sent three times is remembered, and the rest of it is suggested after typing its beginning, to be taken with Tab. Sentences added here are remembered at once and never forgotten.")
        case .temporary:
            return L("Phrases picked once come first for 30 days, and are added to the Chinese phrases when typed again.")
        case .templates:
            return L("Press ` and type the code to insert the text. Write \\n for a line break.")
        }
    }

    var columnTitles: [String] {
        switch self {
        case .phrases, .excluded: return [L("Phrase"), L("Reading")]
        case .english: return [L("Word"), L("Times")]
        case .sentences: return [L("Sentence"), L("Times"), L("Status")]
        case .temporary: return [L("Phrase"), L("Reading"), L("Picked")]
        case .templates: return [L("Code"), L("Text")]
        }
    }

    /// The fields to fill in to add an entry.
    var fieldTitles: [String] {
        switch self {
        case .phrases, .excluded: return [L("Phrase"), L("Reading")]
        case .english: return [L("Word")]
        case .sentences: return [L("Sentence")]
        case .temporary: return []
        case .templates: return [L("Code"), L("Text")]
        }
    }

    var canEdit: Bool {
        self == .phrases || self == .excluded || self == .templates
    }
}

struct VocabularyRow: Identifiable, Hashable {
    let id: String
    let columns: [String]
    /// The line in the file, the word, the sentence or "value reading".
    let key: String
}

final class VocabularyModel: ObservableObject {
    @Published var kind: VocabularyKind = .phrases {
        didSet {
            cancelEditing()
            selection.removeAll()
            reload()
        }
    }
    @Published var rows: [VocabularyRow] = []
    @Published var search = ""
    @Published var selection = Set<String>()
    @Published var field1 = "" {
        didSet {
            fillReading()
        }
    }
    @Published var field2 = ""
    @Published var editingKey: String?
    @Published var message = ""

    /// Whether the reading has been typed by the user, so that it is not
    /// filled in automatically.
    private var readingEdited = false
    private var settingField = false

    var filteredRows: [VocabularyRow] {
        let keyword = search.trimmingCharacters(in: .whitespaces)
        if keyword.isEmpty {
            return rows
        }
        return rows.filter { row in
            row.columns.contains { $0.localizedCaseInsensitiveContains(keyword) }
        }
    }

    // MARK: Loading

    func reload() {
        switch kind {
        case .phrases:
            rows = Self.phraseRows(path: LanguageModelManager.userPhrasesDataPathMcBopomofo)
        case .excluded:
            rows = Self.phraseRows(path: LanguageModelManager.excludedPhrasesDataPathMcBopomofo)
        case .english:
            rows = EnglishWords.allWords().map {
                VocabularyRow(id: $0.word, columns: [$0.word, "\($0.count)"], key: $0.word)
            }
        case .sentences:
            rows = CommonSentences.allEntries().map { item in
                let status: String
                if item.entry.pinned {
                    status = L("Added")
                } else if item.entry.count >= CommonSentences.threshold {
                    status = L("Remembered")
                } else {
                    status = String(
                        format: L("%d more times"), CommonSentences.threshold - item.entry.count)
                }
                return VocabularyRow(
                    id: item.sentence, columns: [item.sentence, "\(item.entry.count)", status],
                    key: item.sentence)
            }
        case .temporary:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            rows = LanguageModelManager.allTemporaryPhrases()
                .sorted { $0.value.doubleValue > $1.value.doubleValue }
                .compactMap { phrase, time in
                    let parts = phrase.components(separatedBy: " ")
                    guard parts.count == 2 else {
                        return nil
                    }
                    let date = formatter.string(
                        from: Date(timeIntervalSince1970: time.doubleValue))
                    return VocabularyRow(
                        id: phrase, columns: [parts[0], parts[1], date], key: phrase)
                }
        case .templates:
            rows = Self.lines(path: LanguageModelManager.textTemplatesDataPath).enumerated()
                .compactMap { index, line in
                    let parts = line.split(
                        separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2 else {
                        return nil
                    }
                    return VocabularyRow(
                        id: "\(index)\t\(line)", columns: [String(parts[0]), String(parts[1])],
                        key: line)
                }
        }
        selection = selection.filter { id in rows.contains { $0.id == id } }
    }

    private static func lines(path: String) -> [String] {
        let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return content.components(separatedBy: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#")
        }
    }

    // Each line is the phrase, a space, and the reading.
    private static func phraseRows(path: String) -> [VocabularyRow] {
        lines(path: path).enumerated().compactMap { index, line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else {
                return nil
            }
            return VocabularyRow(
                id: "\(index)\t\(line)", columns: [String(parts[0]), String(parts[1])], key: line)
        }
    }

    // MARK: Editing

    private func fillReading() {
        guard !settingField, kind == .phrases || kind == .excluded, !readingEdited else {
            return
        }
        let phrase = field1.trimmingCharacters(in: .whitespaces)
        settingField = true
        field2 = phrase.isEmpty ? "" : ServiceProvider().extractReading(from: phrase)
        settingField = false
    }

    func readingChangedByUser() {
        if !settingField {
            readingEdited = true
        }
    }

    func beginEditing() {
        guard kind.canEdit, selection.count == 1, let id = selection.first,
            let row = rows.first(where: { $0.id == id })
        else {
            return
        }
        settingField = true
        field1 = row.columns[0]
        field2 = row.columns[1]
        settingField = false
        readingEdited = true
        editingKey = row.key
        message = ""
    }

    func cancelEditing() {
        settingField = true
        field1 = ""
        field2 = ""
        settingField = false
        readingEdited = false
        editingKey = nil
    }

    /// Adds the entry in the fields, or saves the one being edited.
    func commit() {
        let value1 = field1.trimmingCharacters(in: .whitespaces)
        let value2 = field2.trimmingCharacters(in: .whitespaces)
        guard !value1.isEmpty else {
            NSSound.beep()
            return
        }
        switch kind {
        case .phrases, .excluded:
            guard !value2.isEmpty, !value2.contains("？"), !value1.contains(" ") else {
                message = L("Please type the reading in Bopomofo, with \"-\" between syllables, like ㄒㄧㄠˇ-ㄇㄞˋ.")
                return
            }
            let path =
                kind == .phrases
                ? LanguageModelManager.userPhrasesDataPathMcBopomofo
                : LanguageModelManager.excludedPhrasesDataPathMcBopomofo
            let line = "\(value1) \(value2)"
            if editingKey == nil && rows.contains(where: { $0.key == line }) {
                message = String(format: L("\"%@\" is already in the list."), value1)
                return
            }
            Self.write(line: line, replacing: editingKey, path: path)
        case .templates:
            guard !value2.isEmpty, !value1.contains("\t"), !value2.contains("\t") else {
                message = L("Please type the code and the text.")
                return
            }
            Self.write(
                line: "\(value1)\t\(value2)", replacing: editingKey,
                path: LanguageModelManager.textTemplatesDataPath)
        case .english:
            guard value1.count >= 2, value1.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                message = L("An English word has two or more letters.")
                return
            }
            EnglishWords.add(value1)
        case .sentences:
            guard CommonSentences.isValid(value1) else {
                message = L("A sentence has 6 to 40 characters or words, without punctuation.")
                return
            }
            CommonSentences.add(value1)
        case .temporary:
            return
        }
        message = editingKey == nil ? String(format: L("Added \"%@\"."), value1) : L("Saved.")
        cancelEditing()
        reload()
    }

    func deleteSelected() {
        let keys = rows.filter { selection.contains($0.id) }.map(\.key)
        guard !keys.isEmpty else {
            NSSound.beep()
            return
        }
        switch kind {
        case .phrases:
            Self.remove(lines: keys, path: LanguageModelManager.userPhrasesDataPathMcBopomofo)
        case .excluded:
            Self.remove(lines: keys, path: LanguageModelManager.excludedPhrasesDataPathMcBopomofo)
        case .templates:
            Self.remove(lines: keys, path: LanguageModelManager.textTemplatesDataPath)
        case .english:
            keys.forEach { EnglishWords.remove($0) }
        case .sentences:
            keys.forEach { CommonSentences.remove($0) }
        case .temporary:
            keys.forEach { LanguageModelManager.forgetTemporaryPhrase($0) }
        }
        message = String(format: L("Deleted %d."), keys.count)
        selection.removeAll()
        cancelEditing()
        reload()
    }

    /// Adds the selected temporary phrases to the Chinese phrases.
    func addSelectedToPhrases() {
        let keys = rows.filter { selection.contains($0.id) }.map(\.key)
        guard kind == .temporary, !keys.isEmpty else {
            NSSound.beep()
            return
        }
        for key in keys {
            LanguageModelManager.writeUserPhrase(key)
            LanguageModelManager.forgetTemporaryPhrase(key)
        }
        message = String(format: L("Added %d to the Chinese phrases."), keys.count)
        selection.removeAll()
        reload()
    }

    func revealFile() {
        let path: String
        switch kind {
        case .phrases: path = LanguageModelManager.userPhrasesDataPathMcBopomofo
        case .excluded: path = LanguageModelManager.excludedPhrasesDataPathMcBopomofo
        case .templates: path = LanguageModelManager.textTemplatesDataPath
        default: path = LanguageModelManager.userOverrideModelFolderPath
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Files

    /// Replaces the line, or appends it, keeping the comments and the order.
    private static func write(line: String, replacing oldLine: String?, path: String) {
        var content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var lines = content.components(separatedBy: "\n")
        if let oldLine, let index = lines.firstIndex(of: oldLine) {
            lines[index] = line
            content = lines.joined(separator: "\n")
        } else {
            if !content.isEmpty && !content.hasSuffix("\n") {
                content += "\n"
            }
            content += line + "\n"
        }
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func remove(lines toRemove: [String], path: String) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return
        }
        var remaining = toRemove
        let lines = content.components(separatedBy: "\n").filter { line in
            if let index = remaining.firstIndex(of: line) {
                remaining.remove(at: index)
                return false
            }
            return true
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

struct VocabularyManagerView: View {
    @ObservedObject var model: VocabularyModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $model.kind) {
                ForEach(VocabularyKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(model.kind.help)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                TextField(L("Search"), text: $model.search)
                    .textFieldStyle(.roundedBorder)
                Text(String(format: L("%d items"), model.filteredRows.count))
                    .foregroundColor(.secondary)
                    .fixedSize()
            }

            header
            List(model.filteredRows, selection: $model.selection) { row in
                HStack(spacing: 8) {
                    ForEach(Array(row.columns.enumerated()), id: \.offset) { index, column in
                        Text(column)
                            .lineLimit(1)
                            .frame(
                                maxWidth: index == 0 || isWideColumn(index) ? .infinity : 110,
                                alignment: .leading)
                    }
                }
                .tag(row.id)
            }
            .frame(minHeight: 260)

            if !model.kind.fieldTitles.isEmpty {
                editor
            }

            HStack {
                if model.kind.canEdit {
                    Button(L("Edit")) { model.beginEditing() }
                        .disabled(model.selection.count != 1)
                }
                Button(L("Delete")) { model.deleteSelected() }
                    .disabled(model.selection.isEmpty)
                if model.kind == .temporary {
                    Button(L("Add to Chinese Phrases")) { model.addSelectedToPhrases() }
                        .disabled(model.selection.isEmpty)
                }
                Text(model.message)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Spacer()
                Button(L("Show in Finder")) { model.revealFile() }
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 560)
        .onAppear { model.reload() }
    }

    /// The text of a template and the reading of a phrase may be long.
    private func isWideColumn(_ index: Int) -> Bool {
        (model.kind == .templates || model.kind == .phrases || model.kind == .excluded)
            && index == 1
    }

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.kind.columnTitles.enumerated()), id: \.offset) { index, title in
                Text(title)
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                    .frame(
                        maxWidth: index == 0 || isWideColumn(index) ? .infinity : 110,
                        alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
    }

    private var editor: some View {
        HStack {
            let titles = model.kind.fieldTitles
            TextField(titles[0], text: $model.field1)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: titles.count > 1 ? 200 : .infinity)
            if titles.count > 1 {
                TextField(
                    titles[1],
                    text: Binding(
                        get: { model.field2 },
                        set: {
                            model.field2 = $0
                            model.readingChangedByUser()
                        })
                )
                .textFieldStyle(.roundedBorder)
            }
            Button(model.editingKey == nil ? L("Add") : L("Save")) { model.commit() }
                .keyboardShortcut(.defaultAction)
            if model.editingKey != nil {
                Button(L("Cancel")) { model.cancelEditing() }
            }
        }
    }
}

@objc(VocabularyManagerWindowController)
final class VocabularyManagerWindowController: NSWindowController {
    private let model = VocabularyModel()

    init() {
        let hostingController = NSHostingController(
            rootView: VocabularyManagerView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = L("Manage Vocabulary")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 600))
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndActivate() {
        model.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
