// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The animated opening immediately after iOS's static launch screen. It is
/// deliberately short: the dashboard is already being built behind it, a tap
/// ends it at once, and Reduce Motion turns it into a calm fade.
struct AuroraSplashView: View {
    let onFinish: () -> Void

    @Environment(\.auroraReduceMotion) private var reduceMotion

    /// 0 black, 1 aurora, 2 mark, 3 particles and wordmark, 4 settled.
    @State private var phase = 0
    @State private var glow = false
    @State private var exiting = false
    @State private var didFinish = false

    var body: some View {
        ZStack {
            AuroraBackground(intensity: 1.35)
                .environment(\.colorScheme, .dark)

            // A vignette keeps the centre luminous and the edges midnight.
            RadialGradient(colors: [.clear, Color.black.opacity(0.48)],
                           center: .center, startRadius: 80, endRadius: 560)
                .ignoresSafeArea()

            AuroraParticles(isVisible: phase >= 3)
                .opacity(phase >= 3 ? 1 : 0)
                .animation(.easeOut(duration: 0.7), value: phase)

            VStack(spacing: 0) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [AuroraPalette.cyan.opacity(0.28), .clear],
                                             center: .center, startRadius: 4, endRadius: 160))
                        .frame(width: 300, height: 300)
                        .scaleEffect(glow ? 1.10 : 0.92)
                        .opacity(phase >= 2 ? 1 : 0)
                        .animation(reduceMotion ? nil
                                   : .easeInOut(duration: 2.6).repeatForever(autoreverses: true),
                                   value: glow)

                    CrateMark(size: 124, glowing: true)
                        .scaleEffect(phase >= 2 ? 1 : 0.72)
                        .opacity(phase >= 2 ? 1 : 0)
                        .rotationEffect(.degrees(phase >= 2 ? 0 : -7))
                        .animation(reduceMotion ? .easeOut(duration: 0.2)
                                   : .spring(duration: 0.85, bounce: 0.22),
                                   value: phase)
                }
                .frame(height: 250)

                VStack(spacing: 12) {
                    Text(verbatim: "crate")
                        .font(reduceMotion ? Font.system(size: 54, weight: .bold, design: .rounded)
                              : AuroraType.splashWordmark)
                        .tracking(1.5)
                        .foregroundStyle(AuroraPalette.wordmarkGradient)
                    Text(l10n: "splash.tagline")
                        .font(AuroraType.body)
                        .foregroundStyle(Color.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Text(verbatim: "AURORA EDITION")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(3.2)
                        .foregroundStyle(AuroraPalette.cyan.opacity(0.70))
                        .padding(.top, 2)
                }
                .opacity(phase >= 3 ? 1 : 0)
                .offset(y: phase >= 3 ? 0 : 10)
                .animation(reduceMotion ? .easeOut(duration: 0.2) : .easeOut(duration: 0.65), value: phase)

                Spacer()

                Text(l10n: "splash.continue")
                    .font(AuroraType.footnote)
                    .foregroundStyle(Color.white.opacity(0.46))
                    .padding(.bottom, 34)
                    .opacity(phase >= 4 ? 1 : 0)
                    .animation(.easeIn(duration: 0.3), value: phase)
            }
        }
        .scaleEffect(exiting ? 1.02 : 1)
        .opacity(exiting ? 0 : 1)
        .blur(radius: exiting && !reduceMotion ? 8 : 0)
        .animation(reduceMotion ? .linear(duration: 0.16) : .easeInOut(duration: 0.38), value: exiting)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(l10n: "splash.a11y"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { finish() }
        .onAppear { glow = true }
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            phase = 4
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            finish()
            return
        }
        withAnimation(.easeOut(duration: 0.7)) { phase = 1 }
        try? await Task.sleep(for: .milliseconds(140))
        guard !Task.isCancelled else { return }
        withAnimation(.spring(duration: 0.85, bounce: 0.22)) { phase = 2 }
        try? await Task.sleep(for: .milliseconds(360))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.55)) { phase = 3 }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.4)) { phase = 4 }
        try? await Task.sleep(for: .milliseconds(520))
        guard !Task.isCancelled else { return }
        finish()
    }

    private func finish() {
        guard !exiting else { return }
        exiting = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 160 : 360))
            guard !didFinish else { return }
            didFinish = true
            onFinish()
        }
    }
}
