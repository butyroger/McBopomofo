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

import Cocoa

/// A titled group of consecutive candidates in a grid candidate controller.
@objc(VTGridCandidateSection)
public class GridCandidateSection: NSObject {
    @objc public private(set) var title: String
    @objc public private(set) var count: UInt

    @objc public init(title: String, count: UInt) {
        self.title = title
        self.count = count
    }
}

/// One row of the grid: a run of candidates in a section, and the title of
/// the section if the row is the first one of it.
private struct GridRow {
    var title: String?
    var start: UInt
    var count: UInt
}

private class GridCandidateView: NSView {
    var rows: [GridRow] = []
    var firstVisibleRow: Int = 0
    var visibleRowCount: Int = 0
    var columnCount: Int = 9
    var highlightedIndex: UInt = 0
    var keyLabels: [String] = []
    var candidates: (UInt) -> String = { _ in "" }

    var keyLabelFont: NSFont = .systemFont(ofSize: 14)
    var candidateFont: NSFont = .systemFont(ofSize: 18)
    var titleFont: NSFont = .systemFont(ofSize: 12)

    var target: AnyObject?
    var action: Selector?
    var clickedIndex: UInt = .max

    private(set) var titleWidth: CGFloat = 0
    private(set) var cellWidth: CGFloat = 0
    private(set) var cellHeight: CGFloat = 0
    private(set) var keyLabelHeight: CGFloat = 0
    private let padding: CGFloat = 6

    override var isFlipped: Bool { true }

    func layout(allTitles: [String], sampleCandidates: [String]) -> NSSize {
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont]
        titleWidth = ceil(
            allTitles.map { ($0 as NSString).size(withAttributes: titleAttrs).width }.max() ?? 0)
        if titleWidth > 0 {
            titleWidth += padding * 2
        }

        let candidateAttrs: [NSAttributedString.Key: Any] = [.font: candidateFont]
        let widest = sampleCandidates.map {
            ($0 as NSString).size(withAttributes: candidateAttrs).width
        }.max() ?? 0
        cellWidth = ceil(max(widest, candidateFont.pointSize) + padding * 2)
        keyLabelHeight = ceil(keyLabelFont.pointSize * 1.1)
        cellHeight = ceil(candidateFont.pointSize * 1.3) + keyLabelHeight

        let width = titleWidth + cellWidth * CGFloat(columnCount)
        let height = cellHeight * CGFloat(max(visibleRowCount, 1))
        return NSSize(width: width, height: height)
    }

    private func cellRect(row: Int, column: Int) -> NSRect {
        NSRect(
            x: titleWidth + cellWidth * CGFloat(column),
            y: cellHeight * CGFloat(row - firstVisibleRow),
            width: cellWidth, height: cellHeight)
    }

    override func draw(_: NSRect) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: titleFont, .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let candidateAttrs: [NSAttributedString.Key: Any] = [
            .font: candidateFont, .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let keyLabelAttrs: [NSAttributedString.Key: Any] = [
            .font: keyLabelFont, .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let lastRow = min(firstVisibleRow + visibleRowCount, rows.count)
        for rowIndex in firstVisibleRow..<lastRow {
            let row = rows[rowIndex]
            let rowRect = NSRect(
                x: 0, y: cellHeight * CGFloat(rowIndex - firstVisibleRow),
                width: bounds.width, height: cellHeight)
            if row.title != nil, rowIndex != firstVisibleRow {
                NSColor.separatorColor.setFill()
                NSRect(x: 0, y: rowRect.minY, width: bounds.width, height: 1).fill()
            }
            if let title = row.title {
                let titleRect = NSRect(
                    x: padding, y: rowRect.minY + keyLabelHeight, width: titleWidth - padding,
                    height: cellHeight - keyLabelHeight)
                (title as NSString).draw(in: titleRect, withAttributes: titleAttrs)
            }

            let isHighlightedRow =
                highlightedIndex >= row.start && highlightedIndex < row.start + row.count
            for column in 0..<Int(row.count) {
                let index = row.start + UInt(column)
                let rect = cellRect(row: rowIndex, column: column)
                var attrs = candidateAttrs
                if index == highlightedIndex {
                    NSColor.controlAccentColor.setFill()
                    NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
                        .fill()
                    attrs[.foregroundColor] = NSColor.white
                }
                if isHighlightedRow, column < keyLabels.count {
                    var labelAttrs = keyLabelAttrs
                    if index == highlightedIndex {
                        labelAttrs[.foregroundColor] = NSColor.white
                    }
                    let labelRect = NSRect(
                        x: rect.minX, y: rect.minY, width: rect.width, height: keyLabelHeight)
                    (keyLabels[column] as NSString).draw(in: labelRect, withAttributes: labelAttrs)
                }
                let textRect = NSRect(
                    x: rect.minX, y: rect.minY + keyLabelHeight, width: rect.width,
                    height: rect.height - keyLabelHeight)
                (candidates(index) as NSString).draw(in: textRect, withAttributes: attrs)
            }
        }
    }

    private func hitIndex(_ event: NSEvent) -> UInt? {
        let location = convert(event.locationInWindow, from: nil)
        guard cellHeight > 0, cellWidth > 0, location.x >= titleWidth else {
            return nil
        }
        let rowIndex = firstVisibleRow + Int(location.y / cellHeight)
        let column = Int((location.x - titleWidth) / cellWidth)
        guard rowIndex >= 0, rowIndex < rows.count, column >= 0,
            column < Int(rows[rowIndex].count)
        else {
            return nil
        }
        return rows[rowIndex].start + UInt(column)
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = hitIndex(event) else {
            return
        }
        clickedIndex = index
        if let target = target as? NSObject, let action = action {
            target.perform(action, with: self)
        }
    }
}

