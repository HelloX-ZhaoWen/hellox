import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DiagramOpenRequest: Equatable {
    let id = UUID()
    let url: URL
}

@MainActor
final class DiagramOpenRouter: ObservableObject {
    @Published private(set) var request: DiagramOpenRequest?
    func open(_ url: URL) { request = DiagramOpenRequest(url: url.standardizedFileURL) }
}

enum DiagramCanvasTool: String, CaseIterable, Identifiable {
    case select
    case pan
    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: "选择"
        case .pan: "移动画布"
        }
    }
}

@MainActor
struct MindMapToolView: View {
    @ObservedObject var openRouter: DiagramOpenRouter
    @ObservedObject var document: DiagramDocumentModel

    var body: some View {
        DiagramToolView(openRouter: openRouter, document: document, moduleKind: .mindMap)
    }
}

@MainActor
struct DiagramToolView: View {
    @ObservedObject var openRouter: DiagramOpenRouter
    @ObservedObject var document: DiagramDocumentModel
    let moduleKind: DiagramKind
    @State private var tool: DiagramCanvasTool = .select
    @State private var selectedNodeIDs: Set<UUID> = []
    @State private var selectedEdgeID: UUID?
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize.zero
    @State private var isSpacePressed = false
    @State private var isInspectorExpanded = true
    @State private var statusMessage = "已就绪"
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                DiagramCanvasView(
                    document: document,
                    tool: $tool,
                    selectedNodeIDs: $selectedNodeIDs,
                    selectedEdgeID: $selectedEdgeID,
                    zoom: $zoom,
                    pan: $pan,
                    isSpacePressed: $isSpacePressed
                )
                if isInspectorExpanded {
                    Divider()
                    DiagramInspectorView(
                        document: document,
                        selectedNodeIDs: $selectedNodeIDs,
                        selectedEdgeID: $selectedEdgeID
                    )
                    .frame(width: 256)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            Divider()
            statusBar
        }
        .background(HelloXTheme.pageBackground(for: colorScheme))
        .background(DiagramKeyEventMonitor(
            onDelete: deleteSelection,
            onUndo: document.undo,
            onRedo: document.redo,
            onAddChild: addMindChild,
            onAddSibling: addMindSibling,
            onSpaceChanged: setSpacePressed
        ))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            setSpacePressed(false)
        }
        .onDisappear { setSpacePressed(false) }
        .onChange(of: openRouter.request) { _, request in
            guard let request else { return }
            openDocument(at: request.url)
        }
    }

    private func setSpacePressed(_ pressed: Bool) {
        guard pressed != isSpacePressed else { return }
        isSpacePressed = pressed
        tool = pressed ? .pan : .select
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("新建\(moduleKind.title)") { newDocument(moduleKind) }
                Divider()
                Button("打开…", action: openDocument)
                Button("保存") { saveDocument() }
                Button("另存为…") { saveDocument(saveAs: true) }
                Divider()
                Button("导出 PNG…") { export(.png) }
                Button("导出 PDF…") { export(.pdf) }
                Button("导出 SVG…") { export(.svg) }
            } label: {
                Label("文件", systemImage: "doc")
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(HelloXButtonStyle(isOutlined: true))
            .fixedSize()

            Text(document.displayName + (document.isModified ? " •" : ""))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)

            Divider().frame(height: 22)

            toolbarButton(icon: .undo, help: "撤销 ⌘Z", enabled: document.canUndo, action: document.undo)
            toolbarButton(icon: .redo, help: "重做 ⇧⌘Z", enabled: document.canRedo, action: document.redo)

            Divider().frame(height: 22)

            ForEach(visibleTools) { item in
                Button {
                    tool = item
                } label: {
                    toolLabel(item)
                }
                .buttonStyle(DiagramToolbarButtonStyle(isSelected: tool == item))
                .help(item.title)
            }

            if document.data.kind == .mindMap {
                Divider().frame(height: 22)
                Button("子主题", action: addMindChild)
                    .buttonStyle(HelloXButtonStyle())
                    .disabled(selectedNodeIDs.count != 1)
                Button("同级主题", action: addMindSibling)
                    .buttonStyle(HelloXButtonStyle())
                    .disabled(selectedNodeIDs.count != 1)
                Button("自动布局", action: document.arrangeMindMap)
                    .buttonStyle(HelloXButtonStyle())
            }

            Spacer(minLength: 8)
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isInspectorExpanded.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(DiagramToolbarButtonStyle(isSelected: isInspectorExpanded))
            .help(isInspectorExpanded ? "收起样式面板" : "展开样式面板")
            .accessibilityLabel(isInspectorExpanded ? "收起样式面板" : "展开样式面板")

            Text(document.data.kind.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(HXTextStyle.secondary)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(HelloXTheme.controlBackground(for: colorScheme), in: Capsule())
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private var visibleTools: [DiagramCanvasTool] {
        return DiagramCanvasTool.allCases
    }

    @ViewBuilder
    private func toolLabel(_ item: DiagramCanvasTool) -> some View {
        switch item {
        case .select: HelloXIcon(icon: .capture, size: 16)
        case .pan: Image(systemName: "hand.draw").frame(width: 16, height: 16)

        }
    }

    private func toolbarButton(icon: HelloXIconKey, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { HelloXIcon(icon: icon, size: 16) }
            .buttonStyle(DiagramToolbarButtonStyle(isSelected: false))
            .disabled(!enabled)
            .help(help)
    }

    private var statusBar: some View {
        HStack {
            Text(statusMessage)
            Spacer()
            Text("\(document.data.nodes.count) 个节点 · \(document.data.edges.count) 条连线")
            Text("\(Int(zoom * 100))%")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(HXTextStyle.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }

    private func newDocument(_ kind: DiagramKind) {
        guard confirmDiscardIfNeeded() else { return }
        document.newDocument(kind: kind)
        selectedNodeIDs.removeAll()
        selectedEdgeID = nil
        tool = .select
        zoom = 1
        pan = .zero
        statusMessage = "已新建\(kind.title)"
    }

    private func openDocument() {
        guard confirmDiscardIfNeeded() else { return }
        let panel = NSOpenPanel()
        panel.title = "打开 HelloX 图表"
        panel.allowedContentTypes = [DiagramFileService.documentType, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openDocument(at: url, alreadyConfirmed: true)
    }

    private func openDocument(at url: URL, alreadyConfirmed: Bool = false) {
        guard alreadyConfirmed || confirmDiscardIfNeeded() else { return }
        do {
            let opened = try DiagramFileService.read(from: url)
            guard opened.kind == moduleKind else {
                throw NSError(
                    domain: "HelloX.DiagramModule",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "这是\(opened.kind.title)文档，请在\(opened.kind.title)模块中打开。"]
                )
            }
            document.replace(with: opened, fileURL: url)
            selectedNodeIDs.removeAll()
            selectedEdgeID = nil
            tool = .select
            statusMessage = "已打开 \(url.lastPathComponent)"
        } catch {
            presentError("无法打开图表", error)
        }
    }

    private func saveDocument(saveAs: Bool = false) {
        var destination = saveAs ? nil : document.fileURL
        if destination == nil {
            let panel = NSSavePanel()
            panel.title = saveAs ? "图表另存为" : "保存图表"
            panel.allowedContentTypes = [DiagramFileService.documentType]
            panel.nameFieldStringValue = document.displayName + ".hxdiagram"
            guard panel.runModal() == .OK else { return }
            destination = panel.url
        }
        guard let destination else { return }
        do {
            try DiagramFileService.write(document.data, to: destination)
            document.markSaved(at: destination)
            statusMessage = "已保存 \(destination.lastPathComponent)"
        } catch {
            presentError("无法保存图表", error)
        }
    }

    private func export(_ format: DiagramExportFormat) {
        let panel = NSSavePanel()
        panel.title = "导出 \(format.rawValue.uppercased())"
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = document.displayName + "." + format.rawValue
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DiagramExporter.write(document.data, format: format, to: url)
            statusMessage = "已导出 \(url.lastPathComponent)"
        } catch {
            presentError("无法导出图表", error)
        }
    }

    private func confirmDiscardIfNeeded() -> Bool {
        guard document.isModified else { return true }
        let alert = NSAlert()
        alert.messageText = "当前图表尚未保存"
        alert.informativeText = "继续后将放弃未保存的更改。"
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = title
        alert.runModal()
    }

    private func deleteSelection() {
        document.delete(nodeIDs: selectedNodeIDs, edgeID: selectedEdgeID)
        selectedNodeIDs.removeAll()
        selectedEdgeID = nil
    }

    private func addMindChild() {
        guard let parent = selectedNodeIDs.first,
              let created = document.addMindNode(parentID: parent) else { return }
        selectedNodeIDs = [created]
        selectedEdgeID = nil
        statusMessage = "已新增子主题"
    }

    private func addMindSibling() {
        guard let node = selectedNodeIDs.first,
              let created = document.addMindSibling(of: node) else { return }
        selectedNodeIDs = [created]
        selectedEdgeID = nil
        statusMessage = "已新增同级主题"
    }
}

private struct DiagramToolbarButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled
                ? HelloXTheme.iconForeground(for: colorScheme)
                : HelloXTheme.disabledForeground(for: colorScheme))
            .frame(width: 28, height: 28)
            .background(
                background(isPressed: configuration.isPressed),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                if isEnabled && isFocused {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(HelloXTheme.focusRing, lineWidth: 2)
                }
            }
            .onHover { isHovered = isEnabled && $0 }
    }

    private func background(isPressed: Bool) -> Color {
        if !isEnabled { return .clear }
        if isPressed { return HelloXTheme.pressedBackground(for: colorScheme) }
        if isSelected { return HelloXTheme.selectedBackground(for: colorScheme) }
        if isHovered { return HelloXTheme.hoverBackground(for: colorScheme) }
        return .clear
    }
}

