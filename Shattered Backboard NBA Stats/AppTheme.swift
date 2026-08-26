//
//  AppTheme.swift — Global dark night-sky theme.
//
//  Sport-agnostic. Safe to keep unchanged across all forks.
//

import SwiftUI

// MARK: - Colors

extension Color {
    static let skyDeep   = Color(red: 0.04, green: 0.06, blue: 0.18)   // very dark navy
    static let skyMid    = Color(red: 0.07, green: 0.13, blue: 0.30)   // mid navy
    static let skyAccent = Color(red: 0.15, green: 0.30, blue: 0.55)   // blue highlight
    static let skyBright = Color(red: 0.45, green: 0.75, blue: 1.00)   // bright interactive (tint)
    static let skyRow    = Color(red: 0.09, green: 0.14, blue: 0.26)   // list row fill
    static let skyCard   = Color(red: 0.10, green: 0.17, blue: 0.32).opacity(0.85)
    static let skyBorder = Color.white.opacity(0.12)
}

// MARK: - Double formatting

extension Double {
    /// "22.5" or "22" — strips trailing .0
    var cleanLine: String {
        truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(self))
            : String(format: "%.1f", self)
    }
}

// MARK: - Night Sky Background

struct NightSkyBackground: View {
    private struct Star: Identifiable {
        let id: Int
        let x: Double
        let y: Double
        let size: Double
        let opacity: Double
    }

    private let stars: [Star] = {
        var rng = SeededRandom(seed: 42)
        return (0..<130).map { i in
            Star(id: i,
                 x: rng.next(), y: rng.next(),
                 size: rng.next() * 2.2 + 0.5,
                 opacity: rng.next() * 0.55 + 0.25)
        }
    }()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .skyDeep, location: 0.0),
                        .init(color: .skyMid,  location: 0.55),
                        .init(color: .skyDeep, location: 1.0),
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                ForEach(stars) { star in
                    Circle()
                        .fill(Color.white.opacity(star.opacity))
                        .frame(width: star.size, height: star.size)
                        .position(x: star.x * geo.size.width,
                                  y: star.y * geo.size.height)
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Seeded RNG (simple LCG, not crypto-grade)

private struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}

// MARK: - View Modifier

struct NightSkyModifier: ViewModifier {
    func body(content: Content) -> some View {
        ZStack {
            NightSkyBackground()
            content
        }
    }
}

extension View {
    func nightSky() -> some View {
        modifier(NightSkyModifier())
    }
}

// MARK: - Haptic Feedback

#if canImport(UIKit)
import UIKit

func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
    UIImpactFeedbackGenerator(style: style).impactOccurred()
}
#endif

// MARK: - Date Formatting

extension String {
    /// Converts "YYYY-MM-DD…" to "M/d" (e.g. "2/22").
    var shortDate: String {
        let parts = prefix(10).split(separator: "-")
        guard parts.count == 3,
              let m = Int(parts[1]),
              let d = Int(parts[2]) else { return self }
        return "\(m)/\(d)"
    }
}

// MARK: - Stat colour palette

/// Maps NBA stat labels to their theme colours. Available from all views.
func nbaStatColor(_ stat: String) -> Color {
    switch stat {
    case "PTS": return .orange
    case "REB": return .green
    case "AST": return Color(red: 0.3, green: 0.6, blue: 1.0)
    case "PR":  return Color(red: 1.0, green: 0.55, blue: 0.2)
    case "PA":  return Color(red: 0.95, green: 0.75, blue: 0.2)
    case "RA":  return Color(red: 0.45, green: 0.85, blue: 0.55)
    case "3PM": return .purple
    case "PRA": return .yellow
    case "FPTS": return Color(red: 0.98, green: 0.45, blue: 0.20)
    case "FTM": return Color(red: 0.2, green: 0.8, blue: 0.6)
    case "STL": return Color(red: 1.0, green: 0.6, blue: 0.2)
    case "BLK": return Color(red: 0.6, green: 0.4, blue: 1.0)
    case "DD":  return Color(red: 1.0, green: 0.82, blue: 0.0)   // gold
    case "TD":  return Color(red: 1.0, green: 0.3,  blue: 0.55)  // rose
    default:    return .white.opacity(0.55)
    }
}
