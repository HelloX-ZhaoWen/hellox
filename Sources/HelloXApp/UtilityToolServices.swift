import AppKit
import Foundation
import Vision

enum UtilityTool: String, CaseIterable, Hashable {
    case csvToExcel
    case base64
    case qrCode
    case colorPicker
    case password
    case markdown
    case mindMap

    var title: String {
        switch self {
        case .csvToExcel: "CSV 转 Excel"
        case .base64: "Base64 转换"
        case .qrCode: "二维码识别"
        case .colorPicker: "取色器"
        case .password: "随机密码"
        case .markdown: "Markdown 转换"
        case .mindMap: "脑图"
        }
    }

    var dialogSubtitle: String? {
        switch self {
        case .csvToExcel: "将 CSV 表格转换为可在 Excel 中打开的 .xlsx 文件"
        case .base64: "在普通文本与 Base64 文本之间转换"
        case .qrCode: "从图片中识别二维码内容"
        case .password: "使用系统安全随机源生成高强度密码"
        case .markdown: "阅读、编辑并导出 Markdown 文档"
        case .mindMap: "创建、编辑并导出左右布局脑图"
        case .colorPicker: nil
        }
    }

    var diagramKind: DiagramKind? {
        switch self {
        case .mindMap: .mindMap
        default: nil
        }
    }

    var isDiagramEditor: Bool { diagramKind != nil }

}

enum UtilityToolError: LocalizedError, Equatable {
    case invalidCSV
    case excelArchiveFailed
    case invalidBase64
    case invalidImage
    case qrCodeNotFound
    case invalidMarkdownFile
    case passwordCharacterSetEmpty

    var errorDescription: String? {
        switch self {
        case .invalidCSV: "无法读取 CSV 文件，请确认文件编码和内容。"
        case .excelArchiveFailed: "无法生成 Excel 文件。"
        case .invalidBase64: "Base64 内容无效或不是 UTF-8 文本。"
        case .invalidImage: "无法读取所选图片。"
        case .qrCodeNotFound: "图片中未识别到二维码。"
        case .invalidMarkdownFile: "无法读取该 Markdown 文件，请确认文件编码。"
        case .passwordCharacterSetEmpty: "请至少选择一种字符类型。"
        }
    }
}

enum CSVTableParser {
    static func parse(_ input: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]
            if character == "\"" {
                let next = input.index(after: index)
                if isQuoted, next < input.endIndex, input[next] == "\"" {
                    field.append("\"")
                    index = input.index(after: next)
                    continue
                }
                isQuoted.toggle()
            } else if character == ",", !isQuoted {
                row.append(field)
                field = ""
            } else if (character == "\n" || character == "\r"), !isQuoted {
                if character == "\r" {
                    let next = input.index(after: index)
                    if next < input.endIndex, input[next] == "\n" { index = next }
                }
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(character)
            }
            index = input.index(after: index)
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

enum CSVExcelConverter {
    static func convert(sourceURL: URL, destinationURL: URL) throws {
        let data = try Data(contentsOf: sourceURL)
        guard let csv = decodeText(data), !csv.isEmpty else { throw UtilityToolError.invalidCSV }
        let rows = CSVTableParser.parse(csv)
        guard !rows.isEmpty else { throw UtilityToolError.invalidCSV }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HelloX-xlsx-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try writePackage(rows: rows, at: root)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", destinationURL.path, "."]
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              fileManager.fileExists(atPath: destinationURL.path) else {
            throw UtilityToolError.excelArchiveFailed
        }
    }

    private static func decodeText(_ data: Data) -> String? {
        if let value = String(data: data, encoding: .utf8) {
            return value.hasPrefix("\u{FEFF}") ? String(value.dropFirst()) : value
        }
        for encoding in [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian] {
            if let value = String(data: data, encoding: encoding) { return value }
        }
        return nil
    }

