import AppKit
import Foundation
import Testing
@testable import HelloXApp

@Suite("Diagram workspace")
struct DiagramTests {
    @MainActor
    @Test func multilineTextGrowsNodesAndKeepsBranchesApart() throws {
        let model = DiagramDocumentModel(kind: .mindMap)
        let node = try #require(model.data.nodes.first(where: { $0.parentID != nil }))
        let original = model.data
        let text = "第一行\n第二行\n第三行\n第四行\n"
        model.updateNode(node.id) { $0.text = text }
        let updated = try #require(model.data.nodes.first(where: { $0.id == node.id }))
        #expect(updated.text == text)
        #expect(updated.size.height > node.size.height)
        #expect(updated.size.width == node.size.width)
        for other in model.data.nodes where other.id != updated.id {
            #expect(!DiagramGeometry.rect(for: updated).intersects(DiagramGeometry.rect(for: other)))
        }
        let edited = model.data
        model.undo()
        #expect(model.data == original)
        model.redo()
        #expect(model.data == edited)
        let reopened = DiagramDocumentModel()
        reopened.replace(with: edited, fileURL: nil)
        #expect(reopened.data == edited)
    }

    @Test func textMeasurementIncludesWrappingAndTrailingNewlines() {
        let single = DiagramTextLayout.requiredHeight(text: "文字", width: 118, depth: 3)
        let newline = DiagramTextLayout.requiredHeight(text: "文字\n", width: 118, depth: 3)
        let wrapped = DiagramTextLayout.requiredHeight(text: String(repeating: "长文字", count: 30), width: 118, depth: 3)
        #expect(newline > single)
        #expect(wrapped > newline)
    }

    @MainActor
    @Test func mindMapTemplateStartsWithFourPrimaryTopics() throws {
        let model = DiagramDocumentModel(kind: .mindMap)
        let root = try #require(model.data.nodes.first(where: { $0.parentID == nil }))
        let primary = model.data.nodes.filter { $0.parentID == root.id }
        let secondary = model.data.nodes.filter { node in
            node.parentID.map { parentID in primary.contains(where: { $0.id == parentID }) } == true
        }

        #expect(model.data.nodes.count == 5)
        #expect(model.data.edges.count == 4)
        #expect(primary.count == 4)
        #expect(secondary.isEmpty)
        #expect(primary.filter { $0.branchSide == .left }.count == 2)
        #expect(primary.filter { $0.branchSide == .right }.count == 2)
        #expect(root.shape == .roundedRectangle)
        #expect(root.fillHex == "#E8F3FF")
        #expect(root.size.width > primary[0].size.width)
        #expect(primary.allSatisfy { $0.fillHex != "#FFFFFF" && $0.lineWidth > 0 })
        #expect(Set(primary.map(\.fillHex)).count == 1)
        #expect(DiagramMindMapStyle.depths(in: model.data)[root.id] == 0)
        #expect(primary.allSatisfy { DiagramMindMapStyle.depths(in: model.data)[$0.id] == 1 })
    }

    @MainActor
    @Test func editsSupportUndoRedoAndDirtyTracking() {
        let model = DiagramDocumentModel(kind: .mindMap)
        let original = model.data
        let id = model.addMindNode(parentID: model.data.nodes[0].id)!
        #expect(model.data.nodes.contains { $0.id == id })
        #expect(model.isModified)
        #expect(model.canUndo)
        model.undo()
        #expect(model.data == original)
        #expect(model.canRedo)
        model.redo()
        #expect(model.data.nodes.contains { $0.id == id })
    }

