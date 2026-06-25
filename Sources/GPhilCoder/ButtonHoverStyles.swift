import AppKit
import SwiftUI

struct GPhilHoverBorderlessButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBorderlessButton(configuration: configuration)
    }
}

extension ButtonStyle where Self == GPhilHoverBorderlessButtonStyle {
    static var gphilHoverBorderless: GPhilHoverBorderlessButtonStyle {
        GPhilHoverBorderlessButtonStyle()
    }
}

private struct HoverBorderlessButton: View {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    let configuration: GPhilHoverBorderlessButtonStyle.Configuration

    var body: some View {
        configuration.label
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.arrow.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
    }

    private var backgroundColor: Color {
        guard isEnabled else { return .clear }
        if configuration.isPressed {
            return Color.accentColor.opacity(0.18)
        }
        if isHovering {
            return Color(nsColor: .quaternaryLabelColor).opacity(0.45)
        }
        return .clear
    }
}