private struct DiagramCanvasView: View {
    @ObservedObject var document: DiagramDocumentModel
    @Binding var tool: DiagramCanvasTool
    @Binding var selectedNodeIDs: Set<UUID>
    @Binding var selectedEdgeID: UUID?
    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    @Binding var isSpacePressed: Bool

    @State private var dragStartCenters: [UUID: DiagramPoint] = [:]
    @State private var draggingNodeIDs: Set<UUID> = []
    @State private var dropTarget: DiagramDocumentModel.DropTarget?
    @State private var dragTranslation = CGSize.zero
    @State private var draggedNodeID: UUID?
    @State private var resizeStartSize: DiagramSize?
    @State private var resizeStartCenter: DiagramPoint?
    @State private var panStart: CGSize?
    @State private var zoomStart: CGFloat?
    @State private var viewportSize = CGSize.zero
    @State private var isCanvasHovered = false

    var body: some View {
        GeometryReader { proxy in
            let mindMapDepths = DiagramMindMapStyle.depths(in: document.data)
            ZStack {
                DiagramGridView(
                    zoom: zoom,
                    pan: pan,
                    kind: document.data.kind,
                    backgroundHex: document.data.backgroundHex
                )
                    .equatable()
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(backgroundDrag, isEnabled: isPanning)
                    .onTapGesture { location in handleBackgroundTap(location, size: proxy.size) }
                DiagramEdgeLayer(
                    nodes: document.data.nodes,
                    edges: document.data.edges,
                    selectedEdgeID: selectedEdgeID,
                    fadedNodeIDs: draggingNodeIDs,
                    zoom: zoom,
                    pan: pan,
                    size: proxy.size
                )
                .equatable()
                ForEach(document.data.nodes) { node in
                    DiagramNodeView(
                        node: node,
                        scale: zoom,
                        position: screenPoint(node.center.cgPoint, in: proxy.size),
                        isSelected: selectedNodeIDs.contains(node.id),
                        dropPlacement: dropTarget?.nodeID == node.id && dropTarget?.placement == .child ? .child : nil,
                        isMindMap: document.data.kind == .mindMap,
                        mindMapDepth: mindMapDepths[node.id, default: 0],
                        onSelect: { selectNode(node.id) },
                        onMove: { phase, translation in move(node.id, phase: phase, translation: translation) },
                        onResize: { handle, phase, translation in
                            resize(node.id, handle: handle, phase: phase, translation: translation)
                        },
                        onRename: { value in document.updateNode(node.id) { $0.text = value } }
                    )
                    .equatable()
                    .opacity(draggingNodeIDs.contains(node.id) ? 0.3 : 1)
                    .zIndex(1)
                    .allowsHitTesting(!isPanning)
                }
                if !draggingNodeIDs.isEmpty {
                    dragPreview(in: proxy.size, depths: mindMapDepths)
                        .allowsHitTesting(false)
                        .zIndex(3)
                }
            }
            .clipped()
            .simultaneousGesture(MagnificationGesture()
                .onChanged { value in
                    if zoomStart == nil { zoomStart = zoom }
                    zoom = min(3, max(0.25, (zoomStart ?? zoom) * value))
                }
                .onEnded { _ in zoomStart = nil }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isCanvasHovered = true
                    if isPanning { updateCanvasCursor() }
                case .ended:
                    if isCanvasHovered && isPanning { NSCursor.arrow.set() }
                    isCanvasHovered = false
                }
            }
            .onChange(of: isPanning) { _, panning in
                if !panning { panStart = nil }
                if panning {
                    dragStartCenters.removeAll()
                    draggingNodeIDs.removeAll()
                    dropTarget = nil
                    draggedNodeID = nil
                    dragTranslation = .zero
                }
                updateCanvasCursor()
            }
            .onChange(of: panStart) { _, _ in updateCanvasCursor() }
            .onDisappear {
                if isCanvasHovered { NSCursor.arrow.set() }
                isCanvasHovered = false
                panStart = nil
            }
            .onAppear { viewportSize = proxy.size }
            .onChange(of: proxy.size) { _, value in viewportSize = value }
            .overlay(alignment: .bottomTrailing) { zoomControls }
            .background(DiagramScrollEventMonitor { delta, location in
                zoomAround(location: location, delta: delta, viewport: proxy.size)
            })
        }
    }

    private func dragPreview(in size: CGSize, depths: [UUID: Int]) -> some View {
        let ghostNodes = document.data.nodes.filter { draggingNodeIDs.contains($0.id) }.map { node in
            var ghost = node
            ghost.center.x += dragTranslation.width / zoom
            ghost.center.y += dragTranslation.height / zoom
            return ghost
        }
        let preview = dropTarget.map { document.previewMindMove(draggingNodeIDs, to: $0) }
        let landing = preview?.nodes.first { $0.id == draggedNodeID }
        return ZStack {
            DiagramEdgeLayer(nodes: ghostNodes,
                edges: document.data.edges.filter { draggingNodeIDs.contains($0.sourceID) && draggingNodeIDs.contains($0.targetID) },
                selectedEdgeID: nil, zoom: zoom, pan: pan, size: size)
                .opacity(0.55)
            ForEach(ghostNodes) { node in
                DiagramNodeView(node: node, scale: zoom,
                    position: screenPoint(node.center.cgPoint, in: size),
                    isSelected: false, dropPlacement: nil,
                    isMindMap: true, mindMapDepth: depths[node.id, default: 0],
                    onSelect: {}, onMove: { _, _ in }, onResize: { _, _, _ in }, onRename: { _ in })
                    .opacity(0.65)
            }
            if let landing {
                Canvas { context, _ in
                    let slot = screenPoint(landing.center.cgPoint, in: size)
                    let side = landing.branchSide?.direction ?? 1
                    let innerX = slot.x - side * landing.size.width / 2 * zoom
                    let marker = CGRect(x: innerX - side * 26 * zoom - 16 * zoom,
                        y: slot.y - 6 * zoom, width: 32 * zoom, height: 12 * zoom)
                    context.fill(Path(roundedRect: marker, cornerRadius: 4 * zoom), with: .color(.cyan))

                }
            }
        }
    }

    private func updateCanvasCursor() {
        guard isCanvasHovered else { return }
        if isPanning {
            (panStart == nil ? NSCursor.openHand : NSCursor.closedHand).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard isPanning else { return }
                if panStart == nil { panStart = pan }
                let start = panStart ?? .zero
                pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }
            .onEnded { _ in panStart = nil }
    }

    private var isPanning: Bool { tool == .pan || isSpacePressed }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { zoom = max(0.25, zoom / 1.15) } label: {
                Image(systemName: "minus").frame(width: 14, height: 14)
            }
            .buttonStyle(DiagramToolbarButtonStyle(isSelected: false))
            Button(action: fitDocument) {
                Text("\(Int(zoom * 100))%")
                    .font(HXTypography.caption)
                    .frame(width: 48, height: 28)
            }
            .buttonStyle(HelloXButtonStyle(isOutlined: true))
            Button { zoom = min(3, zoom * 1.15) } label: {
                Image(systemName: "plus").frame(width: 14, height: 14)
            }
            .buttonStyle(DiagramToolbarButtonStyle(isSelected: false))
        }
        .padding(5)
        .background(HelloXTheme.raisedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(HelloXTheme.border(for: colorScheme), lineWidth: 1)
        }
        .shadow(color: HelloXTheme.shadow(for: colorScheme), radius: 8, y: 3)
        .padding(12)
    }

    @Environment(\.colorScheme) private var colorScheme

    private func handleBackgroundTap(_ location: CGPoint, size: CGSize) {
        guard !isPanning else { return }
        endInlineTextEditing()
        let world = worldPoint(location, in: size)
        if tool == .select, let edge = edge(at: world) {
            selectedNodeIDs.removeAll()
            selectedEdgeID = edge.id
        } else if tool == .select {
            selectedNodeIDs.removeAll()
            selectedEdgeID = nil
        }
    }

    private func selectNode(_ id: UUID) {
        endInlineTextEditing()
        guard tool == .select else { return }
        if NSEvent.modifierFlags.contains(.shift) {
            if selectedNodeIDs.contains(id) { selectedNodeIDs.remove(id) } else { selectedNodeIDs.insert(id) }
        } else if !selectedNodeIDs.contains(id) {
            selectedNodeIDs = [id]
        }
        selectedEdgeID = nil
    }

    private func endInlineTextEditing() {
        guard let window = NSApp.keyWindow else { return }
        window.makeFirstResponder(nil)
    }

    private func move(_ id: UUID, phase: DiagramGesturePhase, translation: CGSize) {
        guard tool == .select else { return }
        if phase == .began {
            guard selectedNodeIDs.contains(id),
                  document.data.nodes.first(where: { $0.id == id })?.parentID != nil else { return }
            draggedNodeID = id
            draggingNodeIDs = document.movingNodeIDs(for: selectedNodeIDs)
            dragStartCenters = Dictionary(uniqueKeysWithValues: document.data.nodes
                .filter { draggingNodeIDs.contains($0.id) }.map { ($0.id, $0.center) })
        }
        guard let start = dragStartCenters[id] else { return }
        dragTranslation = translation
        let point = CGPoint(x: start.x + translation.width / zoom, y: start.y + translation.height / zoom)
        dropTarget = document.dropTarget(for: draggingNodeIDs, at: point)
        if phase == .ended {
            if let target = dropTarget { document.moveMindNodes(draggingNodeIDs, to: target) }
            dragStartCenters.removeAll()
            draggingNodeIDs.removeAll()
            dropTarget = nil
            draggedNodeID = nil
            dragTranslation = .zero
        }
    }

    private func resize(
        _ id: UUID,
        handle: DiagramResizeHandle,
        phase: DiagramGesturePhase,
        translation: CGSize
    ) {
        guard let node = document.data.nodes.first(where: { $0.id == id }) else { return }
        if phase == .began {
            resizeStartSize = node.size
            resizeStartCenter = node.center
        }
        if phase == .ended, let startSize = resizeStartSize, let startCenter = resizeStartCenter {
            let dx = Double(translation.width / zoom)
            let dy = Double(translation.height / zoom)
            var size = startSize
            var center = startCenter
            switch handle {
            case .left:
                size.width = max(70, startSize.width - dx)
                center.x = startCenter.x - (size.width - startSize.width) / 2
            case .right:
                size.width = max(70, startSize.width + dx)
                center.x = startCenter.x + (size.width - startSize.width) / 2
            case .top:
                size.height = max(36, startSize.height - dy)
                center.y = startCenter.y - (size.height - startSize.height) / 2
            case .bottom:
                size.height = max(36, startSize.height + dy)
                center.y = startCenter.y + (size.height - startSize.height) / 2
            }
            document.commit { value in
                guard let index = value.nodes.firstIndex(where: { $0.id == id }) else { return }
                value.nodes[index].size = size
                value.nodes[index].center = center
                DiagramDocumentModel.applyMindMapLayout(to: &value)
            }
            resizeStartSize = nil
            resizeStartCenter = nil
        }
    }

    private func zoomAround(location: CGPoint, delta: CGFloat, viewport: CGSize) {
        let oldZoom = zoom
        let limitedDelta = min(50, max(-50, delta))
        let newZoom = min(3, max(0.25, oldZoom * exp(limitedDelta * 0.015)))
        guard abs(newZoom - oldZoom) > 0.0001 else { return }
        let worldX = (location.x - viewport.width / 2 - pan.width) / oldZoom
        let worldY = (location.y - viewport.height / 2 - pan.height) / oldZoom
        pan = CGSize(
            width: location.x - viewport.width / 2 - worldX * newZoom,
            height: location.y - viewport.height / 2 - worldY * newZoom
        )
        zoom = newZoom
    }

    private func edge(at point: CGPoint) -> DiagramEdge? {
        let lookup = Dictionary(uniqueKeysWithValues: document.data.nodes.map { ($0.id, $0) })
        return document.data.edges.first { edge in
            guard let source = lookup[edge.sourceID], let target = lookup[edge.targetID] else { return false }
            return DiagramGeometry.distance(
                from: point,
                toPolyline: DiagramGeometry.edgePoints(edge: edge, source: source, target: target)
            ) <= 8 / zoom
        }
    }

    private func fitDocument() {
        let bounds = DiagramGeometry.documentBounds(document.data)
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        zoom = min(2, max(0.25, min(viewportSize.width / bounds.width, viewportSize.height / bounds.height) * 0.9))
        pan = CGSize(width: -bounds.midX * zoom, height: -bounds.midY * zoom)
    }

    private func screenPoint(_ world: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2 + pan.width + world.x * zoom, y: size.height / 2 + pan.height + world.y * zoom)
    }

    private func worldPoint(_ screen: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (screen.x - size.width / 2 - pan.width) / zoom, y: (screen.y - size.height / 2 - pan.height) / zoom)
    }
}

