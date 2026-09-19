import AppKit
import Foundation
import SwiftUI

enum DiagramKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case mindMap

    var id: String { rawValue }
    var title: String { "脑图" }
}

enum DiagramNodeShape: String, Codable, CaseIterable, Identifiable, Sendable {
    case rectangle
    case roundedRectangle
    case ellipse
    case diamond
    case text

    var id: String { rawValue }
    var title: String {
        switch self {
        case .rectangle: "矩形"
        case .roundedRectangle: "圆角矩形"
        case .ellipse: "椭圆"
        case .diamond: "判断"
        case .text: "文本"
        }
    }
}

enum DiagramEdgeStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case orthogonal
    case straight
    case curved

    var id: String { rawValue }
    var title: String {
        switch self {
        case .orthogonal: "折线"
        case .straight: "直线"
        case .curved: "曲线"
        }
    }
}

enum DiagramBranchSide: String, Codable, Hashable, Sendable {
    case left
    case right

    var direction: Double { self == .left ? -1 : 1 }
}

struct DiagramPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct DiagramSize: Codable, Equatable, Sendable {
    var width: Double
    var height: Double
}

struct DiagramNode: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var text: String
    var center: DiagramPoint
    var size: DiagramSize
    var shape: DiagramNodeShape
    var fillHex: String
    var strokeHex: String
    var textHex: String
    var lineWidth: Double = 1.5
    var parentID: UUID?
    var branchSide: DiagramBranchSide?
}

struct DiagramEdge: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var sourceID: UUID
    var targetID: UUID
    var label = ""
    var style: DiagramEdgeStyle = .orthogonal
    var strokeHex = "#667085"
    var lineWidth: Double = 1.6
    var showsArrow = true
}

struct DiagramDocumentData: Codable, Equatable, Sendable {
    var version = 1
    var kind: DiagramKind
    var title: String
    var nodes: [DiagramNode]
    var edges: [DiagramEdge]
    var backgroundHex = "#F7F8FA"

    static func template(_ kind: DiagramKind) -> DiagramDocumentData {
        switch kind {
        case .mindMap:
            let root = DiagramNode(
                text: "中心主题", center: .init(x: 0, y: 0), size: .init(width: 230, height: 76),
                shape: .roundedRectangle, fillHex: "#E8F3FF", strokeHex: "#1677FF", textHex: "#172B4D",
                lineWidth: 1.5
            )
            var nodes = [root]
            var edges: [DiagramEdge] = []
            let branches: [(DiagramBranchSide, Double, String, String)] = [
                (.left, -68, "#1677FF", "#E8F3FF"),
                (.right, -68, "#1677FF", "#E8F3FF"),
                (.left, 68, "#1677FF", "#E8F3FF"),
                (.right, 68, "#1677FF", "#E8F3FF")
            ]
            for (side, centerY, accent, softFill) in branches {
                let primary = DiagramNode(
                    text: "一级主题",
                    center: .init(x: side.direction * 290, y: centerY),
                    size: DiagramMindMapStyle.defaultTopicSize(depth: 1),
                    shape: .roundedRectangle,
                    fillHex: softFill,
                    strokeHex: accent,
                    textHex: "#172B4D",
                    lineWidth: 1.5,
                    parentID: root.id,
                    branchSide: side
                )
                nodes.append(primary)
                edges.append(DiagramEdge(
                    sourceID: root.id, targetID: primary.id, style: .curved,
                    strokeHex: accent, lineWidth: 2, showsArrow: false
                ))

            }
            return DiagramDocumentData(
                kind: kind,
                title: "未命名脑图",
                nodes: nodes,
                edges: edges,
                backgroundHex: "#FFFFFF"
            )
        }
    }
}

enum DiagramMindMapStyle {
    static func defaultTopicSize(depth: Int) -> DiagramSize {
        switch depth {
        case 0: .init(width: 230, height: 76)
        case 1: .init(width: 166, height: 56)
        case 2: .init(width: 132, height: 40)
        default: .init(width: 118, height: 34)
        }
    }

