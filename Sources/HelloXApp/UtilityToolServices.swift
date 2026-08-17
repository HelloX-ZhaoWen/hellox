import AppKit
import Foundation
import Vision

enum UtilityTool: String, CaseIterable, Hashable {
    case csvToExcel
    case base64
    case qrCode
    case password
    case markdown

    var title: String {
        switch self {
        case .csvToExcel: "CSV 转 Excel"
        case .base64: "Base64 转换"
        case .qrCode: "二维码识别"
        case .password: "随机密码"
        case .markdown: "Markdown 转换"
        }
    }
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

struct MarkdownHeading: Identifiable, Equatable, Sendable {
    let id: String
    let level: Int
    let title: String
}

enum MarkdownHeadingParser {
    static func headings(in markdown: String) -> [MarkdownHeading] {
        var result: [MarkdownHeading] = []
        var isInsideCodeFence = false
        for rawLine in markdown.components(separatedBy: .newlines) {
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

enum MarkdownHTMLConverter {
    static func convert(_ markdown: String, title: String = "Markdown", baseURL: URL? = nil) -> String {
        let body = bodyHTML(markdown)
        let baseTag = baseURL.map { "<base href=\"\(htmlEscaped($0.absoluteString))\">" } ?? ""
        return """
        <!doctype html>
        <html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">\(baseTag)<title>\(htmlEscaped(title))</title>
        <style>
        :root{color-scheme:light dark;--bg:#fff;--text:#1f2937;--muted:#64748b;--line:#e2e8f0;--soft:#f1f5f9;--accent:#2563eb;--scroll-thumb:rgba(15,23,42,.16);--scroll-hover:rgba(15,23,42,.42)}
        @media(prefers-color-scheme:dark){:root{--bg:#101827;--text:#e5edf8;--muted:#9fb0c8;--line:#334155;--soft:#1e293b;--accent:#60a5fa;--scroll-thumb:rgba(248,250,252,.16);--scroll-hover:rgba(248,250,252,.42)}}
        *{box-sizing:border-box}html{scroll-behavior:smooth;background:var(--bg)}body{font:16px -apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC",sans-serif;line-height:1.75;max-width:980px;margin:0 auto;padding:52px 64px 96px;color:var(--text);background:var(--bg)}
        ::-webkit-scrollbar{width:12px;height:12px;background:transparent}::-webkit-scrollbar-track,::-webkit-scrollbar-corner{background:transparent;border:0}::-webkit-scrollbar-thumb{background:var(--scroll-thumb);background-clip:padding-box;border:4px solid transparent;border-radius:999px}::-webkit-scrollbar-thumb:hover{background:var(--scroll-hover);background-clip:padding-box}
        h1,h2,h3,h4,h5,h6{font-weight:750;line-height:1.28;letter-spacing:-.015em;margin:1.7em 0 .65em;scroll-margin-top:28px}h1{font-size:2.45em;border-bottom:1px solid var(--line);padding-bottom:.32em;margin-top:.35em}h2{font-size:1.75em;border-bottom:1px solid var(--line);padding-bottom:.28em}h3{font-size:1.35em}h4{font-size:1.12em}p{margin:.85em 0}ul,ol{padding-left:1.65em;margin:.8em 0}li{margin:.32em 0}
        a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}strong{font-weight:720}hr{border:0;border-top:1px solid var(--line);margin:2.2em 0}blockquote{margin:1.2em 0;padding:.15em 1.1em;border-left:4px solid var(--accent);color:var(--muted);background:var(--soft);border-radius:0 8px 8px 0}
        code{font-family:"SFMono-Regular",Consolas,monospace;font-size:.9em;background:var(--soft);padding:.16em .38em;border-radius:5px}pre{background:var(--soft);padding:18px 20px;border-radius:10px;overflow:auto;line-height:1.55}pre code{padding:0;background:transparent;font-size:13px}img{max-width:100%;height:auto;border-radius:8px}.table-scroll{max-width:100%;overflow-x:auto;margin:1.2em 0}.table-scroll table{width:max-content;min-width:100%;border-collapse:collapse;margin:0}.table-scroll th,.table-scroll td{border:1px solid var(--line);padding:8px 12px;text-align:left;vertical-align:top;overflow-wrap:anywhere}.table-scroll th{background:var(--soft)}
        @media(max-width:720px){body{padding:32px 24px 72px}}@media print{body{max-width:none;padding:0;color:#111;background:#fff}a{color:#111}pre,code{-webkit-print-color-adjust:exact}}
        </style></head><body>\(body)</body></html>
        """
    }

    private static func bodyHTML(_ markdown: String) -> String {
        var output: [String] = []
        var paragraph: [String] = []
        var isInsideCodeFence = false
        var currentList: String?
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

        let lines = markdown.components(separatedBy: .newlines)
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
            if line.isEmpty {
                flushParagraph()
                closeList()
                lineIndex += 1
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
            } else if line.hasPrefix("> ") {
                flushParagraph()
                output.append("<blockquote><p>\(inlineHTML(String(line.dropFirst(2))))</p></blockquote>")
            } else {
                paragraph.append(line)
            }
            lineIndex += 1
        }
        flushParagraph()
        closeList()
        if isInsideCodeFence { output.append("</code></pre>") }
        return output.joined(separator: "\n")
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
