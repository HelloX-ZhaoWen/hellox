import AppKit
import HelloXCore
import SwiftUI

enum SettingsDestination: String, CaseIterable, Identifiable {
    case workbench, shortcuts, intelligence, software

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workbench: "工作台"
        case .shortcuts: "快捷键"
        case .intelligence: "翻译配置"
        case .software: "软件与更新"
        }
    }

    var subtitle: String {
        switch self {
        case .workbench: "快速使用截图、图片处理与常用转换工具。"
        case .shortcuts: "录入后立即验证并生效，无需单独保存。"
        case .intelligence: "管理 AI 翻译服务和连接配置。"
        case .software: "查看版本信息，并安全检查软件更新。"
        }
    }

    var icon: HelloXIconKey {
        switch self {
        case .workbench: .capture
        case .shortcuts: .shortcuts
        case .intelligence: .translation
        case .software: .settings
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            HelloXGlowBackground()
                .ignoresSafeArea()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 236)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(HelloXTheme.accent)
        .frame(minWidth: 960, minHeight: 660)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("HelloX")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                    Text(HelloXBrand.slogan)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)
            .padding(.bottom, 30)

            VStack(spacing: 6) {
                ForEach(SettingsDestination.allCases) { destination in
                    SettingsSidebarButton(
                        destination: destination,
                        isSelected: model.mainDestination == destination,
                        action: { model.mainDestination = destination }
                    )
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(HelloXTheme.success)
                    .frame(width: 7, height: 7)
                Text("版本 \(model.currentVersion)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
            }
            .padding(18)
        }
        .frame(maxHeight: .infinity)
        .background(HelloXTheme.surface(for: colorScheme))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(HelloXTheme.border(for: colorScheme))
                .frame(width: 1)
        }
    }

    private var detail: some View {
        let destination = model.mainDestination
        return ScrollView(.vertical, showsIndicators: false) {
            Group {
                switch destination {
                case .workbench: workbenchPage
                case .shortcuts: shortcutsPage
                case .intelligence:
                    VStack(alignment: .leading, spacing: 20) {
                        pageHeader("翻译配置", subtitle: "管理云端翻译服务、模型和连接凭据")
                        IntelligenceSettingsView()
                    }
                case .software: softwarePage
                }
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(.horizontal, 42)
            .padding(.top, 42)
            .padding(.bottom, 46)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollContentBackground(.hidden)
        .seamlessScrollChrome()
    }

    private var workbenchPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            pageHeader("工作台", subtitle: "选择一项任务，立即开始处理")

            HStack(spacing: 12) {
                primaryCaptureCard
                recordingCard
                    .frame(width: 275)
            }

            VStack(alignment: .leading, spacing: 11) {
                sectionHeader("文字智能", trailing: "输入、截图或划词，快速获得译文")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    textActionButton(
                        "文字提取",
                        detail: "识别屏幕中的文字并复制",
                        icon: .textRecognition,
                        action: model.captureAndOCR
                    )
                    textActionButton(
                        "文本翻译",
                        detail: "输入或粘贴文字，多模型同时翻译",
                        icon: .translation,
                        action: model.showTextTranslation
                    )
                    textActionButton(
                        "截图翻译",
                        detail: "框选屏幕文字并直接翻译",
                        icon: .translation,
                        action: model.captureAndTranslate
                    )
                    textActionButton(
                        "划词翻译",
                        detail: "读取当前选区并显示译文",
                        icon: .translation,
                        action: model.translateSelectedText
                    )
                }
            }

            VStack(alignment: .leading, spacing: 11) {
                sectionHeader("效率工具", trailing: "6 项本地工具")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                    utilityButton("图片加水印", detail: "添加文字或图片水印", icon: .watermark, action: model.importImageForWatermark)
                    utilityButton("CSV 转 Excel", detail: "导出标准 XLSX 工作簿", icon: .save) { model.showUtilityTool(.csvToExcel) }
                    utilityButton("Base64 转换", detail: "文本编码与解码", icon: .copy) { model.showUtilityTool(.base64) }
                    utilityButton("二维码识别", detail: "从图片中读取二维码", icon: .qrCode) { model.showUtilityTool(.qrCode) }
                    utilityButton("密码生成", detail: "生成安全随机密码", icon: .privacy) { model.showUtilityTool(.password) }
                    utilityButton("Markdown 转换", detail: "实时预览并导出 HTML", icon: .text) { model.showUtilityTool(.markdown) }
                }
            }
        }
    }

    private var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageHeader("全局快捷键", subtitle: "录入后立即验证并生效，无需单独保存")
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("快捷键列表")
                        .font(.system(size: 14, weight: .semibold))
                    Text("点击右侧录入框后按下组合键")
                        .font(.system(size: 11))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                }
                Spacer()
                Button(action: model.resetAllShortcuts) {
                    Text("恢复默认")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(
                            HelloXTheme.controlBackground(for: colorScheme),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help("将全部快捷键恢复为默认值")
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible())
                ],
                spacing: 10
            ) {
                ForEach(ShortcutAction.configurableCases) { action in
                    shortcutRow(action)
                }
            }
        }
    }

    private var softwarePage: some View {
        VStack(alignment: .leading, spacing: 22) {
            pageHeader("软件与更新", subtitle: "查看版本信息，并安全检查正式版本更新")
            HelloXCard(showsBorder: false) {
                HStack(spacing: 18) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("HelloX")
                            .font(.system(size: 21, weight: .bold))
                        Text("版本 \(model.currentVersion)")
                            .font(.system(size: 12))
                            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                        Text(HelloXBrand.slogan)
                            .font(.system(size: 12))
                            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                    }
                }
            }

            HelloXSection(title: "权限状态", showsBorder: false) {
                VStack(spacing: 10) {
                    permissionRow(
                        icon: .screen,
                        title: "屏幕录制",
                        subtitle: "截图和录屏需要此权限",
                        granted: model.permissions.canRecordScreen,
                        action: { model.permissions.openScreenRecordingSettings() }
                    )
                    permissionRow(
                        icon: .capture,
                        title: "辅助功能",
                        subtitle: "滚动截图和文字翻译需要此权限",
                        granted: model.permissions.canUseAccessibility,
                        action: { model.permissions.openAccessibilitySettings() }
                    )
                }
            }

            HelloXSection(title: "软件更新", showsBorder: false) {
                HStack(spacing: 13) {
                    HelloXRowIcon(icon: .update, size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.updateState.message ?? "从 GitHub Releases 检查正式版本")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(updateMessageColor)
                        Text("安装前会验证完整性、签名、公证和双架构。")
                            .font(.system(size: 11))
                            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                    }
                    Spacer()
                    if isUpdating { ProgressView().controlSize(.small) }
                    if case .available = model.updateState {
                        HelloXIconButton(icon: .save, help: "立即更新", role: .accent) { model.installAvailableUpdate() }
                            .disabled(isUpdating)
                    } else {
                        HelloXIconButton(icon: .update, help: "检查更新", isBorderless: true) { model.checkForUpdates() }
                            .disabled(isUpdating)
                    }
                }
            }

            HelloXSection(title: "项目链接", showsBorder: false) {
                HStack(spacing: 22) {
                    Link(destination: URL(string: "https://github.com/HelloX/HelloX")!) {
                        HStack(spacing: 7) { HelloXIcon(icon: .link, size: 15); Text("项目主页") }
                    }
                    Link(destination: URL(string: "https://github.com/HelloX/HelloX#隐私与数据")!) {
                        HStack(spacing: 7) { HelloXIcon(icon: .privacy, size: 15); Text("隐私说明") }
                    }
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
    }

    private var primaryCaptureCard: some View {
        Button { model.startCapture(.region) } label: {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("区域截图")
                        .font(.system(size: 20, weight: .bold))
                    Text("自由框选屏幕区域并直接标注")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.80))
                }
                Spacer()
                HelloXIcon(icon: .capture, size: 32)
                    .frame(width: 72, height: 72)
                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(
                LinearGradient(colors: [HelloXTheme.accent, Color(red: 76 / 255, green: 154 / 255, blue: 245 / 255)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: HelloXTheme.cardRadius, style: .continuous)
            )
            .shadow(color: HelloXTheme.accent.opacity(0.18), radius: 14, y: 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!model.isBusy)
        .accessibilityLabel("区域截图，自由框选屏幕区域并直接标注")
    }

    private var recordingCard: some View {
        Button(action: model.startScreenRecording) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    HelloXRowIcon(icon: .recording, size: 42)
                    Spacer()
                    Text(model.shortcutBindings[.screenRecording]?.displayName ?? "未设置")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                        .padding(.horizontal, 8)
                        .frame(height: 25)
                        .background(HelloXTheme.controlBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 7))
                }
                Spacer()
                Text("选区录屏")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                Text("框选区域并录制为 MP4")
                    .font(.system(size: 11))
                    .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                    .padding(.top, 3)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
            .background(HelloXTheme.raisedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.cardRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!model.isBusy)
    }

    private func textActionButton(
        _ title: String,
        detail: String,
        icon: HelloXIconKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                HelloXRowIcon(icon: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                }
                Spacer(minLength: 8)
                HelloXIcon(icon: .chevronRight, size: 15)
                    .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme).opacity(0.75))
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(HelloXTheme.raisedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.cardRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!model.isBusy)
    }

    private func utilityButton(
        _ title: String,
        detail: String,
        icon: HelloXIconKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                HelloXRowIcon(icon: icon, size: 34)
                    .background(HelloXTheme.raisedSurface(for: colorScheme), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: 66)
            .background(HelloXTheme.controlBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!model.isBusy)
    }

    private func pageHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
            Text(subtitle)
                .font(.system(size: 12.5))
                .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
        }
    }

    private func sectionHeader(_ title: String, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
            Spacer()
            Text(trailing)
                .font(.system(size: 10.5))
                .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
        }
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                HelloXRowIcon(icon: action.icon, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(action.defaultBinding.map { "默认 \($0.displayName)" } ?? "默认未设置")
                        .font(.system(size: 11))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                }
                Spacer()
                ShortcutRecorder(
                    binding: Binding(
                        get: { model.shortcutBindings[action] },
                        set: { value in
                            if let value { model.setShortcut(action, binding: value) }
                            else { model.clearShortcut(action) }
                        }
                    ),
                    hasConflict: model.shortcutConflictMessages[action] != nil
                )
                .frame(width: 152, height: 32)
            }
            if let message = model.shortcutConflictMessages[action] {
                HStack(spacing: 6) {
                    HelloXIcon(icon: .warning, size: 14)
                    Text(message)
                }
                    .font(.system(size: 11))
                    .foregroundStyle(HelloXTheme.error)
                    .padding(.leading, 45)
                    .accessibilityLabel("快捷键冲突：\(message)")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .center)
        .background(
            HelloXTheme.controlBackground(for: colorScheme),
            in: RoundedRectangle(cornerRadius: HelloXTheme.controlRadius, style: .continuous)
        )
    }

    private func permissionRow(icon: HelloXIconKey, title: String, subtitle: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 13) {
            HelloXRowIcon(icon: icon, size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
            }
            Spacer()
            if granted {
                HStack(spacing: 5) {
                    HelloXIcon(icon: .success, size: 14)
                    Text("已授权")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(HelloXTheme.success)
            } else {
                HelloXIconButton(icon: .settings, help: "前往授权", role: .accent) { action() }
            }
        }
    }

    private var isUpdating: Bool {
        switch model.updateState {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    private var updateMessageColor: Color {
        if case .failed = model.updateState { return HelloXTheme.error }
        return HelloXTheme.primaryText(for: colorScheme)
    }
}

private struct SettingsSidebarButton: View {
    let destination: SettingsDestination
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                HelloXIcon(icon: destination.icon, size: 19)
                    .frame(width: 24)
                Text(destination.title)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                Spacer()
            }
            .foregroundStyle(isSelected ? HelloXTheme.accent : HelloXTheme.secondaryText(for: colorScheme))
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(
                isSelected
                    ? HelloXTheme.selectedBackground(for: colorScheme)
                    : (isHovering ? HelloXTheme.controlBackground(for: colorScheme) : Color.clear),
                in: RoundedRectangle(cornerRadius: HelloXTheme.controlRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension ShortcutAction {
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
        case .translateSelection: .translation
        case .csvToExcel: .save
        case .base64: .copy
        case .qrCode: .qrCode
        case .password: .privacy
        case .markdown: .text
        }
    }
}
