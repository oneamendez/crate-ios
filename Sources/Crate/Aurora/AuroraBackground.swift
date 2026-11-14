// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The room the app sits in: midnight, with three slow aurora lights. Drawn in
/// Canvas at a deliberately low frame rate, so the atmosphere costs little
/// battery; with Reduce Motion it is a still image.
struct AuroraBackground: View {
    var intensity: Double = 1
    var showsGrain = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.auroraReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size,
                     time: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .background(base)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var base: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color(hex: 0x04060C), Color(hex: 0x080D19), Color(hex: 0x050710)]
                : [Color(hex: 0xF7FAFE), Color(hex: 0xEDF3FB), Color(hex: 0xF5F1FC)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let dark = colorScheme == .dark
        let strength = (dark ? 0.30 : 0.16) * intensity
        let slow = time / 38

        wave(in: &context, size: size, centerX: 0.18 + 0.06 * sin(slow),
             centerY: 0.16 + 0.04 * cos(slow * 0.8),
             radius: max(size.width, size.height) * 0.52,
             angle: -0.55 + 0.12 * sin(slow * 0.6),
             color: AuroraPalette.emerald.opacity(strength * 0.78))
        wave(in: &context, size: size, centerX: 0.82 + 0.05 * cos(slow * 0.7),
             centerY: 0.38 + 0.07 * sin(slow * 0.9),
             radius: max(size.width, size.height) * 0.58,
             angle: -0.40 + 0.10 * cos(slow * 0.5),
             color: AuroraPalette.violet.opacity(strength * 0.82))
        wave(in: &context, size: size, centerX: 0.48 + 0.08 * sin(slow * 0.55),
             centerY: 0.82 + 0.03 * cos(slow * 0.75),
             radius: max(size.width, size.height) * 0.48,
             angle: -0.30 + 0.08 * sin(slow * 0.4),
             color: AuroraPalette.blue.opacity(strength * 0.62))

        if showsGrain {
            // A very quiet star field keeps the large gradients from looking flat.
            let stars = dark ? 34 : 22
            for index in 0..<stars {
                let x = CGFloat(fraction(index * 0.618_033_988_75 + 0.12)) * size.width
                let y = CGFloat(fraction(index * 0.414_213_562_37 + 0.31)) * size.height
                let shimmer = 0.5 + 0.5 * sin(time / 5 + Double(index))
                let alpha = (dark ? 0.10 : 0.06) * (0.35 + 0.65 * shimmer) * intensity
                let dot = CGRect(x: x, y: y, width: 1.4, height: 1.4)
                context.fill(Path(ellipseIn: dot), with: .color(.white.opacity(alpha)))
            }
        }
    }

    private func wave(in context: inout GraphicsContext, size: CGSize, centerX: Double, centerY: Double,
                      radius: CGFloat, angle: Double, color: Color) {
        let center = CGPoint(x: size.width * CGFloat(centerX),
                             y: size.height * CGFloat(centerY))
        context.drawLayer { layer in
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .radians(angle))
            let rect = CGRect(x: -radius, y: -radius * 0.34, width: radius * 2, height: radius * 0.68)
            layer.fill(Path(ellipseIn: rect),
                       with: .radialGradient(Gradient(colors: [color, color.opacity(0.35), .clear]),
                                             center: .zero,
                                             startRadius: 0,
                                             endRadius: radius))
        }
    }

    private func fraction(_ value: Double) -> Double {
        value - floor(value)
    }
}

/// The opening screen's particle layer. Small, deterministic, and short-lived;
/// it never appears when Reduce Motion is on.
struct AuroraParticles: View {
    var isVisible: Bool

    private struct Particle {
        let x: Double
        let y: Double
        let size: Double
        let speed: Double
        let drift: Double
        let phase: Double
        let color: Color
    }

    @Environment(\.colorScheme) private var colorScheme

    private static let particles: [Particle] = {
        var made: [Particle] = []
        var state: UInt64 = 0xA0A1_5EED
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) & 0x7FFF) / 32767
        }
        let colors = [AuroraPalette.cyan, AuroraPalette.violet, Color.white, AuroraPalette.emerald]
        for index in 0..<44 {
            made.append(Particle(x: next(), y: next(), size: 0.7 + next() * 2.1,
                                 speed: 0.008 + next() * 0.022, drift: 0.006 + next() * 0.020,
                                 phase: next() * 6.28,
                                 color: colors[index % colors.count]))
        }
        return made
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isVisible)) { timeline in
            Canvas { context, size in
                guard isVisible else { return }
                let time = timeline.date.timeIntervalSinceReferenceDate
                for particle in Self.particles {
                    let travel = (particle.y - time * particle.speed * 0.12)
                    let y = CGFloat(travel - floor(travel)) * size.height
                    let x = CGFloat(particle.x) * size.width
                        + CGFloat(sin(time * particle.drift + particle.phase) * 14)
                    let twinkle = 0.30 + 0.55 * (0.5 + 0.5 * sin(time * 0.9 + particle.phase))
                    let rect = CGRect(x: x, y: y, width: particle.size, height: particle.size)
                    context.fill(Path(ellipseIn: rect),
                                 with: .color(particle.color.opacity(twinkle * (colorScheme == .dark ? 0.75 : 0.55))))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