    private static func writePackage(rows: [[String]], at root: URL) throws {
        let fileManager = FileManager.default
        let relationships = root.appendingPathComponent("_rels", isDirectory: true)
        let worksheets = root.appendingPathComponent("xl/worksheets", isDirectory: true)
        let workbookRelationships = root.appendingPathComponent("xl/_rels", isDirectory: true)
        try fileManager.createDirectory(at: relationships, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: worksheets, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workbookRelationships, withIntermediateDirectories: true)

        try write(contentTypes, to: root.appendingPathComponent("[Content_Types].xml"))
        try write(rootRelationships, to: relationships.appendingPathComponent(".rels"))
        try write(workbook, to: root.appendingPathComponent("xl/workbook.xml"))
        try write(workbookRels, to: workbookRelationships.appendingPathComponent("workbook.xml.rels"))
        try write(styles, to: root.appendingPathComponent("xl/styles.xml"))
        try write(sheetXML(rows), to: worksheets.appendingPathComponent("sheet1.xml"))
    }

    private static func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url, options: .atomic)
    }

    private static func sheetXML(_ rows: [[String]]) -> String {
        let body = rows.enumerated().map { rowIndex, row in
            let cells = row.enumerated().map { columnIndex, value in
                let reference = "\(columnName(columnIndex + 1))\(rowIndex + 1)"
                return "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscaped(value))</t></is></c>"
            }.joined()
            return "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(body)</sheetData></worksheet>"
    }

    private static func columnName(_ number: Int) -> String {
        var value = number
        var result = ""
        while value > 0 {
            value -= 1
            result = String(UnicodeScalar(65 + value % 26)!) + result
            value /= 26
        }
        return result
    }

    private static func xmlEscaped(_ value: String) -> String {
        let sanitized = String(value.unicodeScalars.filter {
            $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32
        })
        return sanitized
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
      <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
    </Types>
    """

    private static let rootRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    private static let workbook = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>
    </workbook>
    """

    private static let workbookRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """

    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <fonts count="1"><font><sz val="11"/><name val="Aptos"/></font></fonts>
      <fills count="1"><fill><patternFill patternType="none"/></fill></fills>
      <borders count="1"><border/></borders>
      <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
      <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>
    </styleSheet>
    """
}

enum Base64Converter {
    static func encode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    static func decode(_ value: String) throws -> String {
        let compact = value.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: compact),
              let result = String(data: data, encoding: .utf8) else {
            throw UtilityToolError.invalidBase64
        }
        return result
    }
}

struct ColorCode: Equatable, Sendable {
    let red: Int
    let green: Int
    let blue: Int
    let alpha: Int

    init(red: Int, green: Int, blue: Int, alpha: Int = 255) {
        self.red = min(max(red, 0), 255)
        self.green = min(max(green, 0), 255)
        self.blue = min(max(blue, 0), 255)
        self.alpha = min(max(alpha, 0), 255)
    }

    init(color: NSColor) {
        let converted = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(
            red: Int((red * 255).rounded()),
            green: Int((green * 255).rounded()),
            blue: Int((blue * 255).rounded()),
            alpha: Int((alpha * 255).rounded())
        )
    }

    var hex: String {
        let rgb = String(format: "#%02X%02X%02X", red, green, blue)
        return alpha == 255 ? rgb : rgb + String(format: "%02X", alpha)
    }

    var rgb: String {
        guard alpha < 255 else { return "rgb(\(red), \(green), \(blue))" }
        return "rgba(\(red), \(green), \(blue), \(formattedAlpha))"
    }

