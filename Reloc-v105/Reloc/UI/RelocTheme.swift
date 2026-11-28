import SwiftUI
import UIKit

/// Unified visual tokens, surface styles, and haptic helpers for Reloc.
enum RelocTheme {
    static let accent = Color(red: 0.17, green: 0.45, blue: 0.96)
    static let accentDeep = Color(red: 0.11, green: 0.32, blue: 0.84)
    static let emerald = Color(red: 0.09, green: 0.72, blue: 0.48)
    static let amber = Color(red: 0.95, green: 0.60, blue: 0.12)
    static let crimson = Color(red: 0.90, green: 0.25, blue: 0.27)

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accentDeep],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var emeraldGradient: LinearGradient {
        LinearGradient(
            colors: [emerald, Color(red: 0.05, green: 0.56, blue: 0.40)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var crimsonGradient: LinearGradient {
        LinearGradient(
            colors: [crimson, Color(red: 0.76, green: 0.16, blue: 0.20)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static func hapticLight() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func hapticMedium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func hapticSuccess() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// Elevated glass surface for floating map cards and controls.
struct RelocGlassCard: ViewModifier {
    var cornerRadius: CGFloat = 24
    var padding: CGFloat = 15

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.32), Color.white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            )
            .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    }
}

extension View {
    func relocGlassCard(cornerRadius: CGFloat = 24, padding: CGFloat = 15) -> some View {
        modifier(RelocGlassCard(cornerRadius: cornerRadius, padding: padding))
    }

    @ViewBuilder
    func relocOnChange<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(iOS 17.0, *) {
            self.onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            self.onChange(of: value, perform: action)
        }
    }
}

/// Compact pill-shaped floating icon button for the map HUD.
struct MapHUDIconButton: View {
    let systemName: String
    var isActive: Bool = false
    var activeColor: Color = RelocTheme.accent
    let action: () -> Void

    var body: some View {
        Button {
            RelocTheme.hapticLight()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isActive ? .white : .primary)
                .frame(width: 42, height: 42)
                .background(
                    Group {
                        if isActive {
                            Circle().fill(activeColor)
                        } else {
                            Circle().fill(.regularMaterial)
                        }
                    }
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(isActive ? 0.25 : 0.22), lineWidth: 0.7)
                )
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        }
    }
}

/// Primary gradient capsule CTA button used on floating map sheets.
struct RelocPrimaryButton: View {
    let title: String
    let systemImage: String
    var gradient: LinearGradient = RelocTheme.accentGradient
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            RelocTheme.hapticMedium()
            action()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.bold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(disabled ? LinearGradient(colors: [.gray.opacity(0.45), .gray.opacity(0.45)], startPoint: .top, endPoint: .bottom) : gradient)
            )
            .shadow(color: disabled ? .clear : .black.opacity(0.15), radius: 6, y: 3)
        }
        .disabled(disabled)
    }
}

/// Settings-style rounded colored icon badge.
struct SettingsIconBadge: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// Subtle animated pulsing dot for live NMEA states.
struct PulsingStatusDot: View {
    let color: Color
    let isPulsing: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            if isPulsing {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: 15, height: 15)
                    .scaleEffect(pulse ? 1.35 : 0.75)
                    .opacity(pulse ? 0.0 : 0.85)
                    .animation(.easeOut(duration: 1.25).repeatForever(autoreverses: false), value: pulse)
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .frame(width: 16, height: 16)
        .onAppear {
            if isPulsing { pulse = true }
        }
        .relocOnChange(of: isPulsing) { active in
            pulse = active
        }
    }
}
