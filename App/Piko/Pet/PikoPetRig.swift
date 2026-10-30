import PikoKit
import RealityKit
import UIKit

/// Original ellipsoid study, expressed as a native scene (one shared sphere mesh).
@MainActor
final class PikoPetRig {
    let anchor = AnchorEntity(world: .zero)
    private let root = Entity()
    private let head = Entity()
    private let leftEar = Entity()
    private let rightEar = Entity()
    private let camera = PerspectiveCamera()
    private let sphere = MeshResource.generateSphere(radius: 1)
    private var eyes: [ModelEntity] = []
    private var highlights: [ModelEntity] = []
    private var mouth: ModelEntity?

    init() {
        let cream = material(0.98, 0.93, 0.83)
        let warm = material(0.94, 0.86, 0.74)
        let pink = material(0.94, 0.66, 0.61)
        let ink = material(0.18, 0.15, 0.14, roughness: 0.16)
        let glint = material(1, 0.99, 0.95, roughness: 0.2)
        anchor.addChild(root)
        root.addChild(head)
        head.position = [0, 0.53, 0.03]

        ellipsoid(root, at: [0, -0.25, 0], size: [0.52, 0.62, 0.43], material: warm)
        ellipsoid(root, at: [0, -0.27, 0.35], size: [0.35, 0.40, 0.12], material: cream)
        ellipsoid(root, at: [0.44, -0.49, -0.3], size: [0.21, 0.21, 0.21], material: cream)
        for side: Float in [-1, 1] {
            ellipsoid(root, at: [side * 0.28, -0.77, 0.27],
                      size: [0.26, 0.15, 0.29], material: cream, angle: -side * 0.08)
            ellipsoid(root, at: [side * 0.48, -0.18, 0.06],
                      size: [0.16, 0.30, 0.16], material: cream, angle: side * 0.22)
            let ear = side < 0 ? leftEar : rightEar
            head.addChild(ear)
            ear.position = [side * 0.34, 0.47, -0.09]
            ellipsoid(ear, at: [0, 0.35, 0], size: [0.17, 0.50, 0.135], material: cream)
            ellipsoid(ear, at: [0, 0.37, 0.12], size: [0.084, 0.34, 0.026], material: pink)
        }
        ellipsoid(head, at: .zero, size: [0.65, 0.61, 0.54], material: cream)
        for side: Float in [-1, 1] {
            ellipsoid(head, at: [side * 0.39, -0.105, 0.434],
                      size: [0.12, 0.063, 0.034], material: pink)
            eyes.append(ellipsoid(head, at: [side * 0.235, 0.065, 0.505],
                                  size: [0.083, 0.116, 0.043], material: ink))
            highlights.append(ellipsoid(head, at: [side * 0.235 - 0.021, 0.103, 0.543],
                                        size: [0.023, 0.027, 0.014], material: glint))
            ellipsoid(head, at: [side * 0.026, -0.174, 0.52],
                      size: [0.037, 0.012, 0.017], material: ink, angle: side * 0.21)
        }
        ellipsoid(head, at: [0, -0.085, 0.548], size: [0.044, 0.031, 0.023],
                  material: material(0.43, 0.29, 0.26))
        mouth = ellipsoid(head, at: [0, -0.175, 0.538], size: [0.025, 0.009, 0.016], material: ink)

        // Translucent nested 3D ellipsoids feather the contact shadow without an
        // opaque floor, so the caller's room tint (including clear) stays intact.
        for index in 0..<4 {
            let inset = Float(index) * 0.10
            let shadow = SimpleMaterial(
                color: UIColor(red: 0.36, green: 0.35, blue: 0.29, alpha: 0.035),
                roughness: 1, isMetallic: false
            )
            ellipsoid(anchor, at: [0, -0.925 + Float(index) * 0.002, -0.03],
                      size: [0.84 - inset, 0.009, 0.46 - inset * 0.4], material: shadow)
        }

        camera.camera.fieldOfViewInDegrees = 36
        camera.look(at: [0, 0.45, 0], from: [0, 1, 5.3], relativeTo: nil)
        anchor.addChild(camera)
        let key = DirectionalLight()
        key.light = DirectionalLightComponent(
            color: UIColor(red: 1, green: 0.97, blue: 0.91, alpha: 1), intensity: 1_500
        )
        key.look(at: .zero, from: [-3, 5, 5], relativeTo: nil)
        anchor.addChild(key)
        let fill = DirectionalLight()
        fill.light = DirectionalLightComponent(
            color: UIColor(red: 0.92, green: 0.95, blue: 1, alpha: 1), intensity: 650
        )
        fill.look(at: .zero, from: [3, 1, 3], relativeTo: nil)
        anchor.addChild(fill)
    }

    func resize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let aspect = Float(size.width / size.height)
        let distance = 5.3 * max(1, 0.72 / max(aspect, 0.1))
        camera.look(at: [0, 0.45, 0], from: [0, 1, distance], relativeTo: nil)
    }

    func apply(_ pose: PikoPetPose) {
        root.position.y = Float(pose.elevation)
        root.scale = SIMD3(repeating: Float(pose.bodyScale))
        root.orientation = simd_quatf(angle: Float(pose.yaw), axis: [0, 1, 0])
        head.orientation = simd_quatf(angle: Float(pose.headTilt), axis: [0, 0, 1])
            * simd_quatf(angle: Float(pose.pitch), axis: [1, 0, 0])
        leftEar.orientation = simd_quatf(angle: Float(pose.leftEarAngle), axis: [0, 0, 1])
        rightEar.orientation = simd_quatf(angle: Float(pose.rightEarAngle), axis: [0, 0, 1])
        for (index, eye) in eyes.enumerated() {
            eye.scale.y = 0.116 * Float(pose.eyeOpenness)
            eye.position.x = (index == 0 ? -0.235 : 0.235) + Float(pose.yaw) * 0.08
            eye.position.y = 0.065 - Float(pose.pitch) * 0.12
            highlights[index].isEnabled = pose.eyeOpenness > 0.5
            highlights[index].position.x = eye.position.x - 0.021
            highlights[index].position.y = eye.position.y + 0.038
        }
        mouth?.scale.y = 0.009 + Float(pose.mouthOpenness) * 0.045
    }

    private func material(
        _ red: CGFloat, _ green: CGFloat, _ blue: CGFloat,
        roughness: MaterialScalarParameter = 0.9
    ) -> SimpleMaterial {
        SimpleMaterial(color: UIColor(red: red, green: green, blue: blue, alpha: 1),
                       roughness: roughness, isMetallic: false)
    }

    @discardableResult
    private func ellipsoid(
        _ parent: Entity, at position: SIMD3<Float>, size: SIMD3<Float>,
        material: SimpleMaterial, angle: Float = 0
    ) -> ModelEntity {
        let entity = ModelEntity(mesh: sphere, materials: [material])
        entity.position = position
        entity.scale = size
        entity.orientation = simd_quatf(angle: angle, axis: [0, 0, 1])
        parent.addChild(entity)
        return entity
    }
}