private struct DiagramEdgeLayer: View, Equatable {
    let nodes: [DiagramNode]
    let edges: [DiagramEdge]
    let selectedEdgeID: UUID?
    var fadedNodeIDs: Set<UUID> = []
    let zoom: CGFloat
    let pan: CGSize
    let size: CGSize

    var body: some View {
        Canvas { context, _ in
            let lookup = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
            for edge in edges {
                guard let source = lookup[edge.sourceID], let target = lookup[edge.targetID] else { continue }
                let worldPoints = DiagramGeometry.edgePoints(edge: edge, source: source, target: target)
                let points = worldPoints.map(screenPoint)
                var path = Path()
                if let first = points.first {
                    path.move(to: first)
                    for point in points.dropFirst() { path.addLine(to: point) }
                }
                let selected = selectedEdgeID == edge.id
                let baseColor = selected ? HelloXTheme.accent : Color(diagramHex: edge.strokeHex)
                let color = baseColor.opacity(fadedNodeIDs.contains(edge.sourceID) || fadedNodeIDs.contains(edge.targetID) ? 0.25 : 1)
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(
                        lineWidth: edge.lineWidth * zoom,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                if edge.showsArrow, points.count >= 2 {
                    let arrow = arrowPath(
                        from: points[points.count - 2],
                        to: points[points.count - 1],
                        size: 8 * zoom
                    )
                    context.fill(arrow, with: .color(color))
                }
                if !edge.label.isEmpty, let middle = points[safe: points.count / 2] {
                    context.draw(
                        Text(edge.label)
                            .font(.system(size: 11 * zoom))
                            .foregroundColor(color),
                        at: CGPoint(x: middle.x, y: middle.y - 10 * zoom)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func screenPoint(_ world: CGPoint) -> CGPoint {
        CGPoint(
            x: size.width / 2 + pan.width + world.x * zoom,
            y: size.height / 2 + pan.height + world.y * zoom
        )
    }
}

private enum DiagramGesturePhase { case began, changed, ended }
private enum DiagramResizeHandle { case top, bottom, left, right }

private struct DiagramNodeView: View, Equatable {
    let node: DiagramNode
    let scale: CGFloat
    let position: CGPoint
    let isSelected: Bool
    let dropPlacement: DiagramDocumentModel.DropPlacement?
    let isMindMap: Bool
    let mindMapDepth: Int
    let onSelect: () -> Void
    let onMove: (DiagramGesturePhase, CGSize) -> Void
    let onResize: (DiagramResizeHandle, DiagramGesturePhase, CGSize) -> Void
    let onRename: (String) -> Void

    @State private var didBeginMove = false
    @State private var activeResizeHandle: DiagramResizeHandle?
    @GestureState private var resizePreview = CGSize.zero
    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var textFocused: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.node == rhs.node
            && lhs.scale == rhs.scale
            && lhs.position == rhs.position
            && lhs.isSelected == rhs.isSelected
            && lhs.dropPlacement == rhs.dropPlacement
            && lhs.isMindMap == rhs.isMindMap
            && lhs.mindMapDepth == rhs.mindMapDepth
    }

    var body: some View {
        ZStack {
            DiagramNodeShapeView(shape: node.shape)
                .fill(Color(diagramHex: node.fillHex))
                .overlay {
                    DiagramNodeShapeView(shape: node.shape)
                        .stroke(
                            isSelected ? HelloXTheme.accent : Color(diagramHex: node.strokeHex),
                            style: StrokeStyle(lineWidth: (isSelected ? 2 : node.lineWidth))
                        )
                }
                .allowsHitTesting(false)
            if isEditing {
                TextEditor(text: $editText)
                    .scrollContentBackground(.hidden)
                    .scrollDisabled(true)
                    .foregroundStyle(Color(diagramHex: node.textHex))
                    .multilineTextAlignment(.center)
                    .font(.system(
                        size: (isMindMap ? DiagramMindMapStyle.fontSize(depth: mindMapDepth) : 13),
                        weight: isMindMap ? DiagramMindMapStyle.fontWeight(depth: mindMapDepth) : .medium
                    ))
                    .frame(height: DiagramTextLayout.requiredHeight(
                        text: editText, width: node.size.width, depth: mindMapDepth
                    ) - 16)
                    .padding(8)
                    .focused($textFocused)
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        finishEditing()
                        return .handled
                    }
                    .onChange(of: editText) { _, value in
                        if isEditing { onRename(value) }
                    }
                    .onChange(of: textFocused) { _, focused in if !focused { finishEditing() } }
            } else {
                Text(node.text)
                    .font(.system(
                        size: (isMindMap ? DiagramMindMapStyle.fontSize(depth: mindMapDepth) : 13),
                        weight: isMindMap ? DiagramMindMapStyle.fontWeight(depth: mindMapDepth) : .medium
                    ))
                    .foregroundStyle(Color(diagramHex: node.textHex))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .textSelection(.disabled)
                    .allowsHitTesting(false)
            }
            if isSelected && !isEditing && !didBeginMove {
                resizeHandle(.top, alignment: .top)
                resizeHandle(.bottom, alignment: .bottom)
                resizeHandle(.left, alignment: .leading)
                resizeHandle(.right, alignment: .trailing)
            }
        }
        .frame(
            width: previewSize.width / scale,
            height: previewSize.height / scale
        )
        .overlay(alignment: dropPlacement == .before ? .top : .bottom) {
            if let placement = dropPlacement {
                if placement == .child {
                    RoundedRectangle(cornerRadius: 8).stroke(Color.cyan, lineWidth: 3)
                } else {
                    Rectangle().fill(Color.orange).frame(height: 3)
                        .offset(y: placement == .before ? -6 : 6)
                }
            }
        }
        .scaleEffect(scale)
        .frame(width: previewSize.width, height: previewSize.height)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                editText = node.text
                isEditing = true
                DispatchQueue.main.async { textFocused = true }
            }
        }
        .highPriorityGesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if !didBeginMove {
                    didBeginMove = true
                    onMove(.began, .zero)
                }
                let translation = CGSize(
                    width: value.location.x - value.startLocation.x,
                    height: value.location.y - value.startLocation.y
                )
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { onMove(.changed, translation) }
            }
            .onEnded { value in
                let translation = CGSize(
                    width: value.location.x - value.startLocation.x,
                    height: value.location.y - value.startLocation.y
                )
                onMove(.ended, translation)
                didBeginMove = false
            }, including: isEditing ? .none : .all)
        .shadow(
            color: .black.opacity(node.shape == .text || isMindMap || didBeginMove ? 0 : 0.05),
            radius: 3,
            y: 1
        )
        .position(
            x: position.x + resizePreviewOffset.width,
            y: position.y + resizePreviewOffset.height
        )
        .transaction { $0.disablesAnimations = true }
    }

