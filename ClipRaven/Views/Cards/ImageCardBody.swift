import SwiftUI

struct ImageCardBody: View {
    let thumbnail: Data?

    var body: some View {
        GeometryReader { geo in
            if let data = thumbnail, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .allowsHitTesting(false)
    }
}