    @MainActor
    @Test func mindMapLayoutIsDeterministicAndDoesNotOverlapNodes() throws {
        let model = DiagramDocumentModel(kind: .mindMap)
        let root = try #require(model.data.nodes.first?.id)
        let first = try #require(model.addMindNode(parentID: root))
        let second = try #require(model.addMindNode(parentID: root))
        _ = model.addMindNode(parentID: first)
        _ = model.addMindNode(parentID: first)
        _ = model.addMindNode(parentID: second)
        let firstLayout = model.data.nodes.map(\.center)
        model.arrangeMindMap()
        #expect(model.data.nodes.map(\.center) == firstLayout)
        for (index, node) in model.data.nodes.enumerated() {
            for other in model.data.nodes.dropFirst(index + 1) {
                #expect(!DiagramGeometry.rect(for: node).intersects(DiagramGeometry.rect(for: other)))
            }
        }
        #expect(model.data.edges.count == model.data.nodes.count - 1)
    }

    @MainActor
    @Test func mindMapAutomaticallyBalancesRootBranchesAcrossBothSides() throws {
        let model = DiagramDocumentModel(kind: .mindMap)
        let root = try #require(model.data.nodes.first?.id)
        for _ in 0..<5 { _ = model.addMindNode(parentID: root) }

        let rootBranches = model.data.nodes.filter { $0.parentID == root }
        let left = rootBranches.filter { $0.branchSide == .left }
        let right = rootBranches.filter { $0.branchSide == .right }
        #expect(!left.isEmpty)
        #expect(!right.isEmpty)
        #expect(abs(left.count - right.count) <= 1)
        #expect(left.allSatisfy { $0.center.x < 0 })
        #expect(right.allSatisfy { $0.center.x > 0 })
        #expect(Set(rootBranches.map(\.strokeHex)).count == 1)
        #expect(model.data.edges.allSatisfy { $0.style == .curved })
        #expect(model.data.nodes.first(where: { $0.id == root })?.center == .init(x: 0, y: 0))
    }

    @MainActor
    @Test func mindMapDescendantsAndSiblingsStayOnTheirBranchSide() throws {
        let model = DiagramDocumentModel(kind: .mindMap)
        let root = try #require(model.data.nodes.first?.id)
        let first = try #require(model.addMindNode(parentID: root))
        let firstNode = try #require(model.data.nodes.first(where: { $0.id == first }))
        let child = try #require(model.addMindNode(parentID: first))
        let sibling = try #require(model.addMindSibling(of: first))

        for id in [first, child, sibling] {
            let node = try #require(model.data.nodes.first(where: { $0.id == id }))
            #expect(node.branchSide == firstNode.branchSide)
            #expect((node.center.x < 0) == (firstNode.branchSide == .left))
        }
    }