    private var previewSize: CGSize {
        let baseWidth = CGFloat(node.size.width) * scale
        let baseHeight = CGFloat(node.size.height) * scale
        var width = baseWidth
        var height = baseHeight
        switch activeResizeHandle {
        case .left: width = max(70 * scale, baseWidth - resizePreview.width)
        case .right: width = max(70 * scale, baseWidth + resizePreview.width)
        case .top: height = max(36 * scale, baseHeight - resizePreview.height)
        case .bottom: height = max(36 * scale, baseHeight + resizePreview.height)
        case nil: break
        }
        return CGSize(width: max(1, width), height: max(1, height))
    }

    private var resizePreviewOffset: CGSize {
        let widthDelta = previewSize.width - CGFloat(node.size.width) * scale
        let heightDelta = previewSize.height - CGFloat(node.size.height) * scale
        switch activeResizeHandle {
        case .left: return CGSize(width: -widthDelta / 2, height: 0)
        case .right: return CGSize(width: widthDelta / 2, height: 0)
        case .top: return CGSize(width: 0, height: -heightDelta / 2)
        case .bottom: return CGSize(width: 0, height: heightDelta / 2)
        case nil: return .zero
        }
    }

    private func resizeHandle(
        _ handle: DiagramResizeHandle,
        alignment: Alignment
    ) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(HelloXTheme.accent, lineWidth: 1.25))
            .frame(width: 8, height: 8)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .offset(resizeHandleOffset(handle))
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating($resizePreview) { value, preview, transaction in
                    transaction.animation = nil
                    preview = value.translation
                }
                .onChanged { value in
                    if activeResizeHandle == nil {
                        activeResizeHandle = handle
                        onResize(handle, .began, .zero)
                    }
                    guard activeResizeHandle == handle else { return }
                }
                .onEnded { value in
                    guard activeResizeHandle == handle else { return }
                    let finalTranslation = value.translation
                    activeResizeHandle = nil
                    onResize(handle, .ended, finalTranslation)
                })
    }

    private func resizeHandleOffset(_ handle: DiagramResizeHandle) -> CGSize {
        switch handle {
        case .top: CGSize(width: 0, height: -12)
        case .bottom: CGSize(width: 0, height: 12)
        case .left: CGSize(width: -12, height: 0)
        case .right: CGSize(width: 12, height: 0)
        }
    }

    private func finishEditing() {
        guard isEditing else { return }
        isEditing = false
        onRename(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "节点" : editText)
    }
}

