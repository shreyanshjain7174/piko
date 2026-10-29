import SwiftUI
import UIKit
import PikoUI

/// Apple gives no API to detect whether a custom keyboard is installed/enabled (privacy —
/// a host app enumerating keyboards would be a fingerprinting vector), and no deep link
/// straight to Settings > Keyboards (`openSettingsURLString` only opens *this app's* settings
/// page). So this is instructions plus a best-effort shortcut, not a verified checklist —
/// each step is self-reported by the user, not detected.
struct OnboardingView: View {
    @Binding var isPresented: Bool
    @Environment(\.pikoTheme) private var theme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .center, spacing: 14) {
                        PikoFace(phase: .armed, skin: theme.skin)
                            .frame(width: 64, height: 68)
                        Text("Four steps and I’m in every app.")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    privacyNote

                    VStack(alignment: .leading, spacing: 20) {
                        step(1, "Start a session",
                             "Add Arm Piko to Control Center or the Action Button. One press gets the keyboard mic ready. To dictate directly in Piko, tap Start dictating instead.")
                        step(2, "Add the Piko keyboard",
                             "In Settings, go to General › Keyboard › Keyboards › Add New Keyboard and pick Piko. Then tap Piko in that list and turn on Allow Full Access.")
                        step(3, "Switch to Piko in your text field",
                             "Touch and hold the globe key, then choose Piko. Secure fields and apps that block custom keyboards use Apple's keyboard instead.")
                        step(4, "Speak directly into the field",
                             "Tap Piko's large microphone, speak, then tap Stop. Text lands where you were typing, without opening Siri or another composer. Apple's separate dictation button still belongs to iOS.")
                    }

                    settingsShortcut
                }
                .padding(20)
            }
            .background(theme.ground)
            .toolbarBackground(theme.ground, for: .navigationBar)
            .navigationTitle("Get Piko working")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.title3)
                .foregroundStyle(theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Dictation stays on this phone")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.ink)
                Text("Piko processes your voice locally. Language or model setup may need an initial download; after setup, dictation works offline. Copying or sharing text is your choice.")
                    .font(.subheadline)
                    .foregroundStyle(theme.ink2)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var settingsShortcut: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Piko in Settings", systemImage: "gear")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.piko)

            Text("For keyboard access, go to Settings › General › Keyboard › Keyboards › Piko.")
                .font(.footnote)
                .foregroundStyle(theme.ink2)
        }
        .padding(.top, 4)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(theme.onPiko)
                .frame(width: 32, height: 32)
                .background(Circle().fill(theme.piko))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(theme.ink)
                Text(detail).font(.subheadline).foregroundStyle(theme.ink2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(title). \(detail)")
    }
}
