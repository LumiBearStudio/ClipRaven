import SwiftUI

enum DesignTokens {
    // MARK: - Spacing
    enum Spacing {
        static let xxxs: CGFloat = 2
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - Corner Radius
    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
    }

    // MARK: - Card Dimensions
    enum Card {
        static let width: CGFloat = 180
        static let height: CGFloat = 135
        static let headerHeight: CGFloat = 44
        static let spacing: CGFloat = 10
    }

    // MARK: - Panel
    enum Panel {
        static let width: CGFloat = 780
        static let height: CGFloat = 260
        static let previewWidth: CGFloat = 280
    }

    // MARK: - Font
    enum Font {
        static let cardTitle = SwiftUI.Font.system(size: 10)
        static let cardBody = SwiftUI.Font.system(size: 11)
        static let cardCode = SwiftUI.Font.system(size: 10, design: .monospaced)
        static let filterLabel = SwiftUI.Font.system(size: 11)
        static let hint = SwiftUI.Font.system(size: 10)
        static let badge = SwiftUI.Font.system(size: 9, weight: .medium)
    }

    // MARK: - Animation
    enum Animation {
        static let panelShow = SwiftUI.Animation.easeOut(duration: 0.15)
        static let panelHide = SwiftUI.Animation.easeIn(duration: 0.1)
        static let cardHover = SwiftUI.Animation.easeInOut(duration: 0.15)
        static let scrollTo  = SwiftUI.Animation.easeInOut(duration: 0.2)

        // Spring animations
        static let cardSpring    = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.82)
        static let cardStagger   = 0.04  // seconds between staggered cards
        static let previewSpring = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.85)
        static let multiBarSpring = SwiftUI.Animation.spring(response: 0.3, dampingFraction: 0.8)
        static let quickFade     = SwiftUI.Animation.easeInOut(duration: 0.15)
        static let deletionSpring = SwiftUI.Animation.spring(response: 0.35, dampingFraction: 0.85)
    }

    // MARK: - Shadow
    enum Shadow {
        static let cardRadius: CGFloat = 3
        static let cardY: CGFloat = 2
        static let cardOpacity: Double = 0.15
        static let panelRadius: CGFloat = 20
        static let panelOpacity: Double = 0.3
    }

    // MARK: - Colors
    enum Colors {
        static let cardBackground = Color(.windowBackgroundColor)
        static let separatorColor = Color(.separatorColor)

        static let typeText  = Color(red: 0.25, green: 0.52, blue: 0.95)
        static let typeCode  = Color(red: 0.35, green: 0.75, blue: 0.55)
        static let typeURL   = Color(red: 0.95, green: 0.45, blue: 0.25)
        static let typeImage = Color(red: 0.85, green: 0.35, blue: 0.65)
        static let typeColor = Color(red: 0.90, green: 0.65, blue: 0.15)
        static let typeFile  = Color(red: 0.55, green: 0.55, blue: 0.60)
    }
}