private struct DiagramNodeShapeView: Shape {
    let shape: DiagramNodeShape
    func path(in rect: CGRect) -> Path {
        switch shape {
        case .rectangle, .text: return Path(rect)
        case .roundedRectangle: return RoundedRectangle(cornerRadius: min(14, rect.height / 4), style: .continuous).path(in: rect)
        case .ellipse: return Ellipse().path(in: rect)
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        }
    }
}

private struct DiagramGridView: View, Equatable {
    let zoom: CGFloat
    let pan: CGSize
    let kind: DiagramKind
    let backgroundHex: String

    var body: some View {
        Canvas(opaque: true, colorMode: .nonLinear, rendersAsynchronously: false) { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(diagramHex: backgroundHex))
            )
            let spacing = max(12, 24 * zoom)
            let originX = (size.width / 2 + pan.width).truncatingRemainder(dividingBy: spacing)
            let originY = (size.height / 2 + pan.height).truncatingRemainder(dividingBy: spacing)
            if kind == .mindMap {
                var x = originX
                while x < size.width {
                    var y = originY
                    while y < size.height {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x - 0.65, y: y - 0.65, width: 1.3, height: 1.3)),
                            with: .color(.secondary.opacity(0.16))
                        )
                        y += spacing
                    }
                    x += spacing
                }
                return
            }
            var path = Path()
            var x = originX
            while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
            var y = originY
            while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
            context.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