    struct BranchPalette: Sendable {
        let accent: String
        let strongFill: String
        let softFill: String
        let deepText: String
    }

    static let palette: [BranchPalette] = [
        .init(accent: "#D979E8", strongFill: "#D979E8", softFill: "#FAEEFC", deepText: "#7E348A"),
        .init(accent: "#FF686D", strongFill: "#FF686D", softFill: "#FFF0F1", deepText: "#9D3034"),
        .init(accent: "#FF9963", strongFill: "#FF9963", softFill: "#FFF3EA", deepText: "#96502A"),
        .init(accent: "#91D3B5", strongFill: "#91D3B5", softFill: "#ECF8F3", deepText: "#397A61"),
        .init(accent: "#62C5EE", strongFill: "#62C5EE", softFill: "#EAF8FD", deepText: "#286D89"),
        .init(accent: "#7ED8CE", strongFill: "#7ED8CE", softFill: "#ECFAF8", deepText: "#27766E")
    ]

    static func depths(in document: DiagramDocumentData) -> [UUID: Int] {
        guard document.kind == .mindMap,
              let root = document.nodes.first(where: { $0.parentID == nil }) else { return [:] }
        let children = Dictionary(grouping: document.nodes.filter { $0.parentID != nil }, by: { $0.parentID! })
        var result: [UUID: Int] = [root.id: 0]
        var queue: [(UUID, Int)] = [(root.id, 0)]
        var cursor = 0
        while cursor < queue.count {
            let (parentID, depth) = queue[cursor]
            cursor += 1
            for child in children[parentID] ?? [] where result[child.id] == nil {
                result[child.id] = depth + 1
                queue.append((child.id, depth + 1))
            }
        }
        return result
    }

    static func fontSize(depth: Int) -> CGFloat {
        switch depth {
        case 0: 28
        case 1: 16
        case 2: 13
        default: 12
        }
    }

    static func fontWeight(depth: Int) -> Font.Weight {
        switch depth {
        case 0: .bold
        case 1: .semibold
        case 2: .medium
        default: .regular
        }
    }
}

enum DiagramTextLayout {
    static func requiredHeight(text: String, width: Double, depth: Int) -> Double {
        let weight: NSFont.Weight = switch depth {
        case 0: .bold
        case 1: .semibold
        case 2: .medium
        default: .regular
        }
        let font = NSFont.systemFont(ofSize: DiagramMindMapStyle.fontSize(depth: depth), weight: weight)
        let storage = NSTextStorage(string: text + "\u{200B}", attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width - 26), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height) + 16
    }
}

@MainActor
final class DiagramDocumentModel: ObservableObject {
    @Published private(set) var data: DiagramDocumentData
    @Published private(set) var fileURL: URL?
    @Published private(set) var savedSnapshot: DiagramDocumentData

    private var undoStack: [DiagramDocumentData] = []
    private var redoStack: [DiagramDocumentData] = []
    private var interactionSnapshot: DiagramDocumentData?

    init(kind: DiagramKind = .mindMap) {
        var template = DiagramDocumentData.template(kind)
        Self.applyMindMapLayout(to: &template)
        data = template
        savedSnapshot = template
    }

    var isModified: Bool { data != savedSnapshot }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var displayName: String { fileURL?.deletingPathExtension().lastPathComponent ?? data.title }

    func replace(with value: DiagramDocumentData, fileURL: URL?) {
        var normalized = value
        Self.applyMindMapLayout(to: &normalized)
        data = normalized
        self.fileURL = fileURL
        savedSnapshot = normalized
        undoStack.removeAll()
        redoStack.removeAll()
        interactionSnapshot = nil
    }

    func newDocument(kind: DiagramKind) {
        replace(with: .template(kind), fileURL: nil)
    }

    func discardChanges() {
        replace(with: savedSnapshot, fileURL: fileURL)
    }

    func markSaved(at url: URL) {
        fileURL = url
        savedSnapshot = data
        objectWillChange.send()
    }

