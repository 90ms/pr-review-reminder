import SwiftUI

struct SeverityDot: View {
    let severity: Severity
    var body: some View {
        let color: Color = severity == .high ? .red : (severity == .medium ? .orange : .secondary)
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

extension PullRequest {
    var changeStat: String { "+\(additions) −\(deletions)" }
}

/// Reports the measured height of a view so a container can size to its content.
struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension View {
    /// Publishes this view's height via `HeightPreferenceKey`.
    func measureHeight() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: HeightPreferenceKey.self, value: proxy.size.height)
        })
    }
}
