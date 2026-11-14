import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Optara Labs palette: navy surfaces, subtle borders, one cyan accent. No glow or gradients.
enum Theme {
    static let bg = Color(hex: 0x111B27)
    static let panel = Color(hex: 0x1B2938)
    static let border = Color(hex: 0x2D4052)
    static let text = Color(hex: 0xE6EDF3)
    static let secondary = Color(hex: 0xA8B6C5)
    static let accent = Color(hex: 0x65B8CB)
    static let danger = Color(hex: 0xE5534B)
    static let radius: CGFloat = 8
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout.weight(.semibold)).foregroundStyle(Theme.bg)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.accent.opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4), in: RoundedRectangle(cornerRadius: Theme.radius))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout).foregroundStyle(Theme.text.opacity(enabled ? 1 : 0.4))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(configuration.isPressed ? Theme.border : Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
    }
}

struct DangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.danger.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: Theme.radius))
    }
}

extension View {
    func card() -> some View {
        padding(12).background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border))
    }
    /// Applies the app-wide dark navy look to a window's root view.
    func optaraWindow() -> some View {
        foregroundStyle(Theme.text).tint(Theme.accent).background(Theme.bg).preferredColorScheme(.dark)
    }
}

/// Small horizontal audio level meter.
struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                Capsule().fill(Theme.accent).frame(width: max(3, g.size.width * CGFloat(min(1, level))))
            }
        }
        .frame(width: 80, height: 5)
        .accessibilityElement().accessibilityLabel("Audio level").accessibilityValue("\(Int(min(1, level) * 100)) percent")
    }
}

struct OptaraLogo: View {
    var height: CGFloat = 26
    var body: some View {
        if let url = Bundle.main.url(forResource: "optara-logo", withExtension: "png"), let img = NSImage(contentsOf: url) {
            Image(nsImage: img).resizable().scaledToFit().frame(height: height).accessibilityLabel("Optara Labs")
        } else {
            Image(systemName: "sparkle").foregroundStyle(Theme.accent).accessibilityLabel("Optara Labs")
        }
    }
}

/// Date helpers for sidebar grouping and headers.
enum DateLabel {
    static func day(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().year())
    }
    static func range(_ s: MeetingSnapshot) -> String {
        s.start.formatted(date: .abbreviated, time: .shortened) + " – " + s.end.formatted(date: .omitted, time: .shortened)
    }
}