    func commit(_ mutation: (inout DiagramDocumentData) -> Void) {
        let before = data
        var after = before
        mutation(&after)
        guard after != before else { return }
        undoStack.append(before)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        data = after
    }

    func beginInteraction() {
        if interactionSnapshot == nil { interactionSnapshot = data }
    }

    func updateDuringInteraction(_ mutation: (inout DiagramDocumentData) -> Void) {
        var updated = data
        mutation(&updated)
        data = updated
    }

    func endInteraction() {
        guard let before = interactionSnapshot else { return }
        interactionSnapshot = nil
        guard before != data else { return }
        undoStack.append(before)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(data)
        data = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(data)
        data = next
    }

    @discardableResult
    func addMindNode(parentID: UUID?, preferredSide: DiagramBranchSide? = nil) -> UUID? {
        guard data.kind == .mindMap else { return nil }
        let root = data.nodes.first(where: { $0.parentID == nil })
        let resolvedParent = parentID ?? root?.id
        guard let resolvedParent,
              let parent = data.nodes.first(where: { $0.id == resolvedParent }) else { return nil }
        let branchSide: DiagramBranchSide
        if resolvedParent == root?.id {
            branchSide = preferredSide ?? Self.preferredSideForNewRootBranch(in: data, rootID: resolvedParent)
        } else {
            branchSide = parent.branchSide ?? (parent.center.x < (root?.center.x ?? 0) ? .left : .right)
        }
        let id = UUID()
        commit { document in
            document.nodes.append(DiagramNode(
                id: id,
                text: "新主题",
                center: .init(x: parent.center.x + branchSide.direction * 220, y: parent.center.y),
                size: DiagramMindMapStyle.defaultTopicSize(depth: DiagramMindMapStyle.depths(in: document)[resolvedParent, default: 0] + 1),
                shape: .roundedRectangle,
                fillHex: parent.fillHex,
                strokeHex: parent.strokeHex,
                textHex: "#1D2939",
                lineWidth: 1,
                parentID: resolvedParent,
                branchSide: branchSide
            ))
            document.edges.append(DiagramEdge(
                sourceID: resolvedParent, targetID: id, style: .curved,
                strokeHex: parent.strokeHex, lineWidth: 1.4, showsArrow: false
            ))
            Self.applyMindMapLayout(to: &document)
        }
        return id
    }

    @discardableResult
    func addMindSibling(of nodeID: UUID) -> UUID? {
        guard let node = data.nodes.first(where: { $0.id == nodeID }), let parentID = node.parentID else {
            return addMindNode(parentID: nodeID)
        }
        return addMindNode(parentID: parentID, preferredSide: node.branchSide)
    }

    func connect(sourceID: UUID, targetID: UUID) {
        moveMindNodes([targetID], to: .init(nodeID: sourceID, placement: .child))
    }

    func delete(nodeIDs: Set<UUID>, edgeID: UUID?) {
        guard !nodeIDs.isEmpty || edgeID != nil else { return }
        commit { document in
            var deleting = nodeIDs
            if document.kind == .mindMap {
                var changed = true
                while changed {
                    changed = false
                    for node in document.nodes where node.parentID.map(deleting.contains) == true && !deleting.contains(node.id) {
                        deleting.insert(node.id)
                        changed = true
                    }
                }
                if let root = document.nodes.first(where: { $0.parentID == nil }) { deleting.remove(root.id) }
            }
            document.nodes.removeAll { deleting.contains($0.id) }
            document.edges.removeAll {
                deleting.contains($0.sourceID) || deleting.contains($0.targetID) || $0.id == edgeID
            }
            if document.kind == .mindMap { Self.applyMindMapLayout(to: &document) }
        }
    }

    func arrangeMindMap() {
        commit { Self.applyMindMapLayout(to: &$0) }
    }

