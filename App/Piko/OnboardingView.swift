import SwiftUI
import UIKit

/// Apple gives no API to detect whether a custom keyboard is installed/enabled (privacy —
/// a host app enumerating keyboards would be a fingerprinting vector), and no deep link
/// straight to Settings > Keyboards (`openSettingsURLString` only opens *this app's* settings
/// page). So this is instructions plus a best-effort shortcut, not a verified checklist —
/// each step is self-reported by the user, not detected.
struct OnboardingView: View {
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    privacyNote

                    VStack(alignment: .leading, spacing: 20) {
                        step(1, "Start a session",
                             "On Home, tap Start session in the keyboard card. To dictate directly in Piko, tap Start dictating instead.")
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
            }
            .background(Color(.systemGroupedBackground))
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
            Image(systemName: "lock.iphone")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Everything stays on this phone")
                    .font(.subheadline.weight(.semibold))
                Text("Your voice and your text are never sent anywhere. Turn on airplane mode and Piko works exactly the same.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var settingsShortcut: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Label("Open Piko in Settings", systemImage: "gear")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Text("For keyboard access, go to Settings › General › Keyboard › Keyboards › Piko.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(title). \(detail)")
    }
}