    @MainActor
    @Test func legacyMindMapWithoutBranchSideDecodesAndMigratesToBalancedLayout() throws {
        let model = DiagramDocumentModel(kind: .mindMap)
        let root = try #require(model.data.nodes.first?.id)
        for _ in 0..<4 { _ = model.addMindNode(parentID: root) }
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(model.data)) as? [String: Any])
        object["nodes"] = try #require(object["nodes"] as? [[String: Any]]).map { node in
            var legacyNode = node
            legacyNode.removeValue(forKey: "branchSide")
            return legacyNode
        }
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        var legacy = try JSONDecoder().decode(DiagramDocumentData.self, from: legacyData)
        DiagramDocumentModel.applyMindMapLayout(to: &legacy)

        let sides = Set(legacy.nodes.compactMap(\.branchSide))
        #expect(sides == [.left, .right])
    }

    @MainActor
    @Test func deletingMindMapParentRemovesItsBranchButKeepsRoot() throws {
        let model = DiagramDocumentModel(kind: .mindMap)
        let root = try #require(model.data.nodes.first?.id)
        let originalIDs = Set(model.data.nodes.map(\.id))
        let parent = try #require(model.addMindNode(parentID: root))
        let child = try #require(model.addMindNode(parentID: parent))
        model.delete(nodeIDs: [parent], edgeID: nil)
        #expect(Set(model.data.nodes.map(\.id)) == originalIDs)
        #expect(!model.data.nodes.contains { $0.id == child })
        model.delete(nodeIDs: [root], edgeID: nil)
        #expect(model.data.nodes.map(\.id) == [root])
    }

    @MainActor
    @Test func documentRoundTripsThroughNativeFormat() throws {
        let model = DiagramDocumentModel(kind: .mindMap)
        let root = try #require(model.data.nodes.first?.id)
        _ = model.addMindNode(parentID: root)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelloXDiagramTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample.hxdiagram")
        try DiagramFileService.write(model.data, to: url)
        #expect(try DiagramFileService.read(from: url) == model.data)
    }

    @MainActor
    @Test func svgExportContainsNodesConnectionsAndEscapedText() throws {
        var document = DiagramDocumentData.template(.mindMap)
        document.nodes[0].text = "A & B < C"
        document.edges[0].showsArrow = true
        let svg = DiagramExporter.svg(document)
        #expect(svg.contains("<svg"))
        #expect(svg.contains("<polyline"))
        #expect(svg.contains("A &amp; B &lt; C"))
        #expect(svg.contains("marker-end"))
    }

    @MainActor
    @Test func pngAndPDFExportsProduceNativeFiles() throws {
        _ = NSApplication.shared
        let document = DiagramDocumentData.template(.mindMap)
        let png = try DiagramExporter.pngData(document)
        let pdf = try DiagramExporter.pdfData(document)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(String(data: pdf.prefix(4), encoding: .ascii) == "%PDF")
    }

    @MainActor
    @Test func renderPolishedMindMapSample() throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] else { return }
        let model = DiagramDocumentModel(kind: .mindMap)
        let root = try #require(model.data.nodes.first?.id)
        for _ in 0..<10 { _ = model.addMindNode(parentID: root) }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try DiagramExporter.pngData(model.data).write(to: output.appendingPathComponent("mindmap-polished.png"))
    }

    @Test func edgeGeometryTerminatesAtNodeBoundaries() throws {
        let document = DiagramDocumentData.template(.mindMap)
        let source = document.nodes[0]
        let target = document.nodes[1]
        let edge = try #require(document.edges.first)
        let points = DiagramGeometry.edgePoints(edge: edge, source: source, target: target)
        #expect(points.count >= 2)
        #expect(isOnBoundary(points.first!, of: DiagramGeometry.rect(for: source)))
        #expect(isOnBoundary(points.last!, of: DiagramGeometry.rect(for: target)))
        #expect(points.first != source.center.cgPoint)
        #expect(points.last != target.center.cgPoint)
    }

    @MainActor
    @Test func attachingSubtreeChangesParentAndSideAndCanUndo() throws {
        let model = DiagramDocumentModel(kind: .mindMap)
        let original = model.data
        let branch = original.nodes[1]
        let target = try #require(original.nodes.first { $0.branchSide == .right })
        let moving = model.movingNodeIDs(for: [branch.id])
        #expect(model.dropTarget(for: moving, at: target.center.cgPoint)?.nodeID == target.id)
        #expect(model.dropTarget(for: moving, at: branch.center.cgPoint) == nil)
        model.beginInteraction()
        model.attachDuringInteraction(nodeIDs: moving, to: target.id)
        model.endInteraction()
        #expect(model.data.nodes.first { $0.id == branch.id }?.parentID == target.id)
        #expect(model.data.nodes.filter { moving.contains($0.id) }.allSatisfy { $0.branchSide == .right })
        #expect(model.data.edges.filter { $0.targetID == branch.id }.map(\.sourceID) == [target.id])
        #expect(model.data.edges.count == original.edges.count)
        model.undo()
        #expect(model.data == original)
    }

    @MainActor
    @Test func attachmentRejectsCyclesAndRootMovementMovesEverything() throws {
        let model = populatedMindMap()
        let original = model.data
        let root = original.nodes[0]
        let branch = original.nodes[1]
        let child = try #require(original.nodes.first { $0.parentID == branch.id })
        model.beginInteraction()
        model.attachDuringInteraction(nodeIDs: [branch.id], to: child.id)
        model.attachDuringInteraction(nodeIDs: [root.id], to: branch.id)
        model.endInteraction()
        #expect(model.data == original)
        #expect(model.movingNodeIDs(for: [root.id]).count == original.nodes.count)
    }

    @MainActor
    @Test func openingAndArrangingPreserveCustomAppearance() {
        let model = DiagramDocumentModel(kind: .mindMap)
        var original = model.data
        original.nodes[1].strokeHex = "#123456"
        original.nodes[1].fillHex = "#ABCDEF"
        original.nodes[1].lineWidth = 3
        model.replace(with: original, fileURL: nil)
        model.arrangeMindMap()
        for (before, after) in zip(original.nodes, model.data.nodes) {
            #expect(before.strokeHex == after.strokeHex)
            #expect(before.fillHex == after.fillHex)
            #expect(before.lineWidth == after.lineWidth)
        }
    }

    @Test func mindMapConnectionsRemainOnFixedHorizontalSidesWhenCrossingParent() {
        let document = DiagramDocumentData.template(.mindMap)
        let source = document.nodes[0]
        var target = document.nodes[1]
        for point in [DiagramPoint(x: -20, y: 600), .init(x: 400, y: -600), .init(x: 0, y: 0)] {
            target.center = point
            let endpoints = DiagramGeometry.endpoints(source: source, target: target)
            #expect(endpoints.0 == CGPoint(x: source.center.x - source.size.width / 2, y: source.center.y))
            #expect(endpoints.1 == CGPoint(x: target.center.x + target.size.width / 2, y: target.center.y))
        }
    }

    @MainActor
    @Test func childCanMoveAfterAnotherChildAndShiftFollowingTopics() throws {
        let model = populatedMindMap()
        let parent = model.data.nodes[1]
        let thirdID = try #require(model.addMindNode(parentID: parent.id))
        let fourthID = try #require(model.addMindNode(parentID: parent.id))
        let children = model.data.nodes.filter { $0.parentID == parent.id }
        let original = model.data
        let firstID = children[0].id
        let destination = children[1]
        let drop = try #require(model.dropTarget(for: [firstID], at: destination.center.cgPoint))
        #expect(drop.placement == .after)
        model.moveMindNodes([firstID], to: drop)
        let reordered = model.data.nodes.filter { $0.parentID == parent.id }
        #expect(reordered.map(\.id) == [destination.id, firstID, thirdID, fourthID])
        #expect(reordered.map { $0.center.y } == reordered.map { $0.center.y }.sorted())
        #expect(reordered[0].center.y != destination.center.y)
        model.undo()
        #expect(model.data == original)
        model.redo()
        #expect(model.data.nodes.filter { $0.parentID == parent.id }.map(\.id) == reordered.map(\.id))
    }

    @MainActor
    @Test func movingSubtreeAfterTopicInAnotherBranchReparentsAndPreservesChildren() throws {
        let model = populatedMindMap()
        let parent = model.data.nodes[1]
        let branchID = try #require(model.addMindNode(parentID: parent.id))
        let leafID = try #require(model.addMindNode(parentID: branchID))
        let otherParent = try #require(model.data.nodes.first { $0.branchSide == .right })
        let target = try #require(model.data.nodes.first { $0.parentID == otherParent.id })
        let original = model.data
        model.moveMindNodes([branchID], to: .init(nodeID: target.id, placement: .after))
        let siblings = model.data.nodes.filter { $0.parentID == otherParent.id }
        let targetIndex = try #require(siblings.firstIndex { $0.id == target.id })
        #expect(siblings[targetIndex + 1].id == branchID)
        #expect(model.data.nodes.first { $0.id == leafID }?.parentID == branchID)
        #expect(model.data.nodes.first { $0.id == leafID }?.branchSide == .right)
        #expect(model.data.edges.filter { $0.targetID == branchID }.map(\.sourceID) == [otherParent.id])
        for (index, node) in model.data.nodes.enumerated() {
            for other in model.data.nodes.dropFirst(index + 1) {
                #expect(!DiagramGeometry.rect(for: node).intersects(DiagramGeometry.rect(for: other)))
            }
        }
        model.undo()
        #expect(model.data == original)
    }

    @MainActor
    @Test func dropsOnBlankSpaceAndOwnDescendantsDoNotMoveNodes() throws {
        let model = populatedMindMap()
        let original = model.data
        let parent = original.nodes[1]
        let child = try #require(original.nodes.first { $0.parentID == parent.id })
        #expect(model.dropTarget(for: [parent.id], at: CGPoint(x: 10000, y: 10000)) == nil)
        #expect(model.dropTarget(for: [parent.id], at: child.center.cgPoint) == nil)
        model.moveMindNodes([parent.id], to: .init(nodeID: child.id, placement: .after))
        #expect(model.data == original)
        #expect(!model.canUndo)
    }

    @MainActor
    @Test func movingMultipleTopicsKeepsTheirOrderAndBeforeInsertionWorks() throws {
        let model = populatedMindMap()
        let parent = model.data.nodes[1]
        _ = model.addMindNode(parentID: parent.id)
        _ = model.addMindNode(parentID: parent.id)
        let children = model.data.nodes.filter { $0.parentID == parent.id }
        model.moveMindNodes([children[2].id, children[3].id], to: .init(nodeID: children[0].id, placement: .before))
        #expect(model.data.nodes.filter { $0.parentID == parent.id }.map(\.id)
            == [children[2].id, children[3].id, children[0].id, children[1].id])
    }

    @Test func legacyFlowchartFilesAreRejectedWithoutChangingTheFile() throws {
        let original = try JSONEncoder().encode(DiagramDocumentData.template(.mindMap))
        let json = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "mindMap", with: "flowchart")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID()).hxdiagram")
        try Data(json.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try DiagramFileService.read(from: url) }
        #expect(try Data(contentsOf: url) == Data(json.utf8))
    }

    @MainActor
    @Test func largeTopicsReserveSpaceDuringReordering() throws {
        let model = populatedMindMap()
        let parent = model.data.nodes[1]
        let children = model.data.nodes.filter { $0.parentID == parent.id }
        model.updateNode(children[0].id) { $0.size = .init(width: 380, height: 220) }
        model.moveMindNodes([children[0].id], to: .init(nodeID: children[1].id, placement: .after))
        for (index, node) in model.data.nodes.enumerated() {
            for other in model.data.nodes.dropFirst(index + 1) {
                #expect(!DiagramGeometry.rect(for: node).intersects(DiagramGeometry.rect(for: other)))
            }
        }
    }

    @MainActor
    @Test func dragPreviewMatchesDropWithoutChangingDocumentOrUndoHistory() throws {
        let model = DiagramDocumentModel(kind: .mindMap)
        let moving = model.data.nodes[1]
        let target = try #require(model.data.nodes.first { $0.branchSide == .right })
        let original = model.data
        let drop = DiagramDocumentModel.DropTarget(nodeID: target.id, placement: .after)
        let preview = model.previewMindMove([moving.id], to: drop)
        #expect(model.data == original)
        #expect(!model.canUndo)
        #expect(preview.nodes.first { $0.id == moving.id }?.branchSide == .right)
        model.moveMindNodes([moving.id], to: drop)
        #expect(model.data == preview)
        model.undo()
        #expect(model.data == original)
    }

    @MainActor
    @Test func newTopicsUseGradedSizesAndPreserveResizedTopics() throws {
        let model = DiagramDocumentModel(kind: .mindMap)
        let depths = DiagramMindMapStyle.depths(in: model.data)
        #expect(model.data.nodes.allSatisfy { $0.size == DiagramMindMapStyle.defaultTopicSize(depth: depths[$0.id, default: 0]) })
        let first = try #require(model.addMindNode(parentID: model.data.nodes[0].id))
        #expect(model.data.nodes.first { $0.id == first }?.size == .init(width: 166, height: 56))
        model.updateNode(first) { $0.size = .init(width: 240, height: 80) }
        let second = try #require(model.addMindNode(parentID: first))
        let third = try #require(model.addMindNode(parentID: second))
        let fourth = try #require(model.addMindNode(parentID: third))
        for (id, expected) in [(first, DiagramSize(width: 166, height: 56)),
                               (second, .init(width: 132, height: 40)),
                               (third, .init(width: 118, height: 34))] {
            let sibling = try #require(model.addMindSibling(of: id))
            #expect(model.data.nodes.first { $0.id == sibling }?.size == expected)
            if id != first { #expect(model.data.nodes.first { $0.id == id }?.size == expected) }
        }
        #expect(model.data.nodes.first { $0.id == fourth }?.size == .init(width: 118, height: 34))
        model.arrangeMindMap()
        #expect(model.data.nodes.first { $0.id == first }?.size == .init(width: 240, height: 80))
    }

    @MainActor
    @Test func reparentPreviewPreservesConnectionIdentityAndStyle() throws {
        let model = DiagramDocumentModel(kind: .mindMap)
        let moving = model.data.nodes[1]
        let target = try #require(model.data.nodes.first { $0.branchSide == .right })
        let edge = try #require(model.data.edges.first { $0.targetID == moving.id })
        model.updateEdge(edge.id) { $0.strokeHex = "#123456"; $0.lineWidth = 3 }
        let drop = DiagramDocumentModel.DropTarget(nodeID: target.id, placement: .child)
        let preview = model.previewMindMove([moving.id], to: drop)
        model.moveMindNodes([moving.id], to: drop)
        #expect(model.data == preview)
        let movedEdge = try #require(model.data.edges.first { $0.id == edge.id })
        #expect(movedEdge.strokeHex == "#123456")
        #expect(movedEdge.lineWidth == 3)
    }

    @MainActor
    @Test func reparentingResetsEntireBranchToNewLevelSizesAndUndoRestoresCustomSizes() throws {
        let model = populatedMindMap()
        let branch = model.data.nodes[1]
        let target = try #require(model.data.nodes.first { $0.branchSide == .right })
        let child = try #require(model.data.nodes.first { $0.parentID == branch.id })
        model.updateNode(branch.id) { $0.size = .init(width: 320, height: 100) }
        model.updateNode(child.id) { $0.size = .init(width: 260, height: 90) }
        model.updateNode(target.id) { $0.size = .init(width: 290, height: 110) }
        let before = model.data
        let drop = DiagramDocumentModel.DropTarget(nodeID: target.id, placement: .child)
        let preview = model.previewMindMove([branch.id], to: drop)
        #expect(model.data == before)
        model.moveMindNodes([branch.id], to: drop)
        #expect(model.data == preview)
        #expect(model.data.nodes.first { $0.id == branch.id }?.size == .init(width: 132, height: 40))
        #expect(model.data.nodes.first { $0.id == child.id }?.size == .init(width: 118, height: 34))
        #expect(model.data.nodes.first { $0.id == target.id }?.size == .init(width: 290, height: 110))
        let moved = model.data
        model.undo()
        #expect(model.data == before)
        model.redo()
        #expect(model.data == moved)
        model.moveMindNodes([branch.id], to: .init(nodeID: target.id, placement: .after))
        #expect(model.data.nodes.first { $0.id == branch.id }?.size == .init(width: 166, height: 56))
        #expect(model.data.nodes.first { $0.id == child.id }?.size == .init(width: 132, height: 40))
    }

    @MainActor
    @Test func reorderingWithinSameParentKeepsCustomSize() throws {
        let model = populatedMindMap()
        let branch = model.data.nodes[1]
        let children = model.data.nodes.filter { $0.parentID == branch.id }
        let moving = children[0]
        model.updateNode(moving.id) { $0.size = .init(width: 260, height: 90) }
        model.moveMindNodes([moving.id], to: .init(nodeID: children[1].id, placement: .after))
        #expect(model.data.nodes.first { $0.id == moving.id }?.size == .init(width: 260, height: 90))
    }

    @MainActor
    private func populatedMindMap() -> DiagramDocumentModel {
        let model = DiagramDocumentModel(kind: .mindMap)
        let branches = model.data.nodes.filter { $0.parentID != nil }
        for branch in branches {
            _ = model.addMindNode(parentID: branch.id)
            _ = model.addMindNode(parentID: branch.id)
        }
        model.replace(with: model.data, fileURL: nil)
        return model
    }

    @MainActor
    @Test func pngExportRendersAtFourTimesResolutionWithoutChangingAspectRatio() throws {
        _ = NSApplication.shared
        let document = DiagramDocumentData.template(.mindMap)
        let bounds = DiagramGeometry.documentBounds(document).integral
        let bitmap = try #require(NSBitmapImageRep(data: DiagramExporter.pngData(document)))
        #expect(bitmap.pixelsWide == Int(bounds.width * 4))
        #expect(bitmap.pixelsHigh == Int(bounds.height * 4))
        #expect(abs(Double(bitmap.pixelsWide) / Double(bitmap.pixelsHigh) - bounds.width / bounds.height) < 0.0001)
        // A real render must contain topic/text pixels, not only a background or transparent bitmap.
        let background = try #require(bitmap.colorAt(x: 0, y: 0))
        let containsDrawing = stride(from: 0, to: bitmap.pixelsWide, by: 16).contains { x in
            stride(from: 0, to: bitmap.pixelsHigh, by: 16).contains { y in
                guard let color = bitmap.colorAt(x: x, y: y) else { return false }
                return color != background
            }
        }
        #expect(containsDrawing)
    }

    @MainActor
    @Test func initialMindMapUsesOneColorFamilyAndPreservesCustomColors() throws {
        let model = DiagramDocumentModel(kind: .mindMap)
        #expect(model.data.nodes.count == 5)
        #expect(Set(model.data.nodes.map(\.fillHex)) == ["#E8F3FF"])
        #expect(Set(model.data.nodes.map(\.strokeHex)) == ["#1677FF"])
        #expect(Set(model.data.edges.map(\.strokeHex)) == ["#1677FF"])
        let first = model.data.nodes[1]
        let child = try #require(model.addMindNode(parentID: first.id))
        #expect(model.data.edges.first { $0.targetID == child }?.strokeHex == "#1677FF")
        let edge = try #require(model.data.edges.first)
        model.updateEdge(edge.id) { $0.strokeHex = "#ABC123" }
        model.updateNode(first.id) { $0.fillHex = "#FAEEFC"; $0.strokeHex = "#D979E8" }
        let saved = model.data
        model.replace(with: saved, fileURL: nil)
        #expect(model.data == saved)
    }

    private func isOnBoundary(_ point: CGPoint, of rect: CGRect) -> Bool {
        let epsilon = 0.001
        let onVertical = (abs(point.x - rect.minX) < epsilon || abs(point.x - rect.maxX) < epsilon)
            && point.y >= rect.minY - epsilon && point.y <= rect.maxY + epsilon
        let onHorizontal = (abs(point.y - rect.minY) < epsilon || abs(point.y - rect.maxY) < epsilon)
            && point.x >= rect.minX - epsilon && point.x <= rect.maxX + epsilon
        return onVertical || onHorizontal
    }
}