    func movingNodeIDs(for selected: Set<UUID>) -> Set<UUID> {
        guard data.kind == .mindMap else { return selected }
        var result = selected
        var previousCount = -1
        while previousCount != result.count {
            previousCount = result.count
            for node in data.nodes where node.parentID.map(result.contains) == true {
                result.insert(node.id)
            }
        }
        return result
    }

    enum DropPlacement: Equatable { case before, after, child }
    struct DropTarget: Equatable {
        let nodeID: UUID
        let placement: DropPlacement
    }

    func dropTarget(for selected: Set<UUID>, at point: CGPoint) -> DropTarget? {
        let moving = movingNodeIDs(for: selected)
        guard !data.nodes.contains(where: { moving.contains($0.id) && $0.parentID == nil }) else { return nil }
        guard let target = data.nodes.filter({
            !moving.contains($0.id) && DiagramGeometry.rect(for: $0).insetBy(dx: -44, dy: -24).contains(point)
        }).min(by: {
            hypot($0.center.x - point.x, $0.center.y - point.y) < hypot($1.center.x - point.x, $1.center.y - point.y)
        }) else { return nil }
        let rect = DiagramGeometry.rect(for: target)
        let beyondOuterSide = target.branchSide == .left ? point.x < rect.minX : point.x > rect.maxX
        let placement: DropPlacement = target.parentID == nil || beyondOuterSide ? .child
            : (point.y < rect.minY + rect.height * 0.3 ? .before : .after)
        return DropTarget(nodeID: target.id, placement: placement)
    }

    func previewMindMove(_ selected: Set<UUID>, to target: DropTarget) -> DiagramDocumentData {
        var preview = data
        Self.applyDrop(selected, to: target, in: &preview)
        return preview
    }

    func moveMindNodes(_ selected: Set<UUID>, to target: DropTarget) {
        commit { document in Self.applyDrop(selected, to: target, in: &document) }
    }

    func attachDuringInteraction(nodeIDs: Set<UUID>, to parentID: UUID) {
        updateDuringInteraction { document in
            Self.applyDrop(nodeIDs, to: DropTarget(nodeID: parentID, placement: .child), in: &document)
        }
    }

    private static func applyDrop(_ selected: Set<UUID>, to drop: DropTarget, in document: inout DiagramDocumentData) {
        var moving = selected
        var count = -1
        while count != moving.count {
            count = moving.count
            for node in document.nodes where node.parentID.map(moving.contains) == true { moving.insert(node.id) }
        }
        guard !moving.contains(drop.nodeID),
              !document.nodes.contains(where: { moving.contains($0.id) && $0.parentID == nil }),
              let target = document.nodes.first(where: { $0.id == drop.nodeID }) else { return }
        let parentID = drop.placement == .child ? target.id : target.parentID
        guard let parentID else { return }
        var roots = document.nodes.filter { moving.contains($0.id) && !($0.parentID.map(moving.contains) ?? false) }
        guard !roots.isEmpty else { return }
        let rootIDs = Set(roots.map(\.id))
        var resizedIDs = Set(roots.filter { $0.parentID != parentID }.map(\.id))
        for index in roots.indices {
            let oldParent = roots[index].parentID
            roots[index].parentID = parentID
            roots[index].branchSide = target.branchSide ?? roots[index].branchSide ?? .right
            if oldParent != parentID {
                let root = roots[index]
                if let edgeIndex = document.edges.firstIndex(where: { $0.targetID == root.id && $0.sourceID == oldParent }) {
                    document.edges[edgeIndex].sourceID = parentID
                } else {
                    document.edges.append(DiagramEdge(sourceID: parentID, targetID: root.id, style: .curved,
                        strokeHex: root.strokeHex, lineWidth: 1.4, showsArrow: false))
                }
            }
        }
        document.nodes.removeAll { rootIDs.contains($0.id) }
        if drop.placement == .child {
            document.nodes.append(contentsOf: roots)
        } else if let index = document.nodes.firstIndex(where: { $0.id == target.id }) {
            document.nodes.insert(contentsOf: roots, at: index + (drop.placement == .after ? 1 : 0))
        }
        // Reparented branches adopt the defaults of their new levels; simple reordering keeps sizes.
        var previousCount = -1
        while previousCount != resizedIDs.count {
            previousCount = resizedIDs.count
            for node in document.nodes where node.parentID.map(resizedIDs.contains) == true {
                resizedIDs.insert(node.id)
            }
        }
        let depths = DiagramMindMapStyle.depths(in: document)
        for index in document.nodes.indices where resizedIDs.contains(document.nodes[index].id) {
            guard let depth = depths[document.nodes[index].id] else { continue }
            document.nodes[index].size = DiagramMindMapStyle.defaultTopicSize(depth: depth)
        }
        Self.applyMindMapLayout(to: &document)
    }