    var hsl: String {
        let normalizedRed = Double(red) / 255
        let normalizedGreen = Double(green) / 255
        let normalizedBlue = Double(blue) / 255
        let maximum = max(normalizedRed, normalizedGreen, normalizedBlue)
        let minimum = min(normalizedRed, normalizedGreen, normalizedBlue)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))

        let rawHue: Double
        if delta == 0 {
            rawHue = 0
        } else if maximum == normalizedRed {
            rawHue = 60 * ((normalizedGreen - normalizedBlue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == normalizedGreen {
            rawHue = 60 * (((normalizedBlue - normalizedRed) / delta) + 2)
        } else {
            rawHue = 60 * (((normalizedRed - normalizedGreen) / delta) + 4)
        }
        let hue = Int((rawHue < 0 ? rawHue + 360 : rawHue).rounded()) % 360
        let hsl = "\(hue), \(Int((saturation * 100).rounded()))%, \(Int((lightness * 100).rounded()))%"
        return alpha == 255 ? "hsl(\(hsl))" : "hsla(\(hsl), \(formattedAlpha))"
    }

    private var formattedAlpha: String {
        let value = Double(alpha) / 255
        if value == 0 || value == 1 { return String(Int(value)) }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
    }
}

enum SecurePasswordGenerator {
    static func generate(
        length: Int,
        lowercase: Bool,
        uppercase: Bool,
        numbers: Bool,
        symbols: Bool
    ) throws -> String {
        var groups: [[Character]] = []
        if lowercase { groups.append(Array("abcdefghijkmnopqrstuvwxyz")) }
        if uppercase { groups.append(Array("ABCDEFGHJKLMNPQRSTUVWXYZ")) }
        if numbers { groups.append(Array("23456789")) }
        if symbols { groups.append(Array("!@#$%^&*_-+=?")) }
        guard !groups.isEmpty else { throw UtilityToolError.passwordCharacterSetEmpty }

        let actualLength = max(length, groups.count)
        var generator = SystemRandomNumberGenerator()
        var characters = groups.compactMap { $0.randomElement(using: &generator) }
        let all = groups.flatMap { $0 }
        while characters.count < actualLength {
            if let next = all.randomElement(using: &generator) { characters.append(next) }
        }
        characters.shuffle(using: &generator)
        return String(characters)
    }
}

enum QRCodeRecognitionService {
    static func recognize(at url: URL) throws -> [String] {
        guard let image = NSImage(contentsOf: url) else { throw UtilityToolError.invalidImage }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw UtilityToolError.invalidImage
        }
        return try recognize(in: cgImage)
    }

    static func recognize(in image: CGImage) throws -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let values = (request.results ?? []).compactMap(\.payloadStringValue)
        guard !values.isEmpty else { throw UtilityToolError.qrCodeNotFound }
        return values
    }
}

enum QRCodePayload {
    static func webURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              components.host?.isEmpty == false else { return nil }
        return components.url
    }
}

enum MarkdownFileService {
    static func read(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian] {
            if let value = String(data: data, encoding: encoding) { return value }
        }
        throw UtilityToolError.invalidMarkdownFile
    }

    static func write(_ markdown: String, to url: URL) throws {
        try Data(markdown.utf8).write(to: url, options: .atomic)
    }
}

private func markdownLines(in markdown: String) -> [String] {
    markdown
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .components(separatedBy: .newlines)
}

struct MarkdownHeading: Identifiable, Equatable, Sendable {
    let id: String
    let level: Int
    let title: String
}

struct MarkdownOutlineRow: Identifiable, Equatable, Sendable {
    let heading: MarkdownHeading
    let depth: Int
    let hasChildren: Bool
    var id: String { heading.id }
}

enum MarkdownOutline {
    static func visibleRows(
        headings: [MarkdownHeading],
        collapsedIDs: Set<String>
    ) -> [MarkdownOutlineRow] {
        var ancestors: [MarkdownHeading] = []
        var rows: [MarkdownOutlineRow] = []
        for (index, heading) in headings.enumerated() {
            while let parent = ancestors.last, parent.level >= heading.level {
                ancestors.removeLast()
            }
            if !ancestors.contains(where: { collapsedIDs.contains($0.id) }) {
                rows.append(MarkdownOutlineRow(
                    heading: heading,
                    depth: ancestors.count,
                    hasChildren: index + 1 < headings.count && headings[index + 1].level > heading.level
                ))
            }
            ancestors.append(heading)
        }
        return rows
    }
}

