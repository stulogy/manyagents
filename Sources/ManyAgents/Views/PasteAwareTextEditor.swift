import SwiftUI
import AppKit

/// Wraps an NSTextView so we can intercept paste events for images and
/// route them to a separate handler. Also gives us proper Return-to-send /
/// Shift-Return-to-newline behavior that SwiftUI's TextField can't express.
struct PasteAwareTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var font: NSFont
    var minHeight: CGFloat = 26
    var maxHeight: CGFloat = 200
    var onSubmit: () -> Void
    var onImagePaste: ([Data]) -> Void

    func makeNSView(context: Context) -> PasteScrollView {
        let scroll = PasteScrollView()
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true

        let textView = PasteAwareNSTextView()
        textView.font = font
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.placeholderAttributedString = placeholderAttr()
        textView.delegate = context.coordinator
        // Wire callbacks via the coordinator so SwiftUI re-renders update
        // them instead of leaving the textView holding stale closures.
        context.coordinator.onImagePaste = onImagePaste
        context.coordinator.onSubmit = onSubmit
        context.coordinator.textBinding = $text
        context.coordinator.heightBinding = $height
        context.coordinator.minHeight = minHeight
        context.coordinator.maxHeight = maxHeight
        textView.onImagePaste = { [weak coordinator = context.coordinator] data in
            coordinator?.onImagePaste(data)
        }

        scroll.documentView = textView
        scroll.textView = textView

        // Become first responder on next runloop — without this the
        // representable shows up but typing goes nowhere because nothing in
        // the SwiftUI tree owns the focus.
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scroll
    }

    func updateNSView(_ nsView: PasteScrollView, context: Context) {
        // Refresh coordinator callbacks every render so the closures see the
        // latest ComposerView state. The coordinator-as-stale-snapshot trap
        // is what made the previous version look "dead" when typing.
        context.coordinator.onImagePaste = onImagePaste
        context.coordinator.onSubmit = onSubmit
        context.coordinator.textBinding = $text
        context.coordinator.heightBinding = $height
        context.coordinator.minHeight = minHeight
        context.coordinator.maxHeight = maxHeight

        guard let textView = nsView.textView else { return }
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let safeRange = NSRange(location: min(selection.location, text.count), length: 0)
            textView.setSelectedRange(safeRange)
        }
        textView.placeholderAttributedString = placeholderAttr()
        context.coordinator.recomputeHeight(textView: textView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func placeholderAttr() -> NSAttributedString {
        NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font
        ])
    }

    /// Single source of truth for text changes, submission, height tracking,
    /// and the doCommandBy key-routing. Mutable callback properties so
    /// updateNSView can refresh them on every SwiftUI tick.
    final class Coordinator: NSObject, NSTextViewDelegate {
        var textBinding: Binding<String> = .constant("")
        var heightBinding: Binding<CGFloat> = .constant(26)
        var minHeight: CGFloat = 26
        var maxHeight: CGFloat = 200
        var onSubmit: () -> Void = {}
        var onImagePaste: ([Data]) -> Void = { _ in }

        /// A per-text-view undo manager owned by this coordinator. Without it
        /// the NSTextView registers undo into the WINDOW's undo manager, which
        /// outlives the field — so when the composer is rebuilt on a tab switch
        /// the old view's undo actions linger as dangling references and ⌘Z
        /// (Undo) dereferences a freed object and hard-crashes the app. Scoping
        /// undo to the coordinator means the stack dies with the field.
        private let scopedUndoManager = UndoManager()

        func undoManager(for view: NSTextView) -> UndoManager? {
            scopedUndoManager
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Write back to the binding so SwiftUI sees what the user typed.
            textBinding.wrappedValue = tv.string
            recomputeHeight(textView: tv)
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let shift = NSEvent.modifierFlags.contains(.shift)
                if shift {
                    textView.insertText("\n", replacementRange: textView.selectedRange())
                    return true
                } else {
                    onSubmit()
                    return true
                }
            }
            return false
        }

        func recomputeHeight(textView: NSTextView) {
            guard let lm = textView.layoutManager,
                  let tc = textView.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            let computed = used.height + textView.textContainerInset.height * 2 + 2
            let clamped = max(minHeight, min(maxHeight, computed))
            if abs(clamped - heightBinding.wrappedValue) > 0.5 {
                DispatchQueue.main.async { self.heightBinding.wrappedValue = clamped }
            }
        }
    }
}

final class PasteScrollView: NSScrollView {
    weak var textView: PasteAwareNSTextView?
}

/// NSTextView subclass that intercepts paste events for image payloads.
final class PasteAwareNSTextView: NSTextView {
    var onImagePaste: (([Data]) -> Void)?
    var placeholderAttributedString: NSAttributedString? {
        didSet { needsDisplay = true }
    }

    /// Tell NSText that image types are paste-able. Without this, the system
    /// validation for ⌘V sees only text types on a screenshot-only pasteboard
    /// and refuses the action with an error beep — `paste:` never runs.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.png, .tiff, .fileURL]
    }

    /// Menu/keyboard equivalent validation. We allow paste whenever there's
    /// an image on the pasteboard, in addition to the usual text cases.
    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:)) {
            let pb = NSPasteboard.general
            if pb.canReadObject(forClasses: [NSImage.self], options: nil) {
                return true
            }
        }
        return super.validateMenuItem(menuItem)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        let typeNames = pb.types?.map { $0.rawValue }.joined(separator: ", ") ?? "(none)"
        NSLog("[ManyAgents.paste] types on pasteboard: %@", typeNames)
        let images = Self.extractPngs(from: pb)
        NSLog("[ManyAgents.paste] extracted %d image(s)", images.count)
        if !images.isEmpty {
            onImagePaste?(images)
            return
        }
        super.paste(sender)
    }

    /// Robust pasteboard → PNG extractor. Tries every common path: direct
    /// PNG data, NSImage(pasteboard:) — which handles TIFF, PDF, and PICT
    /// transparently — and finally file URLs (e.g. dragged from Finder).
    private static func extractPngs(from pb: NSPasteboard) -> [Data] {
        var out: [Data] = []
        // 1. Direct PNG.
        if let data = pb.data(forType: .png) {
            out.append(data)
        }
        // 2. NSImage's built-in pasteboard reader covers TIFF, PDF, PICT…
        if out.isEmpty, let img = NSImage(pasteboard: pb) {
            if let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                out.append(png)
            }
        }
        // 3. Multiple file URLs (Finder copy).
        if out.isEmpty,
           let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls {
                let ext = url.pathExtension.lowercased()
                guard ["png", "jpg", "jpeg", "gif", "tiff", "tif", "heic", "webp", "bmp"].contains(ext),
                      let data = try? Data(contentsOf: url) else { continue }
                if ext == "png" {
                    out.append(data)
                } else if let rep = NSBitmapImageRep(data: data),
                          let png = rep.representation(using: .png, properties: [:]) {
                    out.append(png)
                }
            }
        }
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, let placeholder = placeholderAttributedString {
            let origin = NSPoint(x: textContainerInset.width + 5,
                                 y: textContainerInset.height + 2)
            placeholder.draw(at: origin)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}