private struct DiagramInspectorView: View {
    @ObservedObject var document: DiagramDocumentModel
    @Binding var selectedNodeIDs: Set<UUID>
    @Binding var selectedEdgeID: UUID?
    @Environment(\.colorScheme) private var colorScheme

    private let fills = ["#FFFFFF", "#E8F3FF", "#EAF8EF", "#FFF3D6", "#FDECEC", "#F3ECFF"]
    private let strokes = ["#667085", "#1677FF", "#2E9B55", "#D97706", "#D64545", "#7A4BB7"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("样式与属性")
                    .font(HXTypography.section)
                    .foregroundStyle(HXTextStyle.primary)
                if selectedNodeIDs.count == 1, let id = selectedNodeIDs.first,
                   let node = document.data.nodes.first(where: { $0.id == id }) {
                    nodeInspector(node)
                } else if let edgeID = selectedEdgeID,
                          let edge = document.data.edges.first(where: { $0.id == edgeID }) {
                    edgeInspector(edge)
                } else if selectedNodeIDs.count > 1 {
                    Text("已选择 \(selectedNodeIDs.count) 个节点")
                        .foregroundStyle(HXTextStyle.secondary)
                } else {
                    documentInspector
                }
            }
            .padding(16)
        }
        .background(HelloXTheme.surface(for: colorScheme))
    }

    private func nodeInspector(_ node: DiagramNode) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            inspectorField("文字") {
                TextEditor(text: Binding(
                    get: { node.text },
                    set: { value in document.updateNode(node.id) { $0.text = value } }
                ))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 72)
                    .modifier(DiagramTextFieldChrome(minHeight: 54))
            }
            inspectorField("形状") {
                HXDropdown("形状", selection: Binding(
                    get: { node.shape },
                    set: { value in document.updateNode(node.id) { $0.shape = value } }
                ), options: DiagramNodeShape.allCases.map { HXDropdownOption($0, $0.title) },
                menuWidth: 224, triggerWidth: 224)
            }
            inspectorField("填充") { palette(fills, selected: node.fillHex) { value in document.updateNode(node.id) { $0.fillHex = value } } }
            inspectorField("边框") { palette(strokes, selected: node.strokeHex) { value in document.updateNode(node.id) { $0.strokeHex = value } } }
            inspectorField("文字颜色") { palette(["#172B4D", "#344054", "#1677FF", "#2E9B55", "#D64545", "#7A4BB7"], selected: node.textHex) { value in document.updateNode(node.id) { $0.textHex = value } } }
            inspectorField("边框粗细") {
                HStack {
                    Slider(value: Binding(
                        get: { node.lineWidth },
                        set: { value in document.updateNode(node.id) { $0.lineWidth = value } }
                    ), in: 0.5...5, step: 0.5)
                    Text(String(format: "%.1f", node.lineWidth)).frame(width: 28)
                }
            }
            inspectorField("尺寸") {
                HStack {
                    Text("W")
                    TextField("", value: Binding(
                        get: { Int(node.size.width) },
                        set: { value in document.updateNode(node.id) { $0.size.width = Double(max(70, value)) } }
                    ), format: .number)
                        .modifier(DiagramTextFieldChrome(minHeight: 28))
                        .frame(width: 58)
                    Text("H")
                    TextField("", value: Binding(
                        get: { Int(node.size.height) },
                        set: { value in document.updateNode(node.id) { $0.size.height = Double(max(36, value)) } }
                    ), format: .number)
                        .modifier(DiagramTextFieldChrome(minHeight: 28))
                        .frame(width: 58)
                }
            }
        }
    }

    private func edgeInspector(_ edge: DiagramEdge) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            inspectorField("标签") {
                TextField("可选标签", text: Binding(
                    get: { edge.label },
                    set: { value in document.updateEdge(edge.id) { $0.label = value } }
                ))
                .modifier(DiagramTextFieldChrome(minHeight: 32))
            }
            inspectorField("线型") {
                HXSegmentedControl("线型", selection: Binding(
                    get: { edge.style },
                    set: { value in document.updateEdge(edge.id) { $0.style = value } }
                ), options: DiagramEdgeStyle.allCases.map { HXSegment($0, $0.title) })
            }
            inspectorField("颜色") { palette(strokes, selected: edge.strokeHex) { value in document.updateEdge(edge.id) { $0.strokeHex = value } } }
            inspectorField("粗细") {
                HStack {
                    Slider(value: Binding(
                        get: { edge.lineWidth },
                        set: { value in document.updateEdge(edge.id) { $0.lineWidth = value } }
                    ), in: 0.5...5, step: 0.5)
                    Text(String(format: "%.1f", edge.lineWidth)).frame(width: 28)
                }
            }
            Toggle("显示箭头", isOn: Binding(
                get: { edge.showsArrow },
                set: { value in document.updateEdge(edge.id) { $0.showsArrow = value } }
            ))
            .toggleStyle(HXSwitchStyle())
        }
    }

    private var documentInspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("选中节点或连线后可编辑样式。")
                .font(.system(size: 12))
                .foregroundStyle(HXTextStyle.secondary)
            inspectorField("文档标题") {
                TextField("图表标题", text: Binding(
                    get: { document.data.title },
                    set: { value in document.commit { $0.title = value } }
                ))
                .modifier(DiagramTextFieldChrome(minHeight: 32))
            }
            inspectorField("画布背景") {
                palette(["#FFFFFF", "#F7F8FA", "#F5F7FC", "#FFFDF6"], selected: document.data.backgroundHex) {
                    value in document.commit { $0.backgroundHex = value }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("快捷键").font(.system(size: 11, weight: .medium))
                Text("选择主题后拖动：调整顺序\n蓝色标记：插入位置；外侧：接入为子主题\n拖到空白处：取消移动\n拖动画布：按住空格拖动\n缩放画布：Control + 滚动\n删除：Delete\n撤销 / 重做：⌘Z / ⇧⌘Z\n脑图子节点：Tab\n脑图同级节点：Enter")
                    .font(.system(size: 11))
                    .foregroundStyle(HXTextStyle.secondary)
            }
        }
    }

    private func inspectorField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(HXTypography.caption).foregroundStyle(HXTextStyle.secondary)
            content()
        }
    }

    private func palette(_ colors: [String], selected: String, action: @escaping (String) -> Void) -> some View {
        HStack(spacing: 7) {
            ForEach(colors, id: \.self) { value in
                Button { action(value) } label: {
                    Circle()
                        .fill(Color(diagramHex: value))
                        .overlay(Circle().stroke(selected == value ? HelloXTheme.accent : Color.secondary.opacity(0.35), lineWidth: selected == value ? 2 : 1))
                        .frame(width: 23, height: 23)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct DiagramTextFieldChrome: ViewModifier {
    let minHeight: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(HXTypography.body)
            .foregroundStyle(HXTextStyle.primary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background(
                HelloXTheme.raisedSurface(for: colorScheme),
                in: RoundedRectangle(cornerRadius: HelloXTheme.controlRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: HelloXTheme.controlRadius, style: .continuous)
                    .strokeBorder(HelloXTheme.border(for: colorScheme), lineWidth: 1)
            }
    }
}

private struct DiagramKeyEventMonitor: NSViewRepresentable {
    let onDelete: () -> Void
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onAddChild: () -> Void
    let onAddSibling: () -> Void
    let onSpaceChanged: (Bool) -> Void

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) { update(nsView) }

    private func update(_ view: KeyView) {
        view.handler = { event in
            if event.keyCode == 49 {
                if event.type == .keyUp {
                    onSpaceChanged(false)
                    return !(event.window?.firstResponder is NSTextView)
                }
                if event.window?.firstResponder is NSTextView { return false }
                onSpaceChanged(true)
                return true
            }
            if event.window?.firstResponder is NSTextView { return false }
            guard event.type == .keyDown else { return false }
            let command = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            if event.keyCode == 51 || event.keyCode == 117 { onDelete(); return true }
            if command, event.charactersIgnoringModifiers == "z" { shift ? onRedo() : onUndo(); return true }
            if event.keyCode == 48 { onAddChild(); return true }
            if event.keyCode == 36 { onAddSibling(); return true }
            return false
        }
    }

    final class KeyView: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            guard window != nil else { monitor = nil; return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                return self.handler?(event) == true ? nil : event
            }
        }
    }
}

private struct DiagramScrollEventMonitor: NSViewRepresentable {
    let onControlScroll: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> ScrollView {
        let view = ScrollView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: ScrollView, context: Context) { update(nsView) }

    private func update(_ view: ScrollView) {
        view.handler = onControlScroll
    }

    final class ScrollView: NSView {
        var handler: ((CGFloat, CGPoint) -> Void)?
        private var monitor: Any?
        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            guard window != nil else { monitor = nil; return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      event.window === self.window,
                      event.modifierFlags.contains(.control)
                else { return event }
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(location) else { return event }
                self.handler?(event.scrollingDeltaY, location)
                return nil
            }
        }
    }
}

