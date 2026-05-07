import SwiftUI
import ClipRavenSync

struct ClipContextMenu: View {
    let clip: Clip
    var onCopy: () -> Void = {}
    var onPin: () -> Void = {}
    var onEdit: () -> Void = {}
    var onAddToStack: () -> Void = {}
    var onDelete: () -> Void = {}
    var onShowTags: () -> Void = {}
    var onPasteWithTransform: ((TextTransform) -> Void)? = nil
    var onFindSimilarImages: (() -> Void)? = nil

    private var isTextLike: Bool {
        clip.contentType == .text || clip.contentType == .code
    }

    var body: some View {
        Group {
            Button(action: onCopy) {
                Label("복사", systemImage: "doc.on.doc")
            }

            // 텍스트 변환하여 붙여넣기 (텍스트/코드 전용)
            if isTextLike, let onPasteWithTransform = onPasteWithTransform {
                Menu {
                    ForEach(TextTransform.allCases) { transform in
                        Button {
                            onPasteWithTransform(transform)
                        } label: {
                            Label(transform.displayName, systemImage: transform.systemImage)
                        }
                    }
                } label: {
                    Label("변환하여 붙여넣기", systemImage: "wand.and.stars")
                }
            }

            // 유사 이미지 찾기 (이미지 전용)
            if clip.contentType == .image, let onFindSimilarImages = onFindSimilarImages {
                Button(action: onFindSimilarImages) {
                    Label("유사 이미지 찾기", systemImage: "rectangle.on.rectangle.angled")
                }
            }

            Divider()

            Button(action: onPin) {
                Label(clip.isPinned ? "핀 해제" : "핀 고정", systemImage: clip.isPinned ? "pin.slash" : "pin")
            }

            if clip.contentType != .image {
                Button(action: onEdit) {
                    Label("편집", systemImage: "pencil")
                }
            }

            Button(action: onShowTags) {
                Label("태그", systemImage: "tag")
            }

            Divider()

            Button(action: onAddToStack) {
                Label("스택에 추가", systemImage: "square.stack.3d.up")
            }

            Divider()

            Button(role: .destructive, action: onDelete) {
                Label("삭제", systemImage: "trash")
            }
        }
    }
}
