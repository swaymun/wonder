import ModelIO
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import UIKit

/// The selected model owns its parsed scene across inline and full-screen
/// presentations. The browser closes this session when the file or pairing
/// changes; a standalone preview owns and closes its own session.
@MainActor final class WorkspaceModelPreviewSession: ObservableObject {
    @Published fileprivate var prepared: PreparedModel?
    @Published private(set) var failure: String?
    private var revision: String?
    private var name: String?
    private var generation = UUID()
    private var preparation: Task<Void, Never>?

    func open(name: String, data: Data, revision: String) {
        guard self.revision != revision || self.name != name else { return }
        close()
        self.revision = revision
        self.name = name
        let request = generation
        preparation = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try PreparedModel.open(name: name, data: data)
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard let self, !Task.isCancelled, self.generation == request else {
                    result.removeTemporaryFile()
                    return
                }
                self.prepared = result
                self.preparation = nil
            } catch is CancellationError {
                // PreparedModel.open removes its temporary directory on error.
            } catch {
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.failure = (error as? LocalizedError)?.errorDescription ?? "This model could not be opened."
                self.preparation = nil
            }
        }
    }

    func close() {
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        prepared?.removeTemporaryFile()
        prepared = nil
        failure = nil
        revision = nil
        name = nil
    }
}

/// A read-only preview of one authenticated, verified workspace file.
struct WorkspaceModelPreview: View {
    let name: String
    let data: Data
    let revision: String
    let session: WorkspaceModelPreviewSession?
    var onClose: (() -> Void)?

    @StateObject private var ownedSession = WorkspaceModelPreviewSession()

    init(name: String, data: Data, revision: String,
         session: WorkspaceModelPreviewSession? = nil, onClose: (() -> Void)? = nil) {
        self.name = name
        self.data = data
        self.revision = revision
        self.session = session
        self.onClose = onClose
    }

    static func supports(_ name: String) -> Bool {
        ["usdz", "obj", "ply", "stl"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    var body: some View {
        WorkspaceModelPreviewContent(name: name, data: data, revision: revision,
                                     session: session ?? ownedSession, ownsSession: session == nil,
                                     onClose: onClose)
    }
}

private struct WorkspaceModelPreviewContent: View {
    let name: String
    let data: Data
    let revision: String
    @ObservedObject var session: WorkspaceModelPreviewSession
    let ownsSession: Bool
    let onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            Group {
                if let prepared = session.prepared {
                    VStack(spacing: 0) {
                        SceneView(scene: prepared.scene, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                            .accessibilityLabel("3D preview of \(name)")
                            .accessibilityHint("Use the controls below to rotate and zoom.")
                            .accessibilityIdentifier("workspace-model-scene")
                        HStack(spacing: 12) {
                            Button("Rotate left", systemImage: "rotate.left") { rotate(prepared, by: -.pi / 8) }
                                .frame(minWidth: 44, minHeight: 44)
                                .accessibilityIdentifier("workspace-model-rotate-left")
                            Button("Rotate right", systemImage: "rotate.right") { rotate(prepared, by: .pi / 8) }
                                .frame(minWidth: 44, minHeight: 44)
                                .accessibilityIdentifier("workspace-model-rotate-right")
                            Spacer(minLength: 8)
                            Button("Zoom out", systemImage: "minus.magnifyingglass") { zoom(prepared, by: 1.25) }
                                .frame(minWidth: 44, minHeight: 44)
                                .accessibilityIdentifier("workspace-model-zoom-out")
                            Button("Zoom in", systemImage: "plus.magnifyingglass") { zoom(prepared, by: 0.8) }
                                .frame(minWidth: 44, minHeight: 44)
                                .accessibilityIdentifier("workspace-model-zoom-in")
                        }
                        .buttonStyle(.bordered)
                        .labelStyle(.iconOnly)
                        .controlSize(.regular)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                } else if let failure = session.failure {
                    ContentUnavailableView("3D preview unavailable", systemImage: "cube.transparent",
                                           description: Text(failure))
                        .accessibilityIdentifier("workspace-model-error")
                } else {
                    ProgressView("Preparing 3D preview…")
                        .accessibilityIdentifier("workspace-model-loading")
                }
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(onClose == nil ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if onClose == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("workspace-model-close")
                    }
                }
            }
        }
        .task(id: revision) { session.open(name: name, data: data, revision: revision) }
        .onDisappear {
            if ownsSession { session.close() }
        }
    }

    private func rotate(_ model: PreparedModel, by radians: Float) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = reduceMotion ? 0 : 0.2
        model.cameraOrbit.eulerAngles.y += radians
        SCNTransaction.commit()
    }

