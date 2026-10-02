import XCTest
@testable import Wonder

final class WorkspacePreviewPolicyTests: XCTestCase {
    func testEPUBReferencesStayWithinTheContainingResourceDirectory() {
        for target in ["images/cover.png", "chapter.xhtml#part", "style.css", "#section"] {
            XCTAssertFalse(WorkspacePublicationResourceGate.isExternal(target), target)
        }
        for target in ["../images/cover.png", "./cover.png", "images/../cover.png",
                       "images%2f..%2fsecret", "%252e%252e%252fsecret", "/private.png",
                       "https://example.com/image.png", "//example.com/image.png",
                       "file:///tmp/secret", "images//cover.png", "images\\cover.png"] {
            XCTAssertTrue(WorkspacePublicationResourceGate.isExternal(target), target)
        }
    }

    func testModelGeometryBudgetRejectsLargeFilesBeforeSceneKitImport() {
        func stl(facets: Int) -> Data {
            var bytes = [UInt8](repeating: 0, count: 84 + facets * 50)
            for offset in 0..<4 { bytes[80 + offset] = UInt8(truncatingIfNeeded: facets >> (offset * 8)) }
            return Data(bytes)
        }

        XCTAssertNoThrow(try WorkspaceModelPreflight.validate(name: "sample.stl", data: stl(facets: 500)))
        XCTAssertThrowsError(try WorkspaceModelPreflight.validate(name: "sample.stl", data: stl(facets: 501)))

        let vertex = "v 0 0 0\n"
        let faces = "f 1 2 3\n"
        XCTAssertNoThrow(try WorkspaceModelPreflight.validate(
            name: "sample.obj", data: Data((String(repeating: vertex, count: 3)
                + String(repeating: faces, count: 10_000)).utf8)))
        XCTAssertThrowsError(try WorkspaceModelPreflight.validate(
            name: "sample.obj", data: Data((String(repeating: vertex, count: 3)
                + String(repeating: faces, count: 10_001)).utf8)))

        let polygonVertices = String(repeating: vertex, count: 64)
        let polygon = "f " + (1...64).map(String.init).joined(separator: " ") + "\n"
        XCTAssertNoThrow(try WorkspaceModelPreflight.validate(name: "polygon.obj",
            data: Data((polygonVertices + String(repeating: polygon, count: 161)).utf8)))
        XCTAssertThrowsError(try WorkspaceModelPreflight.validate(name: "polygon.obj",
            data: Data((polygonVertices + String(repeating: polygon, count: 162)).utf8)))

        func ply(faces: Int) -> Data {
            let header = """
            ply
            format ascii 1.0
            element vertex 3
            property float x
            property float y
            property float z
            element face \(faces)
            property list uchar int vertex_indices
            end_header

            """
            return Data((header + "0 0 0\n1 0 0\n0 1 0\n"
                         + String(repeating: "3 0 1 2\n", count: faces)).utf8)
        }
        XCTAssertNoThrow(try WorkspaceModelPreflight.validate(name: "sample.ply", data: ply(faces: 10_000)))
        XCTAssertThrowsError(try WorkspaceModelPreflight.validate(name: "sample.ply", data: ply(faces: 10_001)))
    }

    func testModelPreflightRejectsMalformedFaceReferencesBeforeImport() {
        let vertices = "v 0 0 0\nv 1 0 0\nv 0 1 0\n"
        XCTAssertNoThrow(try WorkspaceModelPreflight.validate(
            name: "mesh.obj", data: Data((vertices + "f 1 2 3\n").utf8)))
        XCTAssertThrowsError(try WorkspaceModelPreflight.validate(
            name: "mesh.obj", data: Data((vertices + "f 1 2 4\n").utf8)))
        XCTAssertThrowsError(try WorkspaceModelPreflight.validate(
            name: "mesh.obj", data: Data((vertices + "f 1/999 2 3\n").utf8)))

        let plyHeader = """
        ply
        format ascii 1.0
        element vertex 3
        property float x
        property float y
        property float z
        element face 1
        property list uchar int vertex_indices
        end_header

        """
        let plyVertices = "0 0 0\n1 0 0\n0 1 0\n"
        XCTAssertNoThrow(try WorkspaceModelPreflight.validate(
            name: "mesh.ply", data: Data((plyHeader + plyVertices + "3 0 1 2\n").utf8)))
        XCTAssertThrowsError(try WorkspaceModelPreflight.validate(
            name: "mesh.ply", data: Data((plyHeader + plyVertices + "3 0 1 3\n").utf8)))
        XCTAssertThrowsError(try WorkspaceModelPreflight.validate(
            name: "mesh.ply", data: Data((plyHeader + plyVertices + "3 0 1 2\n3 0 1 2\n").utf8)))
    }
}
