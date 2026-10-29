import SwiftUI
import PikoKit

@main
struct PikoApp: App {
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @State private var benchmarkStarted = false
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                #if DEBUG
                .overlay(alignment: .top) {
                    if UserDefaults.standard.string(forKey: "PikoBenchmarkFixtureManifest") != nil
                        || UserDefaults.standard.string(forKey: "PikoBenchmarkFixture") != nil {
                        Text("Developer file benchmark. No microphone. Keep Piko in the foreground.")
                            .font(.caption)
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding(.top, 48)
                    }
                }
                #endif
        }
            .onChange(of: scenePhase, initial: true) { _, newPhase in
                guard newPhase == .active else { return }
                if case .success(let app) = AppComposition.shared {
                    #if DEBUG
                    let defaults = UserDefaults.standard
                    if defaults.string(forKey: "PikoBenchmarkFixtureManifest") != nil
                        || defaults.string(forKey: "PikoBenchmarkFixture") != nil
                        || defaults.bool(forKey: "PikoBenchmarkPrepare") {
                        guard !benchmarkStarted else { return }
                        benchmarkStarted = true
                    }
                    if let eval = defaults.string(forKey: "PikoPlanEval") {
                        guard !benchmarkStarted else { return }
                        benchmarkStarted = true
                        Task { await PlanProbe.evaluate(eval, app: app) }
                        return
                    }
                    if let probe = defaults.string(forKey: "PikoPlanProbe") {
                        guard !benchmarkStarted else { return }
                        benchmarkStarted = true
                        Task { await PlanProbe.run(probe, app: app) }
                        return
                    }
                    if let manifest = defaults.string(forKey: "PikoBenchmarkFixtureManifest") {
                        Task {
                            do {
                                let report = try await app.runBenchmarkManifest(manifest)
                                FileHandle.standardOutput.write(Data("PIKO_FIXTURE_RESULT: \(report)\n".utf8))
                            } catch {
                                FileHandle.standardOutput.write(Data(
                                    "PIKO_FIXTURE_FAILED: \(type(of: error)).\(error)\n".utf8))
                            }
                        }
                        return
                    }
                    if let fixture = UserDefaults.standard.string(forKey: "PikoBenchmarkFixture") {
                        Task {
                            do {
                                let report = try await app.runBenchmarkFixture(fixture)
                                FileHandle.standardOutput.write(Data("PIKO_FIXTURE_RESULT: \(report)\n".utf8))
                            } catch {
                                FileHandle.standardOutput.write(Data(
                                    "PIKO_FIXTURE_FAILED: \(type(of: error)).\(error)\n".utf8))
                            }
                        }
                        return
                    }
                    if UserDefaults.standard.bool(forKey: "PikoBenchmarkPrepare") {
                        Task {
                            do {
                                let engine = try await app.prepareBenchmarkSpeech()
                                FileHandle.standardOutput.write(Data(
                                    "PIKO_BENCHMARK_READY: \(engine); microphone not opened\n".utf8))
                            } catch {
                                let failure = (error as? PikoError) ?? .transcriptionFailed
                                app.captureCoordinator.onFailure?(failure)
                                FileHandle.standardOutput.write(Data(
                                    "PIKO_BENCHMARK_FAILED: \(type(of: error)).\(error)\n".utf8))
                            }
                        }
                        return
                    }
                    #endif
                    Task { await app.handlePendingCaptureRequest() }
                }
            }
    }
}
