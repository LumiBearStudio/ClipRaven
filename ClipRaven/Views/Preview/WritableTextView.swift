import SwiftUI
import AppKit

/// NSViewRepresentable wrapper for NSTextView with Apple Intelligence Writing Tools support.
/// Falls back gracefully on macOS < 15.
struct WritableTextView: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = .systemFont(ofSize: 12)
    var isEditable: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = font
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.string = text

        // Apple Intelligence Writing Tools (macOS 15+)
        // .default shows "글쓰기 도구 표시" in the context menu (same as system apps)
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .default
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.font = font
        textView.isEditable = isEditable
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WritableTextView

        init(_ parent: WritableTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
