import SwiftUI
import ClipRavenSync

/// Vertical section divider label shown between card groups in the horizontal scroll.
struct SectionDividerView: View {
    let title: String
    let icon: String?

    init(title: String, icon: String? = nil) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top line
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            // Gap above label
            Spacer().frame(height: 18)

            // Rotated label (line breaks around it)
            HStack(spacing: 4) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary.opacity(0.6))
                    .tracking(1.5)
            }
            .rotationEffect(.degrees(-90))
            .fixedSize()

            // Gap below label
            Spacer().frame(height: 18)

            // Bottom line
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 24)
        .padding(.vertical, 4)
    }
}

// MARK: - Section Detection

enum ClipSection: Equatable {
    case pinned
    case today
    case yesterday
    case date(String)  // "M/d" formatted

    var title: String {
        switch self {
        case .pinned:    return "PIN"
        case .today:     return "TODAY"
        case .yesterday: return "YESTERDAY"
        case .date(let d): return d
        }
    }

    var icon: String? {
        switch self {
        case .pinned:    return "pin.fill"
        case .today:     return nil
        case .yesterday: return nil
        case .date:      return nil
        }
    }
}

extension Clip {
    private static let sectionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()

    /// Determines which section this clip belongs to.
    var section: ClipSection {
        if isPinned { return .pinned }

        let calendar = Calendar.current
        if calendar.isDateInToday(lastCopiedAt) { return .today }
        if calendar.isDateInYesterday(lastCopiedAt) { return .yesterday }

        return .date(Self.sectionDateFormatter.string(from: lastCopiedAt))
    }
}
