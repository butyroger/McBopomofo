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
import InputMethodKit

/// The floating composition window. Some apps change the text being composed
/// by themselves, which drops characters or repeats a completion. For such an
/// app, the text being composed is shown in this small window above the
/// cursor instead, and the app only gets the text committed.
class FloatingCompositionPanel: NSObject {
    static let shared = FloatingCompositionPanel()

    private let padding: CGFloat = 6

    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 30),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(Int(CGWindowLevelForKey(.popUpMenuWindow)))
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        panel.contentView = background
        background.addSubview(label)
        return panel
    }()

    private lazy var label: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byClipping
        return label
    }()

    /// Whether the app of the client uses the floating composition window.
    static func isEnabled(for client: IMKTextInput?) -> Bool {
        guard let bundleID = client?.bundleIdentifier() else {
            return false
        }
        return Preferences.floatingCompositionBundleIDs.contains(bundleID)
    }

    /// Shows the text being composed, with a cursor, above the insertion
    /// point of the client. An empty text hides the window.
    func show(text: String, cursor: Int, client: IMKTextInput) {
        guard !text.isEmpty else {
            hide()
            return
        }
        let fontSize = min(max(CGFloat(Preferences.candidateListTextSize), 14), 24)
        let font = NSFont.systemFont(ofSize: fontSize)
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: font, .foregroundColor: NSColor.labelColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
        let utf16Cursor = min(max(cursor, 0), (text as NSString).length)
        attributed.insert(
            NSAttributedString(
                string: "|",
                attributes: [.font: font, .foregroundColor: NSColor.controlAccentColor]),
            at: utf16Cursor)
        label.attributedStringValue = attributed
        label.sizeToFit()

        let size = NSSize(
            width: ceil(label.frame.width) + padding * 2,
            height: ceil(label.frame.height) + padding * 2)
        label.frame.origin = NSPoint(x: padding, y: padding)

        // The insertion point of the client, as the marked text is empty.
        var lineRect = NSRect(x: 0, y: 0, width: 0, height: 16)
        client.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineRect)
        // Above the line, so that the candidate window below the line does not
        // cover it.
        var origin = NSPoint(x: lineRect.origin.x, y: lineRect.maxY + 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(lineRect.origin) })
            ?? NSScreen.main
        {
            let visible = screen.visibleFrame
            if origin.y + size.height > visible.maxY {
                origin.y = lineRect.minY - size.height - 2
            }
            origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        if panel.isVisible {
            panel.orderOut(nil)
        }
    }
}
