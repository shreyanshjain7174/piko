import SwiftUI
import UIKit
import PikoKit
import PikoUI

/// Apple gives no API to detect whether a custom keyboard is installed/enabled (privacy —
/// a host app enumerating keyboards would be a fingerprinting vector), and no deep link
/// straight to Settings > Keyboards (`openSettingsURLString` only opens *this app's* settings
/// page). So this is instructions plus a best-effort shortcut, not a verified checklist —
/// each step is self-reported by the user, not detected.
struct OnboardingView: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground(phase: .armed, tint: Skin.cute.controlTint)
                    .ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        intro
                        privacyNote

                        VStack(alignment: .leading, spacing: 14) {
                            step(1, "Start a session",
                                 "On Home, tap Start session in the keyboard card. To dictate directly in Piko, hold the orb instead.")
                            step(2, "Add the Piko keyboard",
                                 "In Settings, go to General › Keyboard › Keyboards › Add New Keyboard and pick Piko. Then tap Piko in that list and turn on Allow Full Access.")
                            step(3, "Switch to Piko in any text field",
                                 "Touch and hold the globe key on the keyboard, then choose Piko.")
                            step(4, "Speak",
                                 "Tap the mic button, say what you want, tap again to stop. The tidied text lands in the field you were already in.")
                        }

                        settingsShortcut
                    }
                    .padding(20)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Get Piko working")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                        .foregroundStyle(.white)
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            PikoFace(phase: .armed, skin: .cute)
                .frame(width: 88, height: 93)
            Text("Four small steps,\nthen talk anywhere.")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .tracking(-0.6)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.iphone")
                .font(.title3)
                .foregroundStyle(Skin.cute.controlTint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Everything stays on this phone")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Your voice and your text are never sent anywhere. Turn on airplane mode and Piko works exactly the same.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
    }

    private var settingsShortcut: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Piko in Settings", systemImage: "gear")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(Skin.cute.controlTint)
            .foregroundStyle(.black.opacity(0.85))

            Text("For keyboard access, go to Settings › General › Keyboard › Keyboards › Piko.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.top, 4)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.black.opacity(0.85))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Skin.cute.controlTint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.white)
                Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.6))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(title). \(detail)")
    }
}
