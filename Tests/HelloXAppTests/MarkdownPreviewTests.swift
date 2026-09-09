import AppKit
import Foundation
import Testing
import WebKit
@testable import HelloXApp

@Suite("Markdown Preview")
struct MarkdownPreviewTests {
    @Test func outlineCollapsesDescendantsWithoutHidingSiblingBranches() {
        let headings = MarkdownHeadingParser.headings(in: """
        # Manual
        ## Dashboard
        ### Overview
        #### Metrics
        ### Agents
        ## Emails
        ### Inbox
        # Appendix
        """)
        let rows = MarkdownOutline.visibleRows(headings: headings, collapsedIDs: ["heading-2"])
        #expect(rows.map(\.heading.title) == ["Manual", "Dashboard", "Emails", "Inbox", "Appendix"])
        #expect(rows.map(\.depth) == [0, 1, 1, 2, 0])
        #expect(rows.map(\.hasChildren) == [true, true, true, false, false])
        #expect(MarkdownOutline.visibleRows(headings: headings, collapsedIDs: ["heading-1"])
            .map(\.heading.title) == ["Manual", "Appendix"])
    }

    @Test func outlineHandlesSkippedLevelsAndDocumentsWithoutHeadings() {
        let headings = MarkdownHeadingParser.headings(in: """
        ## Section
        #### Detail
        #### Peer
        ### Other
        ###### Deep
        ## Next
        """)
        #expect(MarkdownOutline.visibleRows(headings: headings, collapsedIDs: []).map(\.depth)
            == [0, 1, 1, 1, 2, 0])
        #expect(MarkdownOutline.visibleRows(headings: headings, collapsedIDs: ["heading-4"])
            .map(\.heading.title) == ["Section", "Detail", "Peer", "Other", "Next"])
        #expect(MarkdownOutline.visibleRows(headings: [], collapsedIDs: []).isEmpty)
    }

    @Test @MainActor func outlineRemembersNestedCollapsePerDocumentAndResetsWhenHeadingsChange() {
        let markdown = "# Manual\n## Section\n### Detail\n## Next"
        let workspace = MarkdownWorkspace()
        let first = workspace.openDocument(url: URL(fileURLWithPath: "/tmp/outline-first.md"), markdown: markdown)
        first.toggleHeading("heading-2")
        first.toggleHeading("heading-1")
        first.toggleHeading("heading-1")
        #expect(first.outlineRows.map(\.heading.title) == ["Manual", "Section", "Next"])

        let second = workspace.openDocument(url: URL(fileURLWithPath: "/tmp/outline-second.md"), markdown: markdown)
        #expect(second.outlineRows.count == 4)
        workspace.activate(first)
        first.isTableOfContentsExpanded = false
        first.isTableOfContentsExpanded = true
        first.mode = .edit
        first.markdown += "\nBody text"
        first.mode = .preview
        #expect(first.collapsedHeadingIDs == ["heading-2"])
        first.markdown = "# New heading\n" + first.markdown
        #expect(first.collapsedHeadingIDs.isEmpty)
        #expect(first.outlineRows.count == 5)
    }

    @Test @MainActor func readingDocumentReloadsAfterTheFileChanges() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelloX-MarkdownReloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("live.md")
        try MarkdownFileService.write("# First", to: fileURL)
        let document = MarkdownDocumentTab(url: fileURL, markdown: "# First")

        try MarkdownFileService.write("# Latest", to: fileURL)

        for _ in 0..<100 where document.markdown != "# Latest" {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(document.markdown == "# Latest")
        #expect(!document.isModified)
    }

    @Test @MainActor func automaticReloadPreservesUnsavedEdits() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelloX-MarkdownConflictTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("conflict.md")
        try MarkdownFileService.write("Saved", to: fileURL)
        let document = MarkdownDocumentTab(url: fileURL, markdown: "Saved")
        document.markdown = "Unsaved edit"

        try MarkdownFileService.write("External edit", to: fileURL)
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(document.markdown == "Unsaved edit")
        #expect(document.isModified)
        #expect(try document.reloadFromDisk(discardingUnsavedChanges: true))
        #expect(document.markdown == "External edit")
        #expect(!document.isModified)
    }

    @Test @MainActor func returningToReadingModeCatchesUpWithDiskChanges() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelloX-MarkdownModeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("mode.md")
        try MarkdownFileService.write("Before", to: fileURL)
        let document = MarkdownDocumentTab(url: fileURL, markdown: "Before")
        document.mode = .edit

        try MarkdownFileService.write("Changed while editing", to: fileURL)
        document.mode = .preview

        #expect(document.markdown == "Changed while editing")
        #expect(!document.isModified)
    }

    @Test func converterRendersMarkdownAndSanitizedHTMLImages() {
        let markdown = """
        ![Markdown logo](Images/markdown.png)

        <p align="center">
          <img src="Images/html.png" width="128" height="64" alt="HTML logo" onerror="alert(1)">
        </p>

        <h1 align="center">HelloX</h1>
        """

        let html = MarkdownHTMLConverter.convert(markdown)

        #expect(html.contains(#"<img src="Images/markdown.png" alt="Markdown logo">"#))
        #expect(html.contains(#"<p style="text-align:center">"#))
        #expect(html.contains(#"<img src="Images/html.png" alt="HTML logo" width="128" height="64">"#))
        #expect(html.contains(#"<h1 style="text-align:center">HelloX</h1>"#))
        #expect(!html.contains("onerror"))
        #expect(!html.contains("&lt;img"))
    }

    @Test func converterGroupsQuotedParagraphsAndConsumesBareMarkers() {
        let markdown = """
        > **说明**
        >
        > Enabled、Authorized 和 Connected 是不同维度。显示已授权不表示收件、发件和会话关联一定正常。

        引用后的正文。
        """

        let html = MarkdownHTMLConverter.convert(markdown)

        #expect(html.components(separatedBy: "<blockquote>").count - 1 == 1)
        #expect(html.contains("""
        <blockquote>
        <p><strong>说明</strong></p>
        <p>Enabled、Authorized 和 Connected 是不同维度。显示已授权不表示收件、发件和会话关联一定正常。</p>
        </blockquote>
        """))
        #expect(html.contains("</blockquote>\n<p>引用后的正文。</p>"))
        #expect(!html.contains("<p>&gt;</p>"))
    }

    @Test func converterKeepsListsAndNestedQuotesInsideOneBlockquote() {
        let markdown = """
        > 第一行
        > 第二行
        >
        > - 项目 A
        > - 项目 B
        >
        > > 嵌套说明
        """

        let html = MarkdownHTMLConverter.convert(markdown)

        #expect(html.components(separatedBy: "<blockquote>").count - 1 == 2)
        #expect(html.contains("<p>第一行 第二行</p>"))
        #expect(html.contains("<ul>\n<li>项目 A</li>\n<li>项目 B</li>\n</ul>"))
        #expect(html.contains("<blockquote>\n<p>嵌套说明</p>\n</blockquote>"))
    }

    @Test func converterNormalizesCRLFInsideBlockquotes() {
        let markdown = "> **说明**\r\n>\r\n> Enabled、Authorized 和 Connected 是不同维度。"

        let html = MarkdownHTMLConverter.convert(markdown)

        #expect(html.components(separatedBy: "<blockquote>").count - 1 == 1)
        #expect(html.contains("<p><strong>说明</strong></p>"))
        #expect(html.contains("<p>Enabled、Authorized 和 Connected 是不同维度。</p>"))
        #expect(!html.contains("<p>&gt;</p>"))
    }

    @Test func converterBoundsPathologicalBlockquoteNesting() {
        let markdown = String(repeating: "> ", count: 2_000) + "仍可显示"

        let html = MarkdownHTMLConverter.convert(markdown)

        #expect(html.contains("仍可显示"))
        #expect(html.components(separatedBy: "<blockquote>").count - 1 == 32)
    }

    @Test func converterRewritesExplicitFileImageURLsForPreviewOnly() {
        let markdown = "![Local](file:///tmp/Preview/image.png)"
        let previewHTML = MarkdownHTMLConverter.convert(
            markdown,
            localFileImageScheme: MarkdownLocalImageScheme.name
        )
        let exportedHTML = MarkdownHTMLConverter.convert(markdown)

        #expect(previewHTML.contains(#"src="hellox-markdown-image:///tmp/Preview/image.png""#))
        #expect(exportedHTML.contains(#"src="file:///tmp/Preview/image.png""#))
    }

    @Test func localImageSchemeMapsDirectoryAndEscapedFilePaths() throws {
        let directory = URL(fileURLWithPath: "/tmp/HelloX Markdown", isDirectory: true)
        let previewBaseURL = try #require(MarkdownLocalImageScheme.previewBaseURL(for: directory))
        let previewImageURL = try #require(URL(string: "asset%20one.png", relativeTo: previewBaseURL)?.absoluteURL)
        let fileURL = try #require(MarkdownLocalImageScheme.fileURL(for: previewImageURL))

        #expect(previewBaseURL.absoluteString == "hellox-markdown-image:///tmp/HelloX%20Markdown/")
        #expect(fileURL.path == "/tmp/HelloX Markdown/asset one.png")
        #expect(MarkdownLocalImageScheme.fileURL(
            for: try #require(URL(string: "hellox-markdown-image://example.com/tmp/image.png"))
        ) == nil)
    }

    @Test func localImageSchemeConfinesFilesToTheDocumentDirectory() throws {
        let fileManager = FileManager.default
        let parentDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("HelloX-MarkdownSecurityTests-\(UUID().uuidString)", isDirectory: true)
        let documentDirectory = parentDirectory.appendingPathComponent("Document", isDirectory: true)
        let assetDirectory = documentDirectory.appendingPathComponent("Assets", isDirectory: true)
        try fileManager.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: parentDirectory) }

        let localImageURL = assetDirectory.appendingPathComponent("local.png")
        let outsideImageURL = parentDirectory.appendingPathComponent("outside.png")
        let symlinkURL = assetDirectory.appendingPathComponent("linked.png")
        try Data([0]).write(to: localImageURL)
        try Data([0]).write(to: outsideImageURL)
        try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideImageURL)

        #expect(MarkdownLocalImageScheme.resolvedFileURL(
            localImageURL,
            containedIn: documentDirectory
        )?.path == localImageURL.path)
        #expect(MarkdownLocalImageScheme.resolvedFileURL(
            documentDirectory.appendingPathComponent("../outside.png"),
            containedIn: documentDirectory
        ) == nil)
        #expect(MarkdownLocalImageScheme.resolvedFileURL(
            symlinkURL,
            containedIn: documentDirectory
        ) == nil)
    }

    @Test @MainActor func webPreviewLoadsRelativeLocalImage() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("HelloX-MarkdownPreviewTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("local image.png")
        try makePNGData(width: 2, height: 3).write(to: imageURL)

        let model = MarkdownPreviewModel()
        model.render(
            markdown: "![Local image](local%20image.png)",
            title: "Local image test",
            baseURL: directory
        )

        let size = try await waitForImageSize(in: model.webView)
        #expect(size == [2, 3])
    }

    @Test @MainActor func webPreviewLoadsTheReadmeImage() async throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readmeURL = repositoryURL.appendingPathComponent("README.md")
        let markdown = try String(contentsOf: readmeURL, encoding: .utf8)
        let iconData = try Data(contentsOf: repositoryURL.appendingPathComponent("docs/assets/hellox-icon.png"))
        let icon = try #require(NSBitmapImageRep(data: iconData))
        let model = MarkdownPreviewModel()

        model.render(markdown: markdown, title: "README", baseURL: repositoryURL)

        let size = try await waitForImageSize(in: model.webView)
        #expect(size == [icon.pixelsWide, icon.pixelsHigh])
    }

    @Test @MainActor func webPreviewQueuesAdditionalLocalImages() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("HelloX-MarkdownQueueTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let pngData = try makePNGData(width: 2, height: 2)
        for index in 0..<5 {
            try pngData.write(to: directory.appendingPathComponent("image-\(index).png"))
        }
        let markdown = (0..<5).map { "![Image \($0)](image-\($0).png)" }.joined(separator: "\n\n")
        let model = MarkdownPreviewModel()

        model.render(markdown: markdown, title: "Image queue", baseURL: directory)

        let loadedImageCount = try await waitForLoadedImageCount(in: model.webView, expected: 5)
        #expect(loadedImageCount == 5)
    }

    @Test @MainActor func imagesOpenZoomAndCloseInThePreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelloX-ImageViewer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try makePNGData(width: 1200, height: 900).write(to: directory.appendingPathComponent("image.png"))
        let model = MarkdownPreviewModel()
        model.webView.setFrameSize(NSSize(width: 800, height: 600))
        model.render(markdown: "![示例图片](image.png)", title: "Images", baseURL: directory)
        #expect(try await waitForImageSize(in: model.webView) == [1200, 900])

        let opened = try await model.webView.evaluateJavaScript("""
        (() => {
          document.images[0].click();
          const viewer = document.getElementById('hx-image-viewer');
          return [viewer.open, viewer.querySelector('img').src === document.images[0].src,
                  viewer.querySelector('img').alt === '示例图片'];
        })();
        """) as? [Bool]
        #expect(opened == [true, true, true])
        let zoomed = try await model.webView.evaluateJavaScript("""
        (() => {
          const viewer = document.getElementById('hx-image-viewer');
          viewer.querySelector('[data-action=original]').click();
          return viewer.classList.contains('hx-original');
        })();
        """) as? Bool
        #expect(zoomed == true)
        let closed = try await model.webView.evaluateJavaScript("""
        (() => {
          const viewer = document.getElementById('hx-image-viewer');
          viewer.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true}));
          return !viewer.open;
        })();
        """) as? Bool
        #expect(closed == true)
        // Also exercise keyboard opening and PDF export while the viewer is open.
        _ = try await model.webView.evaluateJavaScript("""
        document.images[0].dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', bubbles:true})); true;
        """)
        let pdf = try await model.pdfData()
        #expect(pdf.starts(with: Data("%PDF".utf8)))
        #expect(try await model.webView.evaluateJavaScript("!document.getElementById('hx-image-viewer').open") as? Bool == true)
        #expect(!MarkdownHTMLConverter.convert("![Image](image.png)").contains("hx-image-viewer"))
    }

    @Test @MainActor func imageGalleryNavigatesScalesRotatesAndRestoresDocument() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelloX-ImageGallery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try makePNGData(width: 1200, height: 900).write(to: directory.appendingPathComponent("first.png"))
        try makePNGData(width: 400, height: 800).write(to: directory.appendingPathComponent("second.png"))
        let model = MarkdownPreviewModel()
        model.webView.setFrameSize(NSSize(width: 800, height: 600))
        model.render(markdown: "![First](first.png)\n\n![Second](second.png)", title: "Gallery", baseURL: directory)
        #expect(try await waitForLoadedImageCount(in: model.webView, expected: 2) == 2)
        let result = try await model.webView.evaluateJavaScript("""
        (() => {
          document.images[0].click();
          const viewer = document.getElementById('hx-image-viewer');
          const button = action => viewer.querySelector('[data-action="' + action + '"]');
          const label = () => viewer.querySelector('.hx-image-scale').textContent;
          const counter = () => viewer.querySelector('.hx-image-counter').textContent;
          const checks = [counter() === '1/2', button('previous').disabled,
                          !button('next').disabled, parseInt(label()) < 100];
          button('original').click();
          checks.push(label() === '100%');
          button('zoom-in').click();
          checks.push(label() === '125%', viewer.classList.contains('hx-pannable'));
          button('zoom-out').click();
          checks.push(label() === '100%');
          button('next').click();
          checks.push(counter() === '2/2', button('next').disabled,
                      viewer.querySelector('img').alt === 'Second');
          button('rotate').click();
          checks.push(viewer.querySelector('img').style.transform.includes('rotate(90deg)'));
          viewer.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowLeft', bubbles:true}));
          checks.push(counter() === '1/2', viewer.querySelector('img').alt === 'First',
                      viewer.querySelector('img').style.transform.includes('rotate(0deg)'));
          button('fit').click();
          const stage = viewer.querySelector('.hx-image-stage').getBoundingClientRect();
          const image = viewer.querySelector('img').getBoundingClientRect();
          checks.push(image.width <= stage.width + 1, image.height <= stage.height + 1);
          viewer.querySelector('.hx-image-stage').click();
          checks.push(!viewer.open);
          return checks;
        })();
        """) as? [Bool]
        #expect(result == Array(repeating: true, count: 18))
        // Wait for the dialog's asynchronous close event before checking cleanup.
        for _ in 0..<50 {
            if try await model.webView.evaluateJavaScript("document.documentElement.style.overflow !== 'hidden'") as? Bool == true {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(try await model.webView.evaluateJavaScript("document.documentElement.style.overflow !== 'hidden' && document.activeElement === document.images[0]") as? Bool == true)
    }

    @Test @MainActor func imageOverlayCoversWindowChromeAndRestoresPreview() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelloX-WindowImageViewer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try makePNGData(width: 1200, height: 900).write(to: directory.appendingPathComponent("image.png"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = try #require(window.contentView)
        let model = MarkdownPreviewModel()
        defer { model.imageOverlay.dismiss(); window.close() }
        // Reproduce the inset document column, leaving native header/sidebar space.
        model.webView.frame = NSRect(x: 240, y: 30, width: 730, height: 540)
        content.addSubview(model.webView)
        model.render(markdown: "# Manual\n![Image](image.png)\n" + String(repeating: "Text\n\n", count: 100),
                     title: "Window overlay", baseURL: directory)
        #expect(try await waitForImageSize(in: model.webView) == [1200, 900])
        for _ in 0..<100 {
            if try await model.webView.evaluateJavaScript("window.hxUsesWindowImageViewer === true") as? Bool == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        _ = try await model.webView.evaluateJavaScript("document.documentElement.style.scrollBehavior = 'auto'; window.scrollTo(0, 120); document.images[0].click();")
        for _ in 0..<100 {
            if let overlayWebView = model.imageOverlay.webView, !overlayWebView.isLoading,
               try await overlayWebView.evaluateJavaScript("document.getElementById('hx-image-viewer')?.open === true") as? Bool == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let overlay = try #require(model.imageOverlay.container)
        let overlayWebView = try #require(model.imageOverlay.webView)
        #expect(overlay.superview === content)
        #expect(content.subviews.last === overlay)
        #expect(overlay.frame == content.bounds)
        #expect(overlayWebView.frame == overlay.bounds)
        #expect(overlay.frame.width > model.webView.frame.width)
        #expect(overlay.frame.height > model.webView.frame.height)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(try await model.webView.evaluateJavaScript("!document.getElementById('hx-image-viewer').open") as? Bool == true)
        #expect(try await waitForImageSize(in: overlayWebView) == [1200, 900])
        window.setContentSize(NSSize(width: 1150, height: 850))
        #expect(overlay.frame == content.bounds)
        #expect(overlayWebView.frame == overlay.bounds)
        _ = try await overlayWebView.evaluateJavaScript("document.getElementById('hx-image-viewer').dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true}));")
        for _ in 0..<100 {
            if model.imageOverlay.container == nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(model.imageOverlay.container == nil)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(model.webView.superview === content)
        #expect(try await model.webView.evaluateJavaScript("window.scrollY") as? Int == 120)
    }

    @MainActor
    private func waitForImageSize(in webView: WKWebView) async throws -> [Int] {
        for _ in 0..<100 {
            let size = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[Int], any Error>) in
                webView.evaluateJavaScript(
                    "[document.images[0]?.naturalWidth || 0, document.images[0]?.naturalHeight || 0]"
                ) { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: result as? [Int] ?? [0, 0])
                    }
                }
            }
            if size[0] > 0, size[1] > 0 { return size }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return [0, 0]
    }

    @MainActor
    private func waitForLoadedImageCount(in webView: WKWebView, expected: Int) async throws -> Int {
        for _ in 0..<100 {
            let count = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Int, any Error>) in
                webView.evaluateJavaScript(
                    "Array.from(document.images).filter(image => image.naturalWidth > 0).length"
                ) { result, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: result as? Int ?? 0)
                    }
                }
            }
            if count >= expected { return count }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return 0
    }

    private func makePNGData(width: Int, height: Int) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