    private func zoom(_ model: PreparedModel, by factor: Double) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = reduceMotion ? 0 : 0.2
        model.camera.orthographicScale = min(max(model.camera.orthographicScale * factor,
                                                  model.baseScale * 0.4), model.baseScale * 8)
        SCNTransaction.commit()
    }
}

// SceneKit objects are fully constructed on the worker and then moved to the view.
fileprivate struct PreparedModel: @unchecked Sendable {
    let scene: SCNScene
    let directory: URL
    let cameraOrbit: SCNNode
    let camera: SCNCamera
    let baseScale: Double

    func removeTemporaryFile() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func open(name: String, data: Data) throws -> PreparedModel {
        try WorkspaceModelPreflight.validate(name: name, data: data)
        try Task.checkCancellation()
        let suffix = URL(fileURLWithPath: name).pathExtension.lowercased()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wonder-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let url = directory.appendingPathComponent("preview.\(suffix)")
            try data.write(to: url, options: .atomic)
            try Task.checkCancellation()
            let asset = MDLAsset(url: url)
            let scene = SCNScene(mdlAsset: asset)
            var pending = scene.rootNode.childNodes
            var nodes = 0
            var hasGeometry = false
            while let node = pending.popLast() {
                nodes += 1
                guard nodes <= 4_096 else { throw WorkspaceModelPreflight.Failure.tooLarge }
                hasGeometry = hasGeometry || node.geometry != nil
                pending.append(contentsOf: node.childNodes)
            }
            guard hasGeometry else { throw WorkspaceModelPreflight.Failure.noGeometry }
            let (cameraOrbit, camera, baseScale) = try addCamera(to: scene)
            try Task.checkCancellation()
            return PreparedModel(scene: scene, directory: directory,
                                 cameraOrbit: cameraOrbit, camera: camera, baseScale: baseScale)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func addCamera(to scene: SCNScene) throws -> (SCNNode, SCNCamera, Double) {
        let (low, high) = scene.rootNode.boundingBox
        guard [low.x, low.y, low.z, high.x, high.y, high.z]
            .allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }) else {
            throw WorkspaceModelPreflight.Failure.invalid
        }
        let center = SCNVector3((low.x + high.x) / 2, (low.y + high.y) / 2, (low.z + high.z) / 2)
        let width = CGFloat(high.x - low.x)
        let height = CGFloat(high.y - low.y)
        let depth = CGFloat(high.z - low.z)
        let span = max(max(width, height), max(depth, 0.01))
        let orbit = SCNNode()
        orbit.position = center
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        let baseScale = Double(max(span * 1.8, 0.02))
        camera.orthographicScale = baseScale
        camera.zNear = 0.001
        camera.zFar = Double(max(span * 100, 100))
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, Float(span * 2.5))
        orbit.addChildNode(cameraNode)
        scene.rootNode.addChildNode(orbit)
        let lightNode = SCNNode()
        lightNode.light = SCNLight()
        lightNode.light?.type = .omni
        lightNode.position = SCNVector3(center.x, center.y + Float(span), center.z + Float(span * 3))
        scene.rootNode.addChildNode(lightNode)
        scene.background.contents = UIColor.darkGray
        return (orbit, camera, baseScale)
    }
}

