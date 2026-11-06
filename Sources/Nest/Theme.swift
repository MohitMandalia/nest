import SwiftUI
import AppKit

enum Palette {
    static let canvas = Color(red: 0.98, green: 0.985, blue: 0.98)
    static let panel = Color.white
    static let sidebar = Color(red: 0.95, green: 0.965, blue: 0.95)
    static let ink = Color(red: 0.12, green: 0.19, blue: 0.16)
    static let muted = Color(red: 0.37, green: 0.42, blue: 0.39)
    static let green = Color(red: 0.20, green: 0.40, blue: 0.31)
    static let mint = green.opacity(0.08)
    static let line = ink.opacity(0.10)
    static let inset = green.opacity(0.035)
    static let warning = Color(red: 0.63, green: 0.32, blue: 0.09)
}

enum NestBrand {
    static let logo: NSImage = {
        guard let url = Bundle.module.url(forResource: "NestLogo", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("The bundled NestLogo.png could not be loaded")
        }
        image.isTemplate = false
        return image
    }()

    static let menuBarLogo: NSImage = {
        guard let image = logo.copy() as? NSImage else {
            preconditionFailure("The Nest menu bar logo could not be created")
        }
        image.size = NSSize(width: 20, height: 20)
        image.isTemplate = false
        return image
    }()
}

struct NestMark: View {
    var body: some View {
        Image(nsImage: NestBrand.logo)
            .renderingMode(.original)
            .resizable().interpolation(.high).scaledToFit()
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)
    }
}

struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View { content.padding(padding).frame(maxWidth: .infinity, alignment: .leading).nestPanel() }
}

struct NestActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(primary ? Palette.canvas : Palette.green)
            .background(primary ? Palette.green : Palette.green.opacity(hovering ? 0.13 : 0.07), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(primary ? Color.clear : Palette.green.opacity(0.14)))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .scaleEffect(enabled && configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
            .onHover { hovering = $0 }
    }
}

struct NestQuietStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.35)
            .brightness(enabled && hovering ? -0.03 : 0)
            .onHover { hovering = $0 }
    }
}

extension View {
    func nestPanel() -> some View {
        background(Palette.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
    }
    func nestAnimation<Value: Equatable>(_ value: Value) -> some View { modifier(NestMotion(value: value)) }
}
private struct NestMotion<Value: Equatable>: ViewModifier {
    var value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View { content.animation(reduceMotion ? nil : .smooth(duration: 0.22), value: value) }
}

struct CountBadge: View {
    var count: Int
    var body: some View {
        Text("\(count)").font(.system(size: 10, weight: .medium)).monospacedDigit()
            .foregroundStyle(Palette.green).padding(.horizontal, 7).padding(.vertical, 3)
            .background(Palette.mint, in: Capsule())
    }
}

struct EmptyState: View {
    var icon: String
    var title: String
    var detail = ""
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(Palette.green.opacity(0.08), lineWidth: 1).frame(width: 116, height: 116)
                Circle().fill(Palette.green.opacity(0.035)).frame(width: 84, height: 84)
                Image(systemName: icon).font(.system(size: 32, weight: .ultraLight)).foregroundStyle(Palette.green)
            }.accessibilityHidden(true)
            Text(title).font(.system(size: 18, weight: .medium))
            if !detail.isEmpty {
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth: 300)
            }
        }.frame(maxWidth: .infinity).padding(24)
    }
}