    func updateNode(_ nodeID: UUID, _ mutation: (inout DiagramNode) -> Void) {
        commit { document in
            guard let index = document.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            mutation(&document.nodes[index])
            Self.applyMindMapLayout(to: &document)
        }
    }

    func updateEdge(_ edgeID: UUID, _ mutation: (inout DiagramEdge) -> Void) {
        commit { document in
            guard let index = document.edges.firstIndex(where: { $0.id == edgeID }) else { return }
            mutation(&document.edges[index])
        }
    }

    static func applyMindMapLayout(to document: inout DiagramDocumentData) {
        guard document.kind == .mindMap else { return }
        let depths = DiagramMindMapStyle.depths(in: document)
        for index in document.nodes.indices {
            let node = document.nodes[index]
            document.nodes[index].size.height = max(node.size.height, DiagramTextLayout.requiredHeight(
                text: node.text, width: node.size.width, depth: depths[node.id, default: 0]
            ))
        }
        guard let root = document.nodes.first(where: { $0.parentID == nil }) else { return }
        applyMindMapPresentation(to: &document)
        let children = Dictionary(grouping: document.nodes.filter { $0.parentID != nil }, by: { $0.parentID! })
        var leafCounts: [UUID: Int] = [:]
        func count(_ id: UUID, visited: inout Set<UUID>) -> Int {
            guard visited.insert(id).inserted else { return 1 }
            let result = max(1, (children[id] ?? []).reduce(0) { $0 + count($1.id, visited: &visited) })
            leafCounts[id] = result
            return result
        }
        var visited: Set<UUID> = []
        _ = count(root.id, visited: &visited)

        let rootChildren = children[root.id] ?? []
        var branches: [DiagramBranchSide: [DiagramNode]] = [.left: [], .right: []]
        var branchLoads: [DiagramBranchSide: Int] = [.left: 0, .right: 0]
        for child in rootChildren {
            let side = child.branchSide ?? (
                branchLoads[.left, default: 0] < branchLoads[.right, default: 0] ? .left : .right
            )
            branches[side, default: []].append(child)
            branchLoads[side, default: 0] += leafCounts[child.id, default: 1]
        }

        func assignSide(_ side: DiagramBranchSide, to id: UUID, visited: inout Set<UUID>) {
            guard visited.insert(id).inserted else { return }
            if let index = document.nodes.firstIndex(where: { $0.id == id }) {
                document.nodes[index].branchSide = side
            }
            for child in children[id] ?? [] {
                assignSide(side, to: child.id, visited: &visited)
            }
        }
        for side in [DiagramBranchSide.left, .right] {
            var sideVisited: Set<UUID> = []
            for child in branches[side, default: []] {
                assignSide(side, to: child.id, visited: &sideVisited)
            }
        }

        // Each subtree reserves enough vertical space for all of its descendants.
        let verticalGap = 24.0
        var heights: [UUID: Double] = [:]
        var measuring: Set<UUID> = []
        func measure(_ node: DiagramNode) -> Double {
            if let value = heights[node.id] { return value }
            guard measuring.insert(node.id).inserted else { return node.size.height }
            let descendants = children[node.id] ?? []
            let childrenHeight = descendants.reduce(0.0) { $0 + measure($1) }
                + Double(max(0, descendants.count - 1)) * verticalGap
            let height = max(node.size.height, childrenHeight)
            heights[node.id] = height
            return height
        }
        _ = measure(root)
        var positions: [UUID: DiagramPoint] = [root.id: .init(x: 0, y: 0)]
        var placed: Set<UUID> = [root.id]
        func place(_ node: DiagramNode, parent: DiagramNode, parentX: Double, y: Double, side: DiagramBranchSide) {
            guard placed.insert(node.id).inserted else { return }
            let x = parentX + side.direction * (parent.size.width / 2 + node.size.width / 2 + 56)
            positions[node.id] = .init(x: x, y: y)
            let descendants = children[node.id] ?? []
            let total = descendants.reduce(0.0) { $0 + heights[$1.id, default: $1.size.height] }
                + Double(max(0, descendants.count - 1)) * verticalGap
            var top = y - total / 2
            for child in descendants {
                let height = heights[child.id, default: child.size.height]
                place(child, parent: node, parentX: x, y: top + height / 2, side: side)
                top += height + verticalGap
            }
        }
        for side in [DiagramBranchSide.left, .right] {
            let nodes = branches[side, default: []]
            let total = nodes.reduce(0.0) { $0 + heights[$1.id, default: $1.size.height] }
                + Double(max(0, nodes.count - 1)) * verticalGap
            var top = -total / 2
            for node in nodes {
                let height = heights[node.id, default: node.size.height]
                place(node, parent: root, parentX: 0, y: top + height / 2, side: side)
                top += height + verticalGap
            }
        }
        for index in document.nodes.indices {
            if let position = positions[document.nodes[index].id] { document.nodes[index].center = position }
        }
    }

