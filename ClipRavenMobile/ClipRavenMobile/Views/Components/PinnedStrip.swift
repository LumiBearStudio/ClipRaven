import SwiftUI
import ClipRavenSync

/// 상단 가로 스크롤 핀 스트립.
/// 그리드와 동일한 ClipCard 컴포넌트를 사용해 디자인 언어를 통일.
///
/// 카드 너비는 **일반 그리드 카드와 동일** — 고정 130pt 였던 이전 구현은
/// 일반 카드 (~178pt iPhone, ~200pt+ iPad) 보다 작아 위/아래 같은 콘텐츠가
/// 다른 크기로 보이는 일관성 회귀를 일으켰다. 현재는 GeometryReader +
/// preference key 로 컨테이너 너비를 측정해 `LazyVGrid` 와 동일한 공식
/// `(width − padding*2 − spacing*(count−1)) / count` 로 동적 산출.
struct PinnedStrip: View {

    let clips: [Clip]
    /// 일반 그리드의 컬럼 수. iPhone 2, iPad 4~5. 카드 너비를 그리드와
    /// 동일하게 맞추기 위해 호출자가 전달.
    let columnCount: Int
    let onCopy: (Clip) -> Void
    let onPreview: (Clip) -> Void
    let onTogglePin: (Clip) -> Void
    let onDelete: (Clip) -> Void

    /// 일반 그리드와 동일한 padding/spacing 값. ClipListView 의 LazyVGrid
    /// 설정과 1:1 매핑되므로 변경 시 양쪽 동기화 필요.
    private let horizontalPadding: CGFloat = 12
    private let itemSpacing: CGFloat = 10

    /// `.background(GeometryReader)` 로 측정된 컨테이너 너비.
    /// 0 인 동안 (첫 layout pass) fallback 너비 사용.
    @State private var containerWidth: CGFloat = 0

    private var cardWidth: CGFloat {
        guard containerWidth > 0, columnCount > 0 else { return 170 }
        let count = CGFloat(columnCount)
        let usable = containerWidth - horizontalPadding * 2 - itemSpacing * (count - 1)
        return max(usable / count, 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .rotationEffect(.degrees(45))
                Text("핀 고정")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text("\(clips.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: itemSpacing) {
                    ForEach(clips) { clip in
                        Button { onCopy(clip) } label: {
                            ClipCard(clip: clip)
                                .frame(width: cardWidth)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { onPreview(clip) } label: {
                                Label("미리보기", systemImage: "eye")
                            }

                            Button { onCopy(clip) } label: {
                                Label("클립보드에 복사", systemImage: "doc.on.doc")
                            }
                            .disabled(clip.contentText == nil)

                            Button {
                                onTogglePin(clip)
                            } label: {
                                Label("핀 해제", systemImage: "pin.slash")
                            }

                            Divider()

                            Button(role: .destructive) {
                                onDelete(clip)
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 8)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: PinnedStripWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(PinnedStripWidthKey.self) { newWidth in
            containerWidth = newWidth
        }
    }
}

/// Preference key 로 컨테이너 너비를 상위 → 동일 view 안에서 전달.
/// `.background(GeometryReader { ... preference ... })` 는 GeometryReader 가
/// 자체 frame 을 차지하지 않으면서 측정값만 흘리는 SwiftUI 표준 패턴.
private struct PinnedStripWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#Preview {
    PinnedStrip(
        clips: [
            Clip(contentType: .text, contentText: "회의 노트 — 4분기 OKR 정리", nickname: "OKR", isPinned: true, uuid: "1"),
            Clip(contentType: .url, contentText: "https://example.com/very-long-url", nickname: "Reference", isPinned: true, uuid: "2"),
            Clip(contentType: .code, contentText: "func calculate() -> Int { return 42 }", isPinned: true, uuid: "3"),
        ],
        columnCount: 2,
        onCopy: { _ in },
        onPreview: { _ in },
        onTogglePin: { _ in },
        onDelete: { _ in }
    )
    .background(Color(.systemGroupedBackground))
}
