import AppKit
import HelloXCore

enum HelloXActionSource: Equatable, Sendable {
    case globalHotKey
    case statusMenu
    case dynamicIsland

    var hidesDynamicIslandDuringCapture: Bool {
        true
    }
}

@MainActor
final class HelloXActionDispatcher {
    private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func perform(
        _ action: ShortcutAction,
        source: HelloXActionSource,
        initialDisplayCaptures: [CaptureResult] = []
    ) {
        let hideDynamicIsland = source.hidesDynamicIslandDuringCapture
        switch action {
        case .regionCapture:
            model.startCapture(
                .region,
                hideDynamicIsland: hideDynamicIsland,
                initialDisplayCaptures: initialDisplayCaptures
            )
        case .windowCapture: model.startCapture(.window, hideDynamicIsland: hideDynamicIsland)
        case .fullScreenCapture:
            model.startCapture(
                .fullScreen,
                hideDynamicIsland: hideDynamicIsland,
                initialDisplayCaptures: initialDisplayCaptures
            )
        case .scrollingCapture: model.startCapture(.scrolling, hideDynamicIsland: hideDynamicIsland)
        case .screenRecording: model.startScreenRecording(hideDynamicIsland: hideDynamicIsland)
        case .watermarkImage: model.importImageForWatermark()
        case .captureAndOCR:
            model.captureAndOCR(
                hideDynamicIsland: hideDynamicIsland,
                initialDisplayCaptures: initialDisplayCaptures
            )
        case .textTranslation: model.showTextTranslation()
        case .captureAndTranslate:
            model.captureAndTranslate(
                hideDynamicIsland: hideDynamicIsland,
                initialDisplayCaptures: initialDisplayCaptures
            )
        case .translateSelection: model.translateSelectedText()
        case .csvToExcel: model.showUtilityTool(.csvToExcel)
        case .base64: model.showUtilityTool(.base64)
        case .qrCode: model.showUtilityTool(.qrCode)
        case .colorPicker: model.showUtilityTool(.colorPicker)
        case .password: model.showUtilityTool(.password)
        case .markdown: model.showUtilityTool(.markdown)
        case .mindMap: model.showUtilityTool(.mindMap)
        case .diagram, .flowchart: break // Retired actions cannot open an editor.
        }
    }
}
