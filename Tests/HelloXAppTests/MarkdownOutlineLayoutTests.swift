import AppKit
import SwiftUI
import Testing
@testable import HelloXApp

@MainActor
@Suite(.serialized)
struct MarkdownOutlineLayoutTests {
    /// Opt-in samples exercise the production component and document collapse state.
    @Test func renderCompactOutlineSamples() async throws {
        guard let directory = ProcessInfo.processInfo.environment["HELLOX_UI_SNAPSHOTS"] else { return }
        HXTypography.configureRendering()
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        let savedAppearance = app.appearance
        defer { app.appearance = savedAppearance }

        let deepMarkdown = """
        # 工单系统操作手册
        ## 一、Dashboard 数据看板
        ### 数据指标与筛选
        ## 二、Tickets 工单管理
        ### 查看与处理工单
        ## 三、Settings 系统设置
        ### 1. Channel 页面
        #### 1.1 查看渠道列表
        #### 1.2 搜索和筛选渠道
        #### 1.3 新增渠道
        ##### 1.3.1 选择平台并填写 Gmail 渠道信息
        ###### 1.3.1.1 配置超长的渠道名称与完整身份验证信息并检查连接状态
        ##### 1.3.2 选择认证方式和提交配置
        #### 1.4 渠道状态与维护入口
        ### 2. User 页面
        #### 2.1 查看用户列表
        #### 2.2 按部门与关键词查找用户
        # 附录
        """
        let samples: [(name: String, markdown: String, expanded: Bool, collapsed: [String])] = [
            ("shallow", "# 入门\n## 安装\n## 首次使用\n# 日常操作\n## 快捷键\n## 常见问题", true, []),
            ("deep-long", deepMarkdown, true, []),
            ("branch-collapsed", deepMarkdown, true, ["heading-6", "heading-2"]),
            ("collapsed", deepMarkdown, false, []),
            ("empty", "没有标题的普通正文。", true, [])
        ]

        for scheme in [ColorScheme.light, .dark] {
            app.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            for sample in samples {
                let document = MarkdownDocumentTab(url: nil, markdown: sample.markdown)
                document.isTableOfContentsExpanded = sample.expanded
                sample.collapsed.forEach(document.toggleHeading)
                let width: CGFloat = sample.expanded ? 230 : 44
                let size = NSSize(width: width, height: 620)
                let content = MarkdownTableOfContents(document: document)
                    .frame(width: size.width, height: size.height)
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: content)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.close() }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(120))
                host.layoutSubtreeIfNeeded()
                #expect(host.bounds.size == size)
                #expect(window.contentRect(forFrameRect: window.frame).size == size)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let name = "markdown-outline-\(sample.name)-\(scheme == .dark ? "dark" : "light").png"
                try png.write(to: output.appendingPathComponent(name))
            }
        }
    }
}
