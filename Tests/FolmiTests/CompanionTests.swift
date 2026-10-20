import SwiftUI
import XCTest
@testable import Folmi

final class CompanionTests: XCTestCase {
    func testPrioritiesFollowTheMotionSpec() {
        let order: [CompanionState] = [.error, .attention, .success, .working, .sleep, .idle]
        XCTAssertEqual(order.map(\.priority), order.map(\.priority).sorted(by: >))
        XCTAssertEqual(CompanionState.working.priority, CompanionState.thinking.priority)
    }

    func testEachStateHasItsOwnStillFace() {
        let faces = [CompanionState.idle, .working, .thinking, .success, .attention, .error, .sleep].map(\.pose)
        XCTAssertEqual(Set(faces.map { "\($0.eyes)|\($0.ear)" }).count, faces.count, "no two states look the same when still")
        XCTAssertEqual(CompanionState.error.pose.eyes, .narrow)
        XCTAssertLessThan(CompanionState.attention.pose.ear, 0, "attention raises the ear")
        XCTAssertGreaterThan(CompanionState.error.pose.ear, 0, "an error droops it")
    }

    func testOneShotStatesSettleAndLoopsStaySmall() {
        XCTAssertEqual(CompanionState.success.pose(at: 2).lift, 0, "the nod is over")
        XCTAssertEqual(CompanionState.success.pose(at: 2).accent, 0)
        XCTAssertEqual(CompanionState.attention.pose(at: 5).ear, -16, "attention holds once raised")
        XCTAssertEqual(CompanionState.error.pose(at: 5).ear, 18)
        for t in stride(from: 0.0, to: 10, by: 0.1) {
            XCTAssertLessThanOrEqual(abs(CompanionState.working.pose(at: t).tail), 2, "working only sweeps 2°")
            XCTAssertLessThan(abs(CompanionState.sleep.pose(at: t).scaleY - 1), 0.01, "sleep breathes under 1%")
        }
        XCTAssertEqual(CompanionState.idle.pose(at: 7.1).blink, 0.12, accuracy: 0.001, "idle blinks once per 7.2 s")
        XCTAssertEqual(CompanionState.idle.pose(at: 3).blink, 1)
        XCTAssertFalse(CompanionState.success.loops)
        XCTAssertTrue(CompanionState.working.loops)
    }

    @MainActor
    func testStatusComesFromRealWork() throws {
        let settings = FileManager.default.temporaryDirectory.appendingPathComponent("companion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: settings) }
        let model = FolmiModel(store: WorkspaceStore(url: settings.appendingPathComponent("workspace.json")))
        XCTAssertEqual(model.companionStatus.state, .sleep, "no project open")
        model.commitSuggestion = .generating
        XCTAssertEqual(model.companionStatus.state, .thinking)
        model.capsule = .working(files: 3, prompt: nil)
        XCTAssertEqual(model.companionStatus, CompanionStatus(state: .working, text: "正在改 3 个文件…"))
        model.capsule = .finished(files: 2, prompt: nil, batch: "b")
        XCTAssertEqual(model.companionStatus.state, .attention)
        model.errorMessage = "推送失败：远端有新提交\n详细输出"
        XCTAssertEqual(model.companionStatus, CompanionStatus(state: .error, text: "推送失败：远端有新提交"))
    }

    @MainActor
    func testEveryStillFaceRendersDifferently() throws {
        let states: [CompanionState] = [.idle, .working, .thinking, .success, .attention, .error, .sleep]
        let sheet = HStack(spacing: 8) {
            ForEach(states, id: \.self) { CompanionMark(state: $0, size: 64, animated: false).background(Color.white) }
        }
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("folmi-companion-frames")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("faces.png"))
        // Each 64 pt face is a 128 px column (plus 16 px gaps); compare the faces' pixels pairwise.
        func face(_ index: Int) -> [UInt8] {
            var pixels: [UInt8] = []
            for y in stride(from: 0, to: 128, by: 2) {
                for x in stride(from: index * 144, to: index * 144 + 128, by: 2) {
                    let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                    pixels.append(UInt8((color?.brightnessComponent ?? 1) * 255))
                }
            }
            return pixels
        }
        let faces = states.indices.map(face)
        for a in faces.indices { for b in faces.indices where a < b { XCTAssertNotEqual(faces[a], faces[b], "\(states[a]) and \(states[b]) look the same") } }
        XCTAssertTrue(faces.allSatisfy { $0.contains { $0 < 200 } }, "every face draws the mascot")
    }
}
