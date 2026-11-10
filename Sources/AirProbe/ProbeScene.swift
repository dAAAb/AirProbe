import AppKit
import SceneKit
import AirPoiseCore

/// Real size of the 活萃力 effervescent-tablet tube (measured; matches the Object Capture scan).
enum TubeSpec {
    static let height: CGFloat = 0.1425      // m
    static let diameter: CGFloat = 0.0330    // m
    static let capHeight: CGFloat = 0.021
    static var radius: CGFloat { diameter / 2 }
}

enum TubeModelKind: String, CaseIterable, Identifiable {
    case scan, simple
    var id: String { rawValue }
    var label: String { self == .scan ? "掃描模型" : "簡易模型" }
}

final class ProbeScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    /// Rotated by the live orientation. Pivot = tube center.
    private let orient = SCNNode()
    private var scanNode: SCNNode?
    private let simpleNode: SCNNode
    private let ghost: SCNNode
    private(set) var scanLoaded = false

    init() {
        simpleNode = Self.makeSimpleTube()
        ghost = Self.makeGhost()
        build()
        if let url = Bundle.main.url(forResource: "huocuili", withExtension: "usdz") {
            scanNode = Self.loadScan(url)
            scanLoaded = scanNode != nil
            if let scanNode { content?.addChildNode(scanNode) }
        }
        setKind(scanLoaded ? .scan : .simple)
    }

    func setKind(_ kind: TubeModelKind) {
        let useScan = kind == .scan && scanNode != nil
        scanNode?.isHidden = !useScan
        simpleNode.isHidden = useScan
    }

    func apply(_ q: Quat) {
        orient.simdOrientation = simd_quatf(ix: Float(q.x), iy: Float(q.y), iz: Float(q.z), r: Float(q.w))
    }

    func setGhostVisible(_ on: Bool) { ghost.isHidden = !on }

    // MARK: - Build

    private func build() {
        scene.background.contents = Self.backdrop

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1100
        key.eulerAngles = SCNVector3(-0.9, 0.6, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .omni
        fill.light?.intensity = 500
        fill.position = SCNVector3(-0.4, 0.1, 0.3)
        scene.rootNode.addChildNode(fill)

        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 34
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = 10
        cameraNode.position = SCNVector3(0.17, 0.11, 0.30)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        // Floor ring at the upright tube's base — fixed reference.
        let ring = SCNTube(innerRadius: 0.058, outerRadius: 0.060, height: 0.0008)
        ring.firstMaterial = Self.flat(NSColor(srgbRed: 0.62, green: 0.63, blue: 0.66, alpha: 1), alpha: 0.7)
        let ringNode = SCNNode(geometry: ring)
        ringNode.position = SCNVector3(0, -TubeSpec.height / 2, 0)
        scene.rootNode.addChildNode(ringNode)
        let disc = SCNCylinder(radius: 0.058, height: 0.0004)
        disc.firstMaterial = Self.flat(NSColor(srgbRed: 0.6, green: 0.62, blue: 0.66, alpha: 1), alpha: 0.12)
        let discNode = SCNNode(geometry: disc)
        discNode.position = ringNode.position
        scene.rootNode.addChildNode(discNode)

        scene.rootNode.addChildNode(ghost)
        scene.rootNode.addChildNode(orient)
        let content = SCNNode()
        content.position = SCNVector3(0, -TubeSpec.height / 2, 0)   // models have origin at the base
        orient.addChildNode(content)
        content.addChildNode(simpleNode)
        self.content = content
    }

    private var content: SCNNode?

    private static func loadScan(_ url: URL) -> SCNNode? {
        guard let s = try? SCNScene(url: url, options: [.convertToYUp: true]) else { return nil }
        let holder = SCNNode()
        for child in s.rootNode.childNodes { holder.addChildNode(child) }
        // Normalize to the measured height regardless of the file's units.
        let (minV, maxV) = holder.boundingBox
        let h = CGFloat(maxV.y - minV.y)
        guard h > 1e-6 else { return nil }
        let k = TubeSpec.height / h
        holder.scale = SCNVector3(k, k, k)
        let cx = CGFloat(minV.x + maxV.x) / 2, cz = CGFloat(minV.z + maxV.z) / 2
        holder.position = SCNVector3(-cx * k, -CGFloat(minV.y) * k, -cz * k)
        holder.enumerateHierarchy { node, _ in
            node.geometry?.materials.forEach { $0.isDoubleSided = true }
        }
        return holder
    }

    private static func makeGhost() -> SCNNode {
        let g = SCNCylinder(radius: TubeSpec.radius * 1.04, height: TubeSpec.height)
        let green = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        let m = flat(green, alpha: 0.10)
        m.writesToDepthBuffer = false
        let none = flat(green, alpha: 0)
        none.writesToDepthBuffer = false
        g.materials = [m, none, none]
        let n = SCNNode(geometry: g)
        let edges = SCNTube(innerRadius: TubeSpec.radius * 1.03, outerRadius: TubeSpec.radius * 1.06, height: 0.0008)
        edges.firstMaterial = flat(green, alpha: 0.7)
        for y in [-TubeSpec.height / 2, TubeSpec.height / 2] {
            let e = SCNNode(geometry: edges)
            e.position = SCNVector3(0, y, 0)
            n.addChildNode(e)
        }
        return n
    }

    /// Parametric stand-in from the measured size: white body, yellow lemon band, white cap.
    private static func makeSimpleTube() -> SCNNode {
        let root = SCNNode()
        let bodyH = TubeSpec.height - TubeSpec.capHeight
        let body = SCNCylinder(radius: TubeSpec.radius, height: bodyH)
        body.radialSegmentCount = 64
        let side = SCNMaterial()
        side.diffuse.contents = labelTexture()
        side.lightingModel = .blinn
        let bottom = SCNMaterial()
        bottom.diffuse.contents = NSColor(white: 0.93, alpha: 1)
        body.materials = [side, bottom, bottom]
        let bodyNode = SCNNode(geometry: body)
        bodyNode.position = SCNVector3(0, bodyH / 2, 0)
        root.addChildNode(bodyNode)

        let cap = SCNCylinder(radius: TubeSpec.radius * 1.04, height: TubeSpec.capHeight)
        cap.radialSegmentCount = 64
        let capM = SCNMaterial()
        capM.diffuse.contents = NSColor(white: 0.97, alpha: 1)
        capM.lightingModel = .blinn
        cap.materials = [capM]
        let capNode = SCNNode(geometry: cap)
        capNode.position = SCNVector3(0, bodyH + TubeSpec.capHeight / 2, 0)
        root.addChildNode(capNode)

        let ribs = SCNTube(innerRadius: TubeSpec.radius * 1.0, outerRadius: TubeSpec.radius * 1.045, height: 0.002)
        ribs.firstMaterial = flat(NSColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1))
        let ribNode = SCNNode(geometry: ribs)
        ribNode.position = SCNVector3(0, bodyH + 0.001, 0)
        root.addChildNode(ribNode)
        return root
    }

    private static func labelTexture() -> NSImage {
        let size = NSSize(width: 1024, height: 512)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor(white: 0.97, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        // Image y=0 (bottom) maps to the bottom of the cylinder side.
        let yellow = NSColor(srgbRed: 0.98, green: 0.78, blue: 0.10, alpha: 1)
        let orange = NSColor(srgbRed: 0.96, green: 0.52, blue: 0.08, alpha: 1)
        yellow.setFill()
        NSRect(x: 0, y: 0, width: 1024, height: 150).fill()
        NSColor(srgbRed: 1, green: 0.93, blue: 0.45, alpha: 1).setFill()
        for i in 0..<8 {
            NSBezierPath(ovalIn: NSRect(x: Double(i) * 128 + 30, y: 40 + Double(i % 2) * 40, width: 56, height: 56)).fill()
        }
        orange.setFill()
        NSRect(x: 0, y: 440, width: 1024, height: 16).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 64),
            .foregroundColor: orange
        ]
        for x in [300.0, 812.0] {
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.saveGState()
            ctx.translateBy(x: x - 32, y: 420)
            ctx.rotate(by: -.pi / 2)
            ("活萃力" as NSString).draw(at: .zero, withAttributes: attrs)
            ctx.restoreGState()
        }
        img.unlockFocus()
        return img
    }

    /// Charcoal backdrop: the tube is mostly white, so it reads best on dark in both appearances.
    static let backdrop = NSColor(srgbRed: 0.15, green: 0.16, blue: 0.18, alpha: 1)

    private static func flat(_ c: NSColor, alpha: CGFloat = 1) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = c
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.transparency = alpha
        m.blendMode = .alpha
        return m
    }

    /// Offscreen render for self-checks (`AirProbe --snapshot out.png`).
    func snapshot(size: CGSize) -> NSImage {
        let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        r.scene = scene
        r.pointOfView = cameraNode
        return r.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }
}