    static func applyMindMapPresentation(to document: inout DiagramDocumentData) {
        guard document.kind == .mindMap else { return }
        // Preserve saved colors, borders and sizes when opening or arranging a document.
    }

    private static func preferredSideForNewRootBranch(
        in document: DiagramDocumentData,
        rootID: UUID
    ) -> DiagramBranchSide {
        let children = Dictionary(grouping: document.nodes.filter { $0.parentID != nil }, by: { $0.parentID! })
        func leafCount(_ id: UUID, visited: inout Set<UUID>) -> Int {
            guard visited.insert(id).inserted else { return 1 }
            let descendants = children[id] ?? []
            return max(1, descendants.reduce(0) { partial, child in
                partial + leafCount(child.id, visited: &visited)
            })
        }
        var loads: [DiagramBranchSide: Int] = [.left: 0, .right: 0]
        for child in children[rootID] ?? [] {
            var visited: Set<UUID> = []
            let side = child.branchSide ?? (child.center.x < 0 ? .left : .right)
            loads[side, default: 0] += leafCount(child.id, visited: &visited)
        }
        return loads[.left, default: 0] < loads[.right, default: 0] ? .left : .right
    }
}

enum DiagramGeometry {
    static func rect(for node: DiagramNode) -> CGRect {
        CGRect(
            x: node.center.x - node.size.width / 2,
            y: node.center.y - node.size.height / 2,
            width: node.size.width,
            height: node.size.height
        )
    }

    static func documentBounds(_ document: DiagramDocumentData, margin: CGFloat = 56) -> CGRect {
        guard let first = document.nodes.first else { return CGRect(x: 0, y: 0, width: 800, height: 600) }
        var bounds = rect(for: first)
        for node in document.nodes.dropFirst() { bounds = bounds.union(rect(for: node)) }
        return bounds.insetBy(dx: -margin, dy: -margin)
    }

    static func endpoints(source: DiagramNode, target: DiagramNode) -> (CGPoint, CGPoint) {
        if target.parentID == source.id {
            let direction = (target.branchSide ?? (target.center.x < source.center.x ? .left : .right)).direction
            return (
                CGPoint(x: source.center.x + direction * source.size.width / 2, y: source.center.y),
                CGPoint(x: target.center.x - direction * target.size.width / 2, y: target.center.y)
            )
        }
        let from = boundaryPoint(node: source, toward: target.center.cgPoint)
        let to = boundaryPoint(node: target, toward: source.center.cgPoint)
        return (from, to)
    }

