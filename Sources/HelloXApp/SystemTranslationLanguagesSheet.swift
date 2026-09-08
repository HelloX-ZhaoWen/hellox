import AppKit
import SwiftUI

struct SystemTranslationLanguagesSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: SystemTranslationLanguagesModel
    @State private var operationError: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        VStack(spacing: 0) {
            HXDialogHeader(
                title: "可翻译语言",
                subtitle: model.hasLoaded ? "macOS 系统翻译 · \(model.languages.count) 种语言" : "macOS 系统翻译",
                onClose: { dismiss() }
            )
            ScrollView {
                if model.isLoading && !model.hasLoaded {
                    ProgressView("正在读取可翻译语言…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if model.languages.isEmpty {
                    VStack(spacing: 12) {
                        Text("暂未读取到系统支持的语言")
                        Button("重新读取") { Task { await model.refresh() } }
                    }
                    .foregroundStyle(HXTextStyle.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(model.languages) { language in
                            Text(language.name)
                                .font(HXTypography.body)
                                .multilineTextAlignment(.center)
                                .padding(10)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .aspectRatio(1, contentMode: .fit)
                                .background(HelloXTheme.surface(for: colorScheme),
                                            in: RoundedRectangle(cornerRadius: 12))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(HelloXTheme.border(for: colorScheme), lineWidth: 1)
                                }
                        }
                    }
                }
            }
            .codexScrollChrome()
            .padding(.horizontal, HXDialogStyle.padding)
            VStack(alignment: .leading, spacing: 12) {
                Text("离线使用前，请在 macOS 中下载所需语言包。语言包的下载与移除由系统管理。")
                    .font(HXTypography.caption)
                    .foregroundStyle(HXTextStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let operationError {
                    HelloXStatusBanner(message: operationError, kind: .error)
                }
                HStack {
                    Button("配置语言") {
                        operationError = SystemTranslationSettings.open() ? nil
                            : "无法打开系统设置。请前往“通用 → 语言与地区 → 翻译语言”管理语言包。"
                    }
                    .help("打开 macOS 翻译语言设置")
                    Spacer()
                    Button("完成") { dismiss() }
                        .buttonStyle(HXDialogButtonStyle(primary: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(HXDialogStyle.padding)
        }
        .frame(width: 620, height: 560)
        .background(HXDialogStyle.background(colorScheme))
        .foregroundStyle(HXTextStyle.primary)
        .buttonStyle(HXDialogButtonStyle())
        .onExitCommand { dismiss() }
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }
}
