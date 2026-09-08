import HelloXCore

extension ShortcutAction {
    var icon: HelloXIconKey {
        switch self {
        case .regionCapture: .capture
        case .windowCapture: .window
        case .fullScreenCapture: .screen
        case .scrollingCapture: .scrolling
        case .screenRecording: .recording
        case .watermarkImage: .watermark
        case .captureAndOCR: .textRecognition
        case .textTranslation: .translation
        case .captureAndTranslate: .translation
        case .translateSelection: .selectionTranslation
        case .csvToExcel: .spreadsheet
        case .base64: .code
        case .qrCode: .qrCode
        case .colorPicker: .colorPicker
        case .password: .password
        case .markdown: .markdown
        }
    }

    var settingsTitle: String {
        switch self {
        case .captureAndOCR: "文字提取（OCR）"
        case .qrCode: "二维码识别"
        case .colorPicker: "取色器"
        case .password: "密码生成"
        default: title
        }
    }

    var settingsDescription: String {
        switch self {
        case .regionCapture: "截取屏幕指定区域"
        case .windowCapture: "截取指定应用窗口"
        case .fullScreenCapture: "捕获当前整个屏幕"
        case .scrollingCapture: "滚动捕获长页面"
        case .screenRecording: "录制屏幕指定区域"
        case .watermarkImage: "为图片添加水印"
        case .captureAndOCR: "提取图片中的文字"
        case .textTranslation: "翻译输入文本"
        case .captureAndTranslate: "截图后自动翻译"
        case .translateSelection: "翻译当前选中文字"
        case .csvToExcel: "将 CSV 转换为 Excel"
        case .base64: "文本与 Base64 互转"
        case .qrCode: "识别二维码内容"
        case .colorPicker: "获取屏幕颜色值"
        case .password: "生成安全随机密码"
        case .markdown: "打开 Markdown 工具"
        }
    }
}