enum DiagramFileService {
    static let documentType = UTType(exportedAs: "com.hellox.diagram", conformingTo: .json)

    static func read(from url: URL) throws -> DiagramDocumentData {
        let data = try Data(contentsOf: url)
        struct Header: Decodable { let kind: String }
        guard try JSONDecoder().decode(Header.self, from: data).kind == DiagramKind.mindMap.rawValue else {
            throw NSError(domain: "HelloX.Diagram", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "当前版本仅支持脑图文档。"])
        }
        let value = try JSONDecoder().decode(DiagramDocumentData.self, from: data)
        guard value.version == 1 else {
            throw NSError(domain: "HelloX.Diagram", code: 2, userInfo: [NSLocalizedDescriptionKey: "不支持该图表文档版本。"])
        }
        return value
    }

    static func write(_ document: DiagramDocumentData, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}

enum DiagramExportFormat: String {
    case png, pdf, svg
    var contentType: UTType {
        switch self {
        case .png: .png
        case .pdf: .pdf
        case .svg: .svg
        }
    }
}

@MainActor
enum DiagramExporter {
    static func write(_ document: DiagramDocumentData, format: DiagramExportFormat, to url: URL) throws {
        switch format {
        case .png: try pngData(document).write(to: url, options: .atomic)
        case .pdf: try pdfData(document).write(to: url, options: .atomic)
        case .svg: try svg(document).data(using: .utf8)!.write(to: url, options: .atomic)
        }
    }

    static let pngScale: CGFloat = 4

    static func pngData(_ document: DiagramDocumentData) throws -> Data {
        let bounds = DiagramGeometry.documentBounds(document).integral
        let pixelWidth = bounds.width * pngScale
        let pixelHeight = bounds.height * pngScale
        guard pixelWidth.isFinite, pixelHeight.isFinite,
              pixelWidth > 0, pixelHeight > 0, pixelWidth * pixelHeight <= 100_000_000 else {
            throw exportError("画布超出高清 PNG 导出尺寸，请使用 SVG 或 PDF 导出。")
        }
        // Render at the target pixel density directly, never enlarge a screen capture.
        let renderer = ImageRenderer(content: DiagramExportSurface(document: document, bounds: bounds)
            .environment(\.displayScale, pngScale)
            .environment(\.colorScheme, .light))
        renderer.scale = pngScale
        guard let image = renderer.cgImage else {
            throw exportError("无法创建高清 PNG 画布。")
        }
        let representation = NSBitmapImageRep(cgImage: image)
        representation.size = bounds.size
        guard let data = representation.representation(using: .png, properties: [:]) else {
            throw exportError("无法编码 PNG 图像。")
        }
        return data
    }

    static func pdfData(_ document: DiagramDocumentData) throws -> Data {
        let (view, _) = hostingView(document)
        return view.dataWithPDF(inside: view.bounds)
    }