    static func boundaryPoint(node: DiagramNode, toward point: CGPoint) -> CGPoint {
        let center = node.center.cgPoint
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard abs(dx) + abs(dy) > 0.001 else { return center }
        let halfWidth = max(CGFloat(1), CGFloat(node.size.width / 2))
        let halfHeight = max(CGFloat(1), CGFloat(node.size.height / 2))
        if node.shape == .ellipse {
            let normalizedX = (dx * dx) / (halfWidth * halfWidth)
            let normalizedY = (dy * dy) / (halfHeight * halfHeight)
            let scale: CGFloat = 1 / sqrt(normalizedX + normalizedY)
            return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
        }
        if node.shape == .diamond {
            let scale: CGFloat = 1 / (abs(dx) / halfWidth + abs(dy) / halfHeight)
            return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
        }
        let scale = min(halfWidth / max(abs(dx), 0.001), halfHeight / max(abs(dy), 0.001))
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }

    static func edgePoints(edge: DiagramEdge, source: DiagramNode, target: DiagramNode) -> [CGPoint] {
        let (start, end) = endpoints(source: source, target: target)
        if edge.style == .curved {
            let controlX = (start.x + end.x) / 2
            let direction = (target.branchSide ?? (target.center.x < source.center.x ? .left : .right)).direction
            let reach = max(40, abs(end.x - start.x) / 2)
            let isBranch = target.parentID == source.id
            let control1 = CGPoint(x: isBranch ? start.x + direction * reach : controlX, y: start.y)
            let control2 = CGPoint(x: isBranch ? end.x - direction * reach : controlX, y: end.y)
            return (0...16).map { step in
                let t = CGFloat(step) / 16
                let inverse = 1 - t
                let startWeight = inverse * inverse * inverse
                let firstControlWeight = 3 * inverse * inverse * t
                let secondControlWeight = 3 * inverse * t * t
                let endWeight = t * t * t
                return CGPoint(
                    x: startWeight * start.x
                        + firstControlWeight * control1.x
                        + secondControlWeight * control2.x
                        + endWeight * end.x,
                    y: startWeight * start.y
                        + firstControlWeight * control1.y
                        + secondControlWeight * control2.y
                        + endWeight * end.y
                )
            }
        }
        guard edge.style == .orthogonal else { return [start, end] }
        if abs(end.x - start.x) >= abs(end.y - start.y) {
            let middleX = (start.x + end.x) / 2
            return [start, CGPoint(x: middleX, y: start.y), CGPoint(x: middleX, y: end.y), end]
        }
        let middleY = (start.y + end.y) / 2
        return [start, CGPoint(x: start.x, y: middleY), CGPoint(x: end.x, y: middleY), end]
    }

    static func distance(from point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return .greatestFiniteMagnitude }
        return zip(points, points.dropFirst()).map { distance(from: point, toSegment: $0, $1) }.min() ?? .greatestFiniteMagnitude
    }

    private static func distance(from point: CGPoint, toSegment start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }
}

extension NSColor {
    convenience init?(diagramHex: String) {
        var value = diagramHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else { return nil }
        if value.count == 8 {
            self.init(
                srgbRed: CGFloat((number >> 24) & 0xFF) / 255,
                green: CGFloat((number >> 16) & 0xFF) / 255,
                blue: CGFloat((number >> 8) & 0xFF) / 255,
                alpha: CGFloat(number & 0xFF) / 255
            )
        } else {
            self.init(
                srgbRed: CGFloat((number >> 16) & 0xFF) / 255,
                green: CGFloat((number >> 8) & 0xFF) / 255,
                blue: CGFloat(number & 0xFF) / 255,
                alpha: 1
            )
        }
    }
}

extension Color {
    init(diagramHex: String) {
        self.init(nsColor: NSColor(diagramHex: diagramHex) ?? .clear)
    }
}