enum MarkdownHeadingParser {
    static func headings(in markdown: String) -> [MarkdownHeading] {
        var result: [MarkdownHeading] = []
        var isInsideCodeFence = false
        for rawLine in markdownLines(in: markdown) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                isInsideCodeFence.toggle()
                continue
            }
            guard !isInsideCodeFence else { continue }
            let level = min(line.prefix { $0 == "#" }.count, 6)
            guard level > 0, line.dropFirst(level).hasPrefix(" ") else { continue }
            let rawTitle = String(line.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
            guard !rawTitle.isEmpty else { continue }
            result.append(MarkdownHeading(
                id: "heading-\(result.count + 1)",
                level: level,
                title: plainText(from: rawTitle)
            ))
        }
        return result
    }

    private static func plainText(from value: String) -> String {
        var result = value
        result = replacing(#"!\[([^]]*)\]\([^)]+\)"#, in: result, with: "$1")
        result = replacing(#"\[([^]]+)\]\([^)]+\)"#, in: result, with: "$1")
        return replacing(#"[*_~`]"#, in: result, with: "")
    }

    private static func replacing(_ pattern: String, in value: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: template
        )
    }
}

enum MarkdownLocalImageScheme {
    static let name = "hellox-markdown-image"

    static func previewBaseURL(for directoryURL: URL?) -> URL? {
        guard let directoryURL else { return nil }
        guard directoryURL.isFileURL else { return directoryURL }
        let localDirectoryURL = URL(
            fileURLWithPath: directoryURL.standardizedFileURL.path,
            isDirectory: true
        )
        var components = URLComponents(url: localDirectoryURL, resolvingAgainstBaseURL: false)
        components?.scheme = name
        return components?.url
    }

    static func fileURL(for previewURL: URL) -> URL? {
        guard previewURL.scheme?.lowercased() == name,
              previewURL.host == nil || previewURL.host?.isEmpty == true,
              previewURL.user == nil,
              previewURL.password == nil,
              previewURL.port == nil else { return nil }
        return URL(fileURLWithPath: previewURL.path).standardizedFileURL
    }

    static func resolvedFileURL(_ fileURL: URL, containedIn directoryURL: URL) -> URL? {
        guard fileURL.isFileURL, directoryURL.isFileURL else { return nil }
        let resolvedDirectoryURL = directoryURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedFileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let directoryPath = resolvedDirectoryURL.path.hasSuffix("/")
            ? resolvedDirectoryURL.path
            : resolvedDirectoryURL.path + "/"
        guard resolvedFileURL.path == resolvedDirectoryURL.path
                || resolvedFileURL.path.hasPrefix(directoryPath) else { return nil }
        return resolvedFileURL
    }
}

enum MarkdownHTMLConverter {
    private static let maximumBlockquoteDepth = 32

    static func convert(
        _ markdown: String,
        title: String = "Markdown",
        baseURL: URL? = nil,
        localFileImageScheme: String? = nil
    ) -> String {
        let body = rewritingFileImageSources(
            in: bodyHTML(markdown),
            to: localFileImageScheme
        )
        let baseTag = baseURL.map { "<base href=\"\(htmlEscaped($0.absoluteString))\">" } ?? ""
        return """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">\(baseTag)<title>\(htmlEscaped(title))</title>
        <style>
        :root{color-scheme:light dark;--bg:#fff;--text:#0f1419;--muted:#536471;--line:#eff3f4;--soft:#f7f9f9;--accent:#009aff;--scroll-thumb:rgba(15,20,25,.16);--scroll-hover:rgba(15,20,25,.42)}
        @media(prefers-color-scheme:dark){:root{--bg:#000;--text:#e7e9ea;--muted:#8b98a5;--line:#2f3336;--soft:#16181c;--accent:#009aff;--scroll-thumb:rgba(231,233,234,.16);--scroll-hover:rgba(231,233,234,.42)}}
        *{box-sizing:border-box}html{scroll-behavior:smooth;background:var(--bg)}body{font:16px -apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC",sans-serif;line-height:1.75;max-width:980px;margin:0 auto;padding:52px 64px 96px;color:var(--text);background:var(--bg)}
        ::-webkit-scrollbar{width:12px;height:12px;background:transparent}::-webkit-scrollbar-track,::-webkit-scrollbar-corner{background:transparent;border:0}::-webkit-scrollbar-thumb{background:var(--scroll-thumb);background-clip:padding-box;border:4px solid transparent;border-radius:999px}::-webkit-scrollbar-thumb:hover{background:var(--scroll-hover);background-clip:padding-box}
        h1,h2,h3,h4,h5,h6{font-weight:750;line-height:1.28;letter-spacing:-.015em;margin:1.7em 0 .65em;scroll-margin-top:28px}h1{font-size:2.45em;border-bottom:1px solid var(--line);padding-bottom:.32em;margin-top:.35em}h2{font-size:1.75em;border-bottom:1px solid var(--line);padding-bottom:.28em}h3{font-size:1.35em}h4{font-size:1.12em}p{margin:.85em 0}ul,ol{padding-left:1.65em;margin:.8em 0}li{margin:.32em 0}
        a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}strong{font-weight:720}hr{border:0;border-top:1px solid var(--line);margin:2.2em 0}blockquote{margin:1.2em 0;padding:.15em 1.1em;border-left:4px solid var(--accent);color:var(--muted);background:var(--soft);border-radius:0 8px 8px 0}
        code{font-family:"SFMono-Regular",Consolas,monospace;font-size:.9em;background:var(--soft);padding:.16em .38em;border-radius:5px}pre{background:var(--soft);padding:18px 20px;border-radius:10px;overflow:auto;line-height:1.55}pre code{padding:0;background:transparent;font-size:13px}img{max-width:100%;height:auto;border-radius:8px}.table-scroll{max-width:100%;overflow-x:auto;margin:1.2em 0}.table-scroll table{width:max-content;min-width:100%;border-collapse:collapse;margin:0}.table-scroll th,.table-scroll td{border:1px solid var(--line);padding:8px 12px;text-align:left;vertical-align:top;overflow-wrap:anywhere}.table-scroll th{background:var(--soft)}
        @media(max-width:720px){body{padding:32px 24px 72px}}@media print{body{max-width:none;padding:0;color:#111;background:#fff}a{color:#111}pre,code{-webkit-print-color-adjust:exact}}
        </style></head><body>\(body)</body></html>
        """
    }

    private static func bodyHTML(_ markdown: String, blockquoteDepth: Int = 0) -> String {
        var output: [String] = []
        var paragraph: [String] = []
        var isInsideCodeFence = false
        var currentList: String?
        var rawHTMLContainer: RawHTMLContainer?
        var headingIndex = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            output.append("<p>\(inlineHTML(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll(keepingCapacity: true)
        }
        func closeList() {
            guard let tag = currentList else { return }
            output.append("</\(tag)>")
            currentList = nil
        }

        let lines = markdownLines(in: markdown)
        var lineIndex = 0
        while lineIndex < lines.count {
            let rawLine = lines[lineIndex]
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushParagraph()
                closeList()
                output.append(isInsideCodeFence ? "</code></pre>" : "<pre><code>")
                isInsideCodeFence.toggle()
                lineIndex += 1
                continue
            }
            if isInsideCodeFence {
                output.append(htmlEscaped(rawLine) + "\n")
                lineIndex += 1
                continue
            }

            if let container = rawHTMLContainer {
                if rawHTMLClosingTag(in: line) == container.tag {
                    output.append("</\(container.tag)>")
                    rawHTMLContainer = nil
                } else if let imageHTML = sanitizedRawImageHTML(line) {
                    output.append(imageHTML)
                } else if !line.isEmpty {
                    output.append(inlineHTML(line))
                }
                lineIndex += 1
                continue
            }

            if let blockHTML = sanitizedRawHTMLBlock(line) {
                flushParagraph()
                closeList()
                output.append(blockHTML)
                lineIndex += 1
                continue
            }
            if let container = rawHTMLContainerOpening(in: line) {
                flushParagraph()
                closeList()
                output.append(container.openingHTML)
                rawHTMLContainer = container
                lineIndex += 1
                continue
            }
            if let imageHTML = sanitizedRawImageHTML(line) {
                flushParagraph()
                closeList()
                output.append(imageHTML)
                lineIndex += 1
                continue
            }
            if line.isEmpty {
                flushParagraph()
                closeList()
                lineIndex += 1
                continue
            }

            if let blockquote = blockquoteBlock(
                in: lines,
                startingAt: lineIndex,
                depth: blockquoteDepth
            ) {
                flushParagraph()
                closeList()
                output.append(blockquote.html)
                lineIndex = blockquote.nextIndex
                continue
            }

            if let table = tableBlock(in: lines, startingAt: lineIndex) {
                flushParagraph()
                closeList()
                output.append(table.html)
                lineIndex = table.nextIndex
                continue
            }

            let headingLevel = min(line.prefix { $0 == "#" }.count, 6)
            if headingLevel > 0, line.dropFirst(headingLevel).hasPrefix(" ") {
                flushParagraph()
                closeList()
                headingIndex += 1
                let content = String(line.dropFirst(headingLevel + 1)).trimmingCharacters(in: .whitespaces)
                output.append("<h\(headingLevel) id=\"heading-\(headingIndex)\">\(inlineHTML(content))</h\(headingLevel)>")
                lineIndex += 1
                continue
            }
            if let item = unorderedItem(in: line) {
                flushParagraph()
                if currentList != "ul" { closeList(); output.append("<ul>"); currentList = "ul" }
                output.append("<li>\(inlineHTML(item))</li>")
                lineIndex += 1
                continue
            }
            if let item = orderedItem(in: line) {
                flushParagraph()
                if currentList != "ol" { closeList(); output.append("<ol>"); currentList = "ol" }
                output.append("<li>\(inlineHTML(item))</li>")
                lineIndex += 1
                continue
            }

            closeList()
            if line == "---" || line == "***" || line == "___" {
                flushParagraph()
                output.append("<hr>")
            } else {
                paragraph.append(line)
            }
            lineIndex += 1
        }
        flushParagraph()
        closeList()
        if let rawHTMLContainer { output.append("</\(rawHTMLContainer.tag)>") }
        if isInsideCodeFence { output.append("</code></pre>") }
        return output.joined(separator: "\n")
    }

    private struct BlockquoteBlock {
        let html: String
        let nextIndex: Int
    }

    private static func blockquoteBlock(
        in lines: [String],
        startingAt index: Int,
        depth: Int
    ) -> BlockquoteBlock? {
        guard depth < maximumBlockquoteDepth else { return nil }
        var quotedLines: [String] = []
        var nextIndex = index
        while nextIndex < lines.count,
              let content = blockquoteContent(from: lines[nextIndex]) {
            quotedLines.append(content)
            nextIndex += 1
        }
        guard !quotedLines.isEmpty else { return nil }
        let contentHTML = bodyHTML(
            quotedLines.joined(separator: "\n"),
            blockquoteDepth: depth + 1
        )
        return BlockquoteBlock(
            html: "<blockquote>\n\(contentHTML)\n</blockquote>",
            nextIndex: nextIndex
        )
    }

    private static func blockquoteContent(from rawLine: String) -> String? {
        let line = rawLine.drop { $0 == " " || $0 == "\t" }
        guard line.first == ">" else { return nil }
        var content = line.dropFirst()
        if content.first == " " || content.first == "\t" {
            content = content.dropFirst()
        }
        return String(content)
    }

    private struct RawHTMLContainer {
        let tag: String
        let openingHTML: String
    }

    private static func rawHTMLContainerOpening(in line: String) -> RawHTMLContainer? {
        guard let captures = captures(
            #"^<(p|div|h[1-6])(?:\s+align\s*=\s*[\"']?(left|center|right)[\"']?)?\s*>$"#,
            in: line,
            options: [.caseInsensitive]
        ), let rawTag = captures[0] else { return nil }
        let tag = rawTag.lowercased()
        let alignment = captures[1]?.lowercased()
        let style = alignment.map { " style=\"text-align:\($0)\"" } ?? ""
        return RawHTMLContainer(tag: tag, openingHTML: "<\(tag)\(style)>")
    }

    private static func rawHTMLClosingTag(in line: String) -> String? {
        guard let captures = captures(
            #"^</(p|div|h[1-6])\s*>$"#,
            in: line,
            options: [.caseInsensitive]
        ), let tag = captures[0] else { return nil }
        return tag.lowercased()
    }

    private static func sanitizedRawHTMLBlock(_ line: String) -> String? {
        if line.range(of: #"^<br\s*/?>$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return "<br>"
        }
        guard let captures = captures(
            #"^<(p|div|h[1-6])(?:\s+align\s*=\s*[\"']?(left|center|right)[\"']?)?\s*>(.*?)</(p|div|h[1-6])\s*>$"#,
            in: line,
            options: [.caseInsensitive]
        ), let rawOpeningTag = captures[0], let content = captures[2], let rawClosingTag = captures[3] else {
            return nil
        }
        let tag = rawOpeningTag.lowercased()
        guard tag == rawClosingTag.lowercased() else { return nil }
        let alignment = captures[1]?.lowercased()
        let style = alignment.map { " style=\"text-align:\($0)\"" } ?? ""
        return "<\(tag)\(style)>\(inlineHTML(content))</\(tag)>"
    }

    private static func sanitizedRawImageHTML(_ line: String) -> String? {
        guard let captures = captures(
            #"^<img\b([^>]*)/?>$"#,
            in: line,
            options: [.caseInsensitive]
        ), let rawAttributes = captures[0],
              let expression = try? NSRegularExpression(
                pattern: #"([A-Za-z][A-Za-z0-9:-]*)\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+))"#
              ) else { return nil }

        let range = NSRange(rawAttributes.startIndex..., in: rawAttributes)
        var attributes: [String: String] = [:]
        expression.enumerateMatches(in: rawAttributes, range: range) { match, _, _ in
            guard let match,
                  let nameRange = Range(match.range(at: 1), in: rawAttributes) else { return }
            let name = rawAttributes[nameRange].lowercased()
            guard ["src", "alt", "title", "width", "height"].contains(name) else { return }
            let value = (2...4).compactMap { captureIndex -> String? in
                guard let valueRange = Range(match.range(at: captureIndex), in: rawAttributes) else { return nil }
                return String(rawAttributes[valueRange])
            }.first ?? ""
            if name == "width" || name == "height" {
                guard value.range(of: #"^\d{1,5}(?:\.\d+)?%?$"#, options: .regularExpression) != nil else { return }
            }
            attributes[name] = value
        }

        guard let rawSource = attributes["src"] else { return nil }
        let source = rawSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeImageSource(source) else { return nil }
        var html = "<img src=\"\(htmlEscaped(source))\" alt=\"\(htmlEscaped(attributes["alt"] ?? ""))\""
        for name in ["title", "width", "height"] {
            if let value = attributes[name] {
                html += " \(name)=\"\(htmlEscaped(value))\""
            }
        }
        return html + ">"
    }

    private static func isSafeImageSource(_ source: String) -> Bool {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        guard let colon = value.firstIndex(of: ":") else { return true }
        let scheme = value[..<colon]
        guard scheme.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#, options: .regularExpression) != nil else {
            return true
        }
        switch scheme.lowercased() {
        case "http", "https", "file":
            return true
        case "data":
            return value.lowercased().hasPrefix("data:image/")
        default:
            return false
        }
    }

    private static func rewritingFileImageSources(in html: String, to scheme: String?) -> String {
        guard let scheme,
              scheme.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*$"#, options: .regularExpression) != nil,
              let expression = try? NSRegularExpression(
                pattern: #"(<img\b[^>]*\bsrc=\")file:"#,
                options: [.caseInsensitive]
              ) else { return html }
        return expression.stringByReplacingMatches(
            in: html,
            range: NSRange(html.startIndex..., in: html),
            withTemplate: "$1\(scheme):"
        )
    }

    private static func captures(
        _ pattern: String,
        in value: String,
        options: NSRegularExpression.Options = []
    ) -> [String?]? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let fullRange = NSRange(value.startIndex..., in: value)
        guard let match = expression.firstMatch(in: value, range: fullRange), match.range == fullRange else {
            return nil
        }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }

    private struct TableBlock {
        let html: String
        let nextIndex: Int
    }

    private enum TableAlignment {
        case left, center, right

        var cssValue: String {
            switch self {
            case .left: "left"
            case .center: "center"
            case .right: "right"
            }
        }
    }

    private static func tableBlock(in lines: [String], startingAt index: Int) -> TableBlock? {
        guard index + 1 < lines.count,
              let header = tableCells(from: lines[index]),
              let separator = tableCells(from: lines[index + 1]),
              header.count == separator.count,
              !header.isEmpty
        else { return nil }
        let parsedAlignments = separator.compactMap(parseTableAlignment(_:))
        guard parsedAlignments.count == separator.count else { return nil }
        let alignments = parsedAlignments

        var rowIndex = index + 2
        var rows: [[String]] = []
        while rowIndex < lines.count,
              let cells = tableCells(from: lines[rowIndex]),
              !cells.isEmpty {
            rows.append(Array(cells.prefix(header.count)) + Array(repeating: "", count: max(0, header.count - cells.count)))
            rowIndex += 1
        }

        let headerHTML = zip(header, alignments).map { cell, alignment in
            "<th style=\"text-align:\(alignment.cssValue)\">\(inlineHTML(cell))</th>"
        }.joined()
        let rowsHTML = rows.map { row in
            let cells = zip(row, alignments).map { cell, alignment in
                "<td style=\"text-align:\(alignment.cssValue)\">\(inlineHTML(cell))</td>"
            }.joined()
            return "<tr>\(cells)</tr>"
        }.joined()
        return TableBlock(
            html: "<div class=\"table-scroll\"><table><thead><tr>\(headerHTML)</tr></thead><tbody>\(rowsHTML)</tbody></table></div>",
            nextIndex: rowIndex
        )
    }

    private static func tableCells(from line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var cells: [String] = []
        var cell = ""
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "|" {
                cell.append("|")
                index += 2
                continue
            }
            if character == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell.removeAll(keepingCapacity: true)
            } else {
                cell.append(character)
            }
            index += 1
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells.isEmpty ? nil : cells
    }

    private static func parseTableAlignment(_ cell: String) -> TableAlignment? {
        let value = cell.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let hasLeadingColon = value.first == ":"
        let hasTrailingColon = value.last == ":"
        let start = value.index(value.startIndex, offsetBy: hasLeadingColon ? 1 : 0)
        let end = value.index(value.endIndex, offsetBy: hasTrailingColon ? -1 : 0)
        guard start <= end else { return nil }
        let dashes = value[start..<end]
        guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
        if hasLeadingColon && hasTrailingColon { return .center }
        if hasTrailingColon { return .right }
        return .left
    }

    private static func unorderedItem(in line: String) -> String? {
        guard line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") else { return nil }
        return String(line.dropFirst(2))
    }

    private static func orderedItem(in line: String) -> String? {
        guard let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) else { return nil }
        return String(line[range.upperBound...])
    }

    private static func inlineHTML(_ input: String) -> String {
        var value = htmlEscaped(input)
        value = replacing(#"!\[([^]]*)\]\(([^)]+)\)"#, in: value, with: "<img src=\"$2\" alt=\"$1\">")
        value = replacing(#"\[([^]]+)\]\(([^)]+)\)"#, in: value, with: "<a href=\"$2\">$1</a>")
        value = replacing(#"\*\*(.+?)\*\*"#, in: value, with: "<strong>$1</strong>")
        value = replacing(#"__(.+?)__"#, in: value, with: "<strong>$1</strong>")
        value = replacing(#"~~(.+?)~~"#, in: value, with: "<del>$1</del>")
        value = replacing(#"(?<!\*)\*([^*]+)\*(?!\*)"#, in: value, with: "<em>$1</em>")
        value = replacing(#"`(.+?)`"#, in: value, with: "<code>$1</code>")
        return value
    }

    private static func replacing(_ pattern: String, in value: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template)
    }

    private static func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

@MainActor
enum UtilityClipboard {
    @discardableResult
    static func copy(_ value: String) -> Bool {
        NSPasteboard.general.clearContents()
        let success = NSPasteboard.general.setString(value, forType: .string)
        if success { CopyFeedbackPresenter.shared.showSuccess() }
        else { CopyFeedbackPresenter.shared.showFailure() }
        return success
    }
}