    static func svg(_ document: DiagramDocumentData) -> String {
        let bounds = DiagramGeometry.documentBounds(document)
        let offsetX = -bounds.minX
        let offsetY = -bounds.minY
        let lookup = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        let mindMapDepths = DiagramMindMapStyle.depths(in: document)
        var output = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(bounds.width))" height="\(Int(bounds.height))" viewBox="0 0 \(bounds.width) \(bounds.height)">
        <rect width="100%" height="100%" fill="\(document.backgroundHex)"/>
        <defs><marker id="arrow" markerWidth="8" markerHeight="8" refX="7" refY="4" orient="auto"><path d="M0,0 L8,4 L0,8 Z" fill="context-stroke"/></marker></defs>
        """
        for edge in document.edges {
            guard let source = lookup[edge.sourceID], let target = lookup[edge.targetID] else { continue }
            let edgePoints = DiagramGeometry.edgePoints(edge: edge, source: source, target: target)
            let pointsAttribute = edgePoints.map { "\($0.x + offsetX),\($0.y + offsetY)" }.joined(separator: " ")
            output += "<polyline points=\"\(pointsAttribute)\" fill=\"none\" stroke=\"\(edge.strokeHex)\" stroke-width=\"\(edge.lineWidth)\" stroke-linejoin=\"round\" marker-end=\"\(edge.showsArrow ? "url(#arrow)" : "")\"/>\n"
            if !edge.label.isEmpty, let labelPoint = edgePoints[safe: edgePoints.count / 2] {
                output += "<text x=\"\(labelPoint.x + offsetX)\" y=\"\(labelPoint.y + offsetY - 8)\" fill=\"\(edge.strokeHex)\" text-anchor=\"middle\" font-family=\"-apple-system, sans-serif\" font-size=\"11\">\(xmlEscape(edge.label))</text>\n"
            }
        }
        for node in document.nodes {
            let rect = DiagramGeometry.rect(for: node).offsetBy(dx: offsetX, dy: offsetY)
            let depth = mindMapDepths[node.id, default: 0]
            let fontSize = document.kind == .mindMap ? DiagramMindMapStyle.fontSize(depth: depth) : 13
            let fontWeight = document.kind == .mindMap ? (depth == 0 ? 700 : (depth == 1 ? 600 : 500)) : 500
            let common = "fill=\"\(node.fillHex)\" stroke=\"\(node.strokeHex)\" stroke-width=\"\(node.lineWidth)\""
            switch node.shape {
            case .rectangle, .text:
                output += "<rect x=\"\(rect.minX)\" y=\"\(rect.minY)\" width=\"\(rect.width)\" height=\"\(rect.height)\" \(common)/>\n"
            case .roundedRectangle:
                output += "<rect x=\"\(rect.minX)\" y=\"\(rect.minY)\" width=\"\(rect.width)\" height=\"\(rect.height)\" rx=\"14\" \(common)/>\n"
            case .ellipse:
                output += "<ellipse cx=\"\(rect.midX)\" cy=\"\(rect.midY)\" rx=\"\(rect.width / 2)\" ry=\"\(rect.height / 2)\" \(common)/>\n"
            case .diamond:
                output += "<polygon points=\"\(rect.midX),\(rect.minY) \(rect.maxX),\(rect.midY) \(rect.midX),\(rect.maxY) \(rect.minX),\(rect.midY)\" \(common)/>\n"
            }
            output += "<text x=\"\(rect.midX)\" y=\"\(rect.midY)\" fill=\"\(node.textHex)\" text-anchor=\"middle\" dominant-baseline=\"middle\" font-family=\"-apple-system, sans-serif\" font-size=\"\(fontSize)\" font-weight=\"\(fontWeight)\">\(xmlEscape(node.text))</text>\n"
        }
        return output + "</svg>\n"
    }

    private static func hostingView(_ document: DiagramDocumentData) -> (NSHostingView<DiagramExportSurface>, CGRect) {
        let bounds = DiagramGeometry.documentBounds(document)
        let view = NSHostingView(rootView: DiagramExportSurface(document: document, bounds: bounds))
        view.frame = CGRect(origin: .zero, size: bounds.size)
        view.layoutSubtreeIfNeeded()
        return (view, bounds)
    }

    private static func xmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func exportError(_ message: String) -> NSError {
        NSError(domain: "HelloX.DiagramExport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private struct DiagramExportSurface: View {
    let document: DiagramDocumentData
    let bounds: CGRect
    var body: some View {
        let mindMapDepths = DiagramMindMapStyle.depths(in: document)
        ZStack {
            Color(diagramHex: document.backgroundHex)
            Canvas { context, _ in
                let lookup = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
                for edge in document.edges {
                    guard let source = lookup[edge.sourceID], let target = lookup[edge.targetID] else { continue }
                    let points = DiagramGeometry.edgePoints(edge: edge, source: source, target: target)
                        .map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) }
                    var path = Path()
                    if let first = points.first { path.move(to: first); for point in points.dropFirst() { path.addLine(to: point) } }
                    context.stroke(path, with: .color(Color(diagramHex: edge.strokeHex)), style: StrokeStyle(lineWidth: edge.lineWidth, lineCap: .round, lineJoin: .round))
                    if edge.showsArrow, points.count >= 2 {
                        context.fill(arrowPath(from: points[points.count - 2], to: points.last!, size: 8), with: .color(Color(diagramHex: edge.strokeHex)))
                    }
                    if !edge.label.isEmpty, let middle = points[safe: points.count / 2] {
                        context.draw(
                            Text(edge.label).font(.system(size: 11)).foregroundColor(Color(diagramHex: edge.strokeHex)),
                            at: CGPoint(x: middle.x, y: middle.y - 10)
                        )
                    }
                }
            }
            ForEach(document.nodes) { node in
                let depth = mindMapDepths[node.id, default: 0]
                DiagramNodeShapeView(shape: node.shape)
                    .fill(Color(diagramHex: node.fillHex))
                    .overlay(DiagramNodeShapeView(shape: node.shape).stroke(Color(diagramHex: node.strokeHex), lineWidth: node.lineWidth))
                    .overlay(Text(node.text).font(.system(
                        size: document.kind == .mindMap ? DiagramMindMapStyle.fontSize(depth: depth) : 13,
                        weight: document.kind == .mindMap ? DiagramMindMapStyle.fontWeight(depth: depth) : .medium
                    )).foregroundStyle(Color(diagramHex: node.textHex)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).padding(8))
                    .frame(width: node.size.width, height: node.size.height)
                    .position(x: node.center.x - bounds.minX, y: node.center.y - bounds.minY)
            }
        }
        .frame(width: bounds.width, height: bounds.height)
    }
}

private func arrowPath(from start: CGPoint, to end: CGPoint, size: CGFloat) -> Path {
    let angle = atan2(end.y - start.y, end.x - start.x)
    let left = CGPoint(x: end.x - size * cos(angle - .pi / 6), y: end.y - size * sin(angle - .pi / 6))
    let right = CGPoint(x: end.x - size * cos(angle + .pi / 6), y: end.y - size * sin(angle + .pi / 6))
    var path = Path()
    path.move(to: end)
    path.addLine(to: left)
    path.addLine(to: right)
    path.closeSubpath()
    return path
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