/// A candidate window that shows the candidates in a grid, with each section
/// starting a new row titled with the section name. Designed for picking
/// from many symbols.
@objc(VTGridCandidateController)
public class GridCandidateController: CandidateController {
    /// The sections of the candidates. If they do not add up to the number of
    /// candidates, all candidates are shown as one untitled section.
    @objc public var sections: [GridCandidateSection] = []
    @objc public var visibleRowCount: Int = 8

    private var candidateView: GridCandidateView
    private var rows: [GridRow] = []

    public init() {
        let contentRect = NSRect(x: 128.0, y: 128.0, width: 0.0, height: 0.0)
        let styleMask: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        let panel = NSPanel(
            contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        panel.level = NSWindow.Level(Int(kCGPopUpMenuWindowLevel) + 1)
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false

        let effect = NSVisualEffectView(frame: .zero)
        effect.blendingMode = .behindWindow
        effect.material = .popover
        effect.state = .active
        effect.maskImage = .mask(withCornerRadius: 6)
        panel.contentView = effect

        candidateView = GridCandidateView(frame: .zero)
        panel.contentView?.addSubview(candidateView)
        panel.setAccessibilityRole(.group)

        super.init(window: panel)

        candidateView.target = self
        candidateView.action = #selector(candidateViewMouseDidClick(_:))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var candidateCount: UInt {
        delegate?.candidateCountForController(self) ?? 0
    }

    private var columnCount: UInt {
        UInt(max(keyLabels.count, 1))
    }

    private func buildRows() {
        rows = []
        let total = candidateCount
        var groups: [(String?, UInt)] = sections.map { ($0.title, $0.count) }
        if groups.reduce(0, { $0 + $1.1 }) != total {
            groups = [(nil, total)]
        }
        var start: UInt = 0
        for (title, count) in groups where count > 0 {
            var offset: UInt = 0
            while offset < count {
                let rowCount = min(columnCount, count - offset)
                rows.append(
                    GridRow(title: offset == 0 ? title : nil, start: start + offset, count: rowCount)
                )
                offset += rowCount
            }
            start += count
        }
    }

    private func rowIndex(of candidateIndex: UInt) -> Int? {
        rows.firstIndex { candidateIndex >= $0.start && candidateIndex < $0.start + $0.count }
    }

    private func layoutCandidateView() {
        guard let delegate = delegate else {
            return
        }
        let highlightedRow = rowIndex(of: candidateView.highlightedIndex) ?? 0
        // Keep the highlighted row visible, scrolling by pages.
        let visible = max(visibleRowCount, 1)
        if highlightedRow < candidateView.firstVisibleRow
            || highlightedRow >= candidateView.firstVisibleRow + visible
        {
            candidateView.firstVisibleRow = (highlightedRow / visible) * visible
        }

        candidateView.rows = rows
        candidateView.columnCount = Int(columnCount)
        candidateView.visibleRowCount = min(visible, rows.count)
        candidateView.keyLabels = keyLabels.map { $0.displayedText }
        candidateView.keyLabelFont = keyLabelFont
        candidateView.candidateFont = candidateFont
        candidateView.titleFont = .systemFont(ofSize: max(keyLabelFont.pointSize, 12))
        candidateView.candidates = { [weak self] index in
            guard let self else {
                return ""
            }
            return delegate.candidateController(self, candidateAtIndex: index)
        }

        let total = candidateCount
        var samples: [String] = []
        for index in 0..<min(total, 400) {
            samples.append(delegate.candidateController(self, candidateAtIndex: index))
        }
        let size = candidateView.layout(
            allTitles: rows.compactMap { $0.title }, sampleCandidates: samples)
        candidateView.frame = NSRect(origin: .zero, size: size)

        if var frameRect = window?.frame {
            let topLeftPoint = NSPoint(x: frameRect.minX, y: frameRect.maxY)
            frameRect.size = size
            frameRect.origin = NSPoint(x: topLeftPoint.x, y: topLeftPoint.y - size.height)
            window?.setFrame(frameRect, display: false)
        }
        candidateView.setNeedsDisplay(candidateView.bounds)
    }

    private func moveHighlight(to index: UInt) -> Bool {
        guard index < candidateCount else {
            return false
        }
        candidateView.highlightedIndex = index
        layoutCandidateView()
        return true
    }

    private func moveHighlight(byRows delta: Int) -> Bool {
        guard let current = rowIndex(of: candidateView.highlightedIndex) else {
            return false
        }
        let target = current + delta
        guard target >= 0, target < rows.count else {
            return false
        }
        let column = candidateView.highlightedIndex - rows[current].start
        let row = rows[target]
        return moveHighlight(to: row.start + min(column, row.count - 1))
    }

    override public func reloadData() {
        buildRows()
        candidateView.highlightedIndex = 0
        candidateView.firstVisibleRow = 0
        layoutCandidateView()
    }

    override public func showNextPage() -> Bool {
        let rowsLeft = rows.count - 1 - (rowIndex(of: candidateView.highlightedIndex) ?? 0)
        return moveHighlight(byRows: min(max(visibleRowCount, 1), rowsLeft))
            || moveHighlight(to: candidateCount - 1)
    }

    override public func showPreviousPage() -> Bool {
        let rowsBefore = rowIndex(of: candidateView.highlightedIndex) ?? 0
        return moveHighlight(byRows: -min(max(visibleRowCount, 1), rowsBefore))
    }

    override public func highlightNextCandidate() -> Bool {
        moveHighlight(to: candidateView.highlightedIndex + 1)
    }

    override public func highlightPreviousCandidate() -> Bool {
        guard candidateView.highlightedIndex > 0 else {
            return false
        }
        return moveHighlight(to: candidateView.highlightedIndex - 1)
    }

    @objc public func highlightCandidateInNextRow() -> Bool {
        moveHighlight(byRows: 1)
    }

    @objc public func highlightCandidateInPreviousRow() -> Bool {
        moveHighlight(byRows: -1)
    }

    /// The key labels apply to the row of the highlighted candidate.
    override public func candidateIndexAtKeyLabelIndex(_ index: UInt) -> UInt {
        guard let row = rowIndex(of: candidateView.highlightedIndex), index < rows[row].count
        else {
            return UInt.max
        }
        return rows[row].start + index
    }

    override public var selectedCandidateIndex: UInt {
        get {
            candidateView.highlightedIndex
        }
        set {
            _ = moveHighlight(to: newValue)
        }
    }

    @objc fileprivate func candidateViewMouseDidClick(_: Any) {
        candidateView.highlightedIndex = candidateView.clickedIndex
        candidateView.setNeedsDisplay(candidateView.bounds)
        delegate?.candidateController(self, didSelectCandidateAtIndex: candidateView.clickedIndex)
    }
}
