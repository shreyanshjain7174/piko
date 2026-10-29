import PikoKit
import RealityKit
import SwiftUI
import UIKit

@MainActor
struct PikoPetView: UIViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let activity: PikoPetActivity
    private let loudness: Double
    private let isActive: Bool
    private let room: Color
    private let onPat: @MainActor () -> Void

    init(
        activity: PikoPetActivity, loudness: Double,
        isActive: Bool = true, room: Color = .clear,
        onPat: @escaping @MainActor () -> Void
    ) {
        self.activity = activity
        self.loudness = loudness
        self.isActive = isActive
        self.room = room
        self.onPat = onPat
    }

    func makeUIView(context: Context) -> PikoPetSurface {
        let view = PikoPetSurface(frame: .zero)
        update(view)
        return view
    }

    func updateUIView(_ uiView: PikoPetSurface, context: Context) {
        update(uiView)
    }

    static func dismantleUIView(_ uiView: PikoPetSurface, coordinator: ()) {
        uiView.shutdown()
    }

    private func update(_ view: PikoPetSurface) {
        view.configure(activity: activity, loudness: loudness, isActive: isActive,
                       room: UIColor(room), reduceMotion: reduceMotion, onPat: onPat)
    }
}

/// Owns the virtual view only while visible, foregrounded and explicitly active.
/// Removing the ARView also releases RealityKit's rendering work, not just our poses.
@MainActor
final class PikoPetSurface: UIView {
    private var renderView: ARView?
    private var rig: PikoPetRig?
    private var frameTask: Task<Void, Never>?
    private var patResetTask: Task<Void, Never>?
    private var onPat: (@MainActor () -> Void)?
    private var activity: PikoPetActivity = .idle
    private var loudness = 0.0
    private var requestedActive = false
    private var foreground = false
    private var reduceMotion = false
    private var disposed = false
    private var room = UIColor.clear
    private var activityStarted = ProcessInfo.processInfo.systemUptime
    private var patStarted: TimeInterval?
    private var touchX = 0.0
    private var touchY = 0.0
    private var isStroking = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        prepare()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        prepare()
    }

    private func prepare() {
        isOpaque = false
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = "Piko"
        accessibilityHint = "Double-tap to pat Piko. Drag to gently stroke."
        accessibilityTraits = .button
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let stroke = UIPanGestureRecognizer(target: self, action: #selector(stroked(_:)))
        stroke.maximumNumberOfTouches = 1
        stroke.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        addGestureRecognizer(stroke)
        NotificationCenter.default.addObserver(
            self, selector: #selector(resignedActive),
            name: UIApplication.willResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(becameActive),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    func configure(
        activity: PikoPetActivity, loudness: Double, isActive: Bool,
        room: UIColor, reduceMotion: Bool, onPat: @escaping @MainActor () -> Void
    ) {
        guard !disposed else { return }
        if self.activity != activity {
            activityStarted = ProcessInfo.processInfo.systemUptime
        }
        self.activity = activity
        self.loudness = loudness
        self.requestedActive = isActive
        self.room = room
        self.reduceMotion = reduceMotion
        self.onPat = onPat
        backgroundColor = room
        renderView?.environment.background = .color(room)
        switch activity {
        case .idle: accessibilityValue = "Quietly here"
        case .listening: accessibilityValue = "Listening"
        case .thinking: accessibilityValue = "Thinking"
        case .speaking: accessibilityValue = "Speaking"
        case .happy: accessibilityValue = "Happy"
        }
        reconcile()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        foreground = UIApplication.shared.applicationState == .active
        reconcile()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { stopRendering() }
        super.willMove(toWindow: newWindow)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renderView?.frame = bounds
        rig?.resize(bounds.size)
    }

    override func accessibilityActivate() -> Bool {
        guard shouldRender else { return false }
        pat()
        return true
    }

    private var shouldRender: Bool {
        requestedActive && foreground && window != nil && !disposed
    }

    private func reconcile() {
        guard shouldRender else {
            stopRendering()
            return
        }
        if renderView == nil {
            // Virtual rendering only: no camera access and no automatic AR session.
            let view = ARView(frame: bounds, cameraMode: .nonAR, automaticallyConfigureSession: false)
            view.isOpaque = false
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            view.environment.background = .color(room)
            // Contact shading is explicit geometry; skip automatic grounding
            // shadows, whose mesh-shadow pipeline can be unsupported in Simulator.
            view.renderOptions = [.disableGroundingShadows, .disableMotionBlur, .disableDepthOfField,
                                  .disableCameraGrain, .disableAREnvironmentLighting]
            let rig = PikoPetRig()
            view.scene.addAnchor(rig.anchor)
            rig.resize(bounds.size)
            addSubview(view)
            self.rig = rig
            renderView = view
        }
        _ = renderFrame()
        if reduceMotion {
            frameTask?.cancel()
            frameTask = nil
        } else if frameTask == nil {
            // Weak across each suspension; no display-link target or scene callback
            // retaining the surface, and no actor hop per frame.
            frameTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(33))
                    } catch {
                        return
                    }
                    guard self?.renderFrame() == true else { return }
                }
            }
        }
    }

    private func renderFrame() -> Bool {
        guard shouldRender, let rig else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if !isStroking && !reduceMotion {
            touchX *= 0.88
            touchY *= 0.88
        }
        rig.apply(PikoPetMotion.pose(
            activity: activity, loudness: loudness, elapsed: now - activityStarted,
            patElapsed: patStarted.map { now - $0 }, touchX: touchX, touchY: touchY,
            reduceMotion: reduceMotion
        ))
        return true
    }

    @objc private func tapped() {
        pat()
    }

    @objc private func stroked(_ gesture: UIPanGestureRecognizer) {
        guard shouldRender, bounds.width > 0, bounds.height > 0 else { return }
        switch gesture.state {
        case .began, .changed:
            isStroking = true
            let point = gesture.location(in: self)
            touchX = Double(point.x / bounds.width * 2 - 1)
            touchY = Double(point.y / bounds.height * 2 - 1)
            if gesture.state == .began { pat() }
        case .ended, .cancelled, .failed:
            isStroking = false
            if reduceMotion {
                touchX = 0
                touchY = 0
            }
        default: break
        }
        _ = renderFrame()
    }

    private func pat() {
        guard shouldRender else { return }
        patStarted = ProcessInfo.processInfo.systemUptime
        patResetTask?.cancel()
        patResetTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(1_400))
            } catch {
                return
            }
            self?.finishPat()
        }
        _ = renderFrame()
        onPat?()
    }

    private func finishPat() {
        patStarted = nil
        patResetTask = nil
        _ = renderFrame()
    }

    @objc private func resignedActive() {
        foreground = false
        stopRendering()
    }

    @objc private func becameActive() {
        foreground = true
        reconcile()
    }

    private func stopRendering() {
        frameTask?.cancel()
        frameTask = nil
        patResetTask?.cancel()
        patResetTask = nil
        patStarted = nil
        touchX = 0
        touchY = 0
        isStroking = false
        renderView?.scene.anchors.removeAll()
        renderView?.removeFromSuperview()
        renderView = nil
        rig = nil
    }

    func shutdown() {
        disposed = true
        requestedActive = false
        onPat = nil
        NotificationCenter.default.removeObserver(self)
        stopRendering()
    }

    deinit {
        frameTask?.cancel()
        patResetTask?.cancel()
    }
}