enum WorkspaceModelPreflight {
    enum Failure: LocalizedError {
        case unsupported, unsupportedLayout, tooLarge, sidecar, invalid, noGeometry

        var errorDescription: String? {
            switch self {
            case .unsupported: "Wonder can preview a single-file USDZ, OBJ, ASCII PLY, or binary STL model."
            case .unsupportedLayout: "This mesh layout is not supported. Try a single-file model with basic geometry."
            case .tooLarge: "This model exceeds Wonder’s preview size or geometry limit."
            case .sidecar: "This OBJ needs a separate material or texture file. Single-file models are supported."
            case .invalid: "This model is damaged or uses a format Wonder cannot safely preview."
            case .noGeometry: "This model has no visible geometry."
            }
        }
    }

    static func validate(name: String, data: Data) throws {
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024 else { throw Failure.tooLarge }
        switch URL(fileURLWithPath: name).pathExtension.lowercased() {
        case "usdz": try WorkspaceArchivePreflight.validate(data, as: .usdz)
        case "obj": try validateOBJ(data)
        case "ply": try validatePLY(data)
        case "stl": try validateBinarySTL(data)
        default: throw Failure.unsupported
        }
    }

    private static func validateOBJ(_ data: Data) throws {
        guard let source = String(data: data, encoding: .utf8), !source.contains("\0") else { throw Failure.invalid }
        var vertices = 0
        var textureCoordinates = 0
        var normals = 0
        var faces = 0
        var triangles = 0
        for rawLine in source.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.utf8.count <= 16_384 else { throw Failure.tooLarge }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let words = line.split(whereSeparator: \.isWhitespace)
            let command = words.first.map(String.init) ?? ""
            func finiteCoordinates(_ values: ArraySlice<Substring>) -> Bool {
                values.allSatisfy { value in
                    guard let number = Double(value) else { return false }
                    return number.isFinite && abs(number) <= 1_000_000
                }
            }
            func validReference(_ value: Substring, count: Int) -> Bool {
                guard let index = Int(value), index != 0 else { return false }
                return index > 0 ? index <= count : index >= -count
            }
            switch command {
            case "mtllib", "usemtl": throw Failure.sidecar
            case "v":
                guard (4...8).contains(words.count), finiteCoordinates(words.dropFirst()) else { throw Failure.invalid }
                vertices += 1
            case "vt":
                guard (2...4).contains(words.count), finiteCoordinates(words.dropFirst()) else { throw Failure.invalid }
                textureCoordinates += 1
            case "vn":
                guard words.count == 4, finiteCoordinates(words.dropFirst()) else { throw Failure.invalid }
                normals += 1
            case "f":
                guard (4...65).contains(words.count) else { throw Failure.unsupportedLayout }
                for vertex in words.dropFirst() {
                    let references = vertex.split(separator: "/", omittingEmptySubsequences: false)
                    guard (1...3).contains(references.count),
                          validReference(references[0], count: vertices) else { throw Failure.invalid }
                    if references.count >= 2, !references[1].isEmpty,
                       !validReference(references[1], count: textureCoordinates) { throw Failure.invalid }
                    if references.count == 3, !references[2].isEmpty,
                       !validReference(references[2], count: normals) { throw Failure.invalid }
                }
                faces += 1
                triangles += words.count - 3
            case "o", "g", "s": break
            default: throw Failure.unsupported
            }
            guard vertices <= 10_000, textureCoordinates <= 10_000,
                  normals <= 10_000, faces <= 10_000, triangles <= 10_000 else { throw Failure.tooLarge }
        }
        guard vertices >= 3, faces > 0 else { throw Failure.noGeometry }
    }

    private static func validatePLY(_ data: Data) throws {
        guard let raw = String(data: data, encoding: .utf8) else { throw Failure.invalid }
        let source = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard source.hasPrefix("ply\n"),
              let headerEnd = source.range(of: "\nend_header\n"),
              source.distance(from: source.startIndex, to: headerEnd.upperBound) <= 64 * 1024 else {
            throw Failure.invalid
        }
        let header = source[..<headerEnd.upperBound].split(whereSeparator: \.isNewline)
        guard header.count >= 5, header[1] == "format ascii 1.0",
              !header.joined(separator: "\n").lowercased().contains("texturefile") else { throw Failure.unsupportedLayout }
        var vertexCount = 0
        var faceCount = 0
        var section = ""
        var vertexProperties: [String] = []
        var faceProperties: [String] = []
        for line in header.dropFirst(2).dropLast() {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard let first = words.first else { continue }
            switch first {
            case "comment", "obj_info": break
            case "element":
                guard words.count == 3, let count = Int(words[2]), count >= 0 else { throw Failure.invalid }
                section = String(words[1])
                if section == "vertex", vertexCount == 0 { vertexCount = count }
                else if section == "face", faceCount == 0 { faceCount = count }
                else { throw Failure.unsupportedLayout }
            case "property":
                if section == "vertex" { vertexProperties.append(String(line)) }
                else if section == "face" { faceProperties.append(String(line)) }
                else { throw Failure.unsupportedLayout }
            default: throw Failure.unsupportedLayout
            }
        }
        guard vertexCount >= 3, faceCount > 0 else { throw Failure.noGeometry }
        guard vertexCount <= 10_000, faceCount <= 10_000 else { throw Failure.tooLarge }
        guard vertexProperties.count >= 3,
              zip(vertexProperties.prefix(3), ["x", "y", "z"]).allSatisfy({ pair in
                  pair.0 == "property float \(pair.1)" || pair.0 == "property double \(pair.1)"
              }),
              vertexProperties.allSatisfy({ !$0.contains(" list ") }),
              faceProperties == ["property list uchar int vertex_indices"] else {
            throw Failure.unsupportedLayout
        }
        let body = source[headerEnd.upperBound...].split(whereSeparator: \.isNewline)
        guard body.count == vertexCount + faceCount else { throw Failure.invalid }
        for line in body.prefix(vertexCount) {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard words.count == vertexProperties.count, words.allSatisfy({ word in
                guard let number = Double(word) else { return false }
                return number.isFinite && abs(number) <= 1_000_000
            }) else { throw Failure.invalid }
        }
        var triangles = 0
        for line in body.dropFirst(vertexCount) {
            let words = line.split(whereSeparator: \.isWhitespace)
            guard let first = words.first, let indices = Int(first), (3...64).contains(indices),
                  words.count == indices + 1,
                  words.dropFirst().allSatisfy({ index in
                      guard let index = Int(index) else { return false }
                      return (0..<vertexCount).contains(index)
                  }) else { throw Failure.invalid }
            triangles += indices - 2
            guard triangles <= 10_000 else { throw Failure.tooLarge }
        }
    }

    private static func validateBinarySTL(_ data: Data) throws {
        guard data.count >= 84 else { throw Failure.invalid }
        let bytes = [UInt8](data)
        let facets = Int(bytes[80]) | Int(bytes[81]) << 8 | Int(bytes[82]) << 16 | Int(bytes[83]) << 24
        guard facets > 0, data.count == 84 + facets * 50 else { throw Failure.invalid }
        guard facets <= 500 else { throw Failure.tooLarge }
        for facet in 0..<facets {
            let base = 84 + facet * 50
            for offset in stride(from: 0, through: 44, by: 4) {
                let i = base + offset
                let bits = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8
                    | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
                let coordinate = Float(bitPattern: bits)
                guard coordinate.isFinite, abs(coordinate) <= 1_000_000 else { throw Failure.invalid }
            }
        }
    }
}
