import AppKit
import HelloXCore
import SwiftUI

struct IntelligenceSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var model: AppModel
    @State private var editingProfile: TranslationProfile?
    @State private var showsSystemLanguages = false
    @State private var operationError: String?
    @StateObject private var systemLanguages = SystemTranslationLanguagesModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            HXSettingsGroup(title: "通用") {
                HXSettingsRow(title: "截图翻译目标语言") {
                    HelloXLanguagePicker(title: "截图翻译目标语言", selection: Binding(
                        get: { model.screenshotTranslationTargetLanguage },
                        set: { model.setScreenshotTranslationTargetLanguage($0) }
                    ), includesAuto: false)
                }
                .id("translation-target")
                if !model.enabledTranslationProfiles.isEmpty {
                    HXSettingsDivider()
                    HXSettingsRow(title: "默认云端服务") {
                        HXDropdown(
                            "默认云端服务",
                            selection: Binding(
                                get: { model.defaultTranslationProfileID },
                                set: { if let id = $0 { model.setDefaultTranslationProfile(id) } }
                            ),
                            options: model.enabledTranslationProfiles.map {
                                HXDropdownOption(Optional($0.id), $0.name)
                            }
                        )
                        .frame(maxWidth: 220, alignment: .trailing)
                    }
                    .id("translation-default")
                }
            }
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("翻译服务").font(HXTypography.section)
                    Spacer(minLength: 12)
                    HXDropdownMenu("添加翻译服务", actions:
                        [TranslationVendor.zhipu, .baidu, .aliyun, .volcengine, .niutrans].map { vendor in
                            HXDropdownAction(vendor.displayName, image: TranslationServiceIcon.image(for: vendor)) {
                                editingProfile = TranslationProfile.preset(vendor)
                            }
                        }
                    )
                    .id("translation-add")
                }
                HXSettingsGroup(title: "", footer: "离线翻译无需配置凭证。云端服务的名称、模型和凭证可在详情中编辑。") {
                    HStack(spacing: 12) {
                        TranslationServiceIcon(vendor: .local, size: 24, logoSize: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("本地离线翻译")
                            Text("系统翻译 · 无需凭证").font(HXTypography.caption).foregroundStyle(HXTextStyle.secondary)
                        }
                        Spacer()
                        Button("可翻译语言") { showsSystemLanguages = true }
                            .help("查看系统支持的语言并配置语言包")
                            .id("translation-languages")
                        Toggle("使用本地离线翻译", isOn: Binding(
                            get: { model.isOfflineTranslationEnabled },
                            set: { enabled in
                                model.setOfflineTranslationEnabled(enabled)
                                operationError = model.isOfflineTranslationEnabled == enabled ? nil : model.lastError
                            }
                        ))
                        .labelsHidden().toggleStyle(HXSwitchStyle()).controlSize(.small)
                        .id("translation-offline")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    ForEach(model.translationProfiles) { profile in
                        HXSettingsDivider()
                        serviceRow(profile).id("translation-profile-" + profile.id.uuidString)
                    }
                }
            }
            .id("translation-services")
            if let operationError {
                HelloXStatusBanner(message: operationError, kind: .error)
            }
        }
        .font(HXTypography.body)
        .task { await systemLanguages.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await systemLanguages.refresh() }
        }
        .sheet(item: $editingProfile) { profile in
            TranslationProfileEditor(profile: profile, apiKey: model.apiKey(for: profile.id) ?? "")
                .environmentObject(model)
                .presentationBackground(HXDialogStyle.background(colorScheme))
                .presentationCornerRadius(HXDialogStyle.radius)
        }
        .sheet(isPresented: $showsSystemLanguages) {
            SystemTranslationLanguagesSheet(model: systemLanguages)
                .presentationBackground(HXDialogStyle.background(colorScheme))
                .presentationCornerRadius(HXDialogStyle.radius)
        }
    }

    private func serviceRow(_ profile: TranslationProfile) -> some View {
        HStack(spacing: 12) {
            TranslationServiceIcon(vendor: profile.vendor, size: 24, logoSize: 18)
            Button { editingProfile = profile } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name).foregroundStyle(HXTextStyle.primary)
                    Text(profile.vendor.displayName).font(HXTypography.caption).foregroundStyle(HXTextStyle.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("编辑 \(profile.name)")
            Button("详情") { editingProfile = profile }
            Toggle("启用 \(profile.name)", isOn: Binding(
                get: { profile.isEnabled },
                set: { enabled in
                    model.setTranslationProfileEnabled(profile.id, enabled: enabled)
                    let updated = model.translationProfiles.first { $0.id == profile.id }
                    operationError = updated?.isEnabled == enabled ? nil : model.lastError
                }
            ))
            .labelsHidden().toggleStyle(HXSwitchStyle()).controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

struct TranslationProfileEditor: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var profile: TranslationProfile
    @State var apiKey: String
    @State private var message: String?
    @State private var failed = false
    @State private var isTesting = false
    @State private var testTask: Task<Void, Never>?
    @State private var showsSetupGuide = false

    private var isExisting: Bool { model.translationProfiles.contains { $0.id == profile.id } }

    var body: some View {
        VStack(spacing: 0) {
            HXDialogHeader(
                title: isExisting ? "翻译服务详情" : "配置翻译服务",
                subtitle: profile.vendor.displayName,
                onClose: { dismiss() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HXSettingsGroup(title: "服务") {
                        VStack(alignment: .leading, spacing: 16) {
                            HXFormField("名称", text: $profile.name, placeholder: "输入服务名称")
                            if profile.vendor.requiresModel {
                                HXFormField("模型", text: $profile.model,
                                            placeholder: "例如 \(profile.vendor.defaultModel)")
                            }
                        }
                        .padding(16)
                    }
                    if let description = profile.vendor.freeQuotaDescription {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("官方免费说明")
                                .font(HXTypography.body)
                            Text(description)
                                .font(HXTypography.caption)
                                .foregroundStyle(HXTextStyle.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 12) {
                                Button("申请教程") { showsSetupGuide = true }
                                if let url = profile.vendor.registrationURL {
                                    Link("开通服务 / 获取凭证", destination: url)
                                }
                            }
                            .font(HXTypography.caption)
                        }
                    }
                    HXSettingsGroup(title: "凭证") {
                        VStack(alignment: .leading, spacing: 16) {
                            if [.volcengine, .aliyun].contains(profile.vendor) {
                                HXFormField("Access Key ID", text: optionBinding("accessKeyID"),
                                            placeholder: "输入 Access Key ID")
                            }
                            if [.niutrans, .baidu].contains(profile.vendor) {
                                HXFormField("APPID", text: optionBinding("appID"), placeholder: "输入 APPID")
                            }
                            HXFormField(credentialTitle, text: $apiKey,
                                        placeholder: "输入 \(credentialTitle)", isSecure: true)
                        }
                        .padding(16)
                    }
                }
                .padding(.horizontal, 20)
                .disabled(isTesting)
            }
            .codexScrollChrome()

            VStack(alignment: .leading, spacing: 12) {
                if let message {
                    Label {
                        Text(message)
                    } icon: {
                        HelloXIcon(icon: failed ? .warning : .success, size: 14)
                    }
                    .foregroundStyle(failed ? HelloXTheme.error : HelloXTheme.success)
                    .font(HXTypography.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if isTesting { ProgressView().controlSize(.small) }
                    Button(isTesting ? "测试中" : "测试连接", action: testConnection)
                        .disabled(isTesting)
                    if isExisting {
                        Button("删除服务", role: .destructive, action: deleteProfile)
                            .disabled(isTesting)
                    }
                    Spacer(minLength: 12)
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("保存", action: save)
                        .buttonStyle(HXDialogButtonStyle(primary: true))
                        .keyboardShortcut(.defaultAction).disabled(isTesting)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .font(HXTypography.body).frame(width: 560, height: profile.vendor.freeQuotaDescription == nil ? 480 : 600)
        // The sheet owns the outer clipping; a second rounded surface exposes
        // the system backing at the corners when their radii differ.
        .background(HXDialogStyle.background(colorScheme))
        .foregroundStyle(HXTextStyle.primary)
        .buttonStyle(HXDialogButtonStyle())
        .onDisappear { testTask?.cancel() }
        .sheet(isPresented: $showsSetupGuide) {
            TranslationSetupGuideView(vendor: profile.vendor)
                .presentationBackground(HXDialogStyle.background(colorScheme))
                .presentationCornerRadius(HXDialogStyle.radius)
        }
    }

    private func deleteProfile() {
        let alert = HelloXAlert()
        alert.messageText = "删除“\(profile.name)”？"
        alert.informativeText = "删除后，此服务将不再用于翻译。你可以重新添加服务。"
        alert.addButton(withTitle: "删除服务")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.deleteTranslationProfile(profile.id)
        if !model.translationProfiles.contains(where: { $0.id == profile.id }) { dismiss() }
        else { failed = true; message = model.lastError }
    }

    private var credentialTitle: String {
        profile.vendor.credentialTitle
    }

    private func optionBinding(_ key: String) -> Binding<String> {
        Binding(get: { profile.options[key] ?? "" }, set: { profile.options[key] = $0 })
    }
    private func save() {
        do {
            guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw HelloXError.invalidConfiguration("配置名称不能为空")
            }
            if profile.isEnabled { try profile.validate(hasAPIKey: !apiKey.isEmpty) }
            model.saveTranslationProfile(profile, apiKey: apiKey)
            dismiss()
        } catch { failed = true; message = error.localizedDescription }
    }
    private func testConnection() {
        message = nil; failed = false; isTesting = true
        let draft = profile
        let key = apiKey
        testTask = Task { @MainActor in
            defer { isTesting = false }
            do {
                let provider = try TranslationProviderFactory.make(profile: draft, apiKey: key)
                let started = Date()
                _ = try await provider.translate(TranslationRequest(text: "Hello", sourceLanguage: .english, targetLanguage: .simplifiedChinese))
                guard !Task.isCancelled else { return }
                message = "连接成功 · \(Int(Date().timeIntervalSince(started) * 1000)) ms"
            } catch {
                guard !Task.isCancelled else { return }
                failed = true; message = error.localizedDescription
            }
        }
    }
}

struct TranslationSetupGuideView: View {
    let vendor: TranslationVendor
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HXDialogHeader(title: "密钥申请教程", subtitle: vendor.displayName, onClose: { dismiss() })
            ScrollView {
                if let guide = vendor.setupGuide {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("申请步骤").font(HXTypography.section)
                            ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(index + 1).")
                                        .foregroundStyle(HXTextStyle.secondary)
                                        .frame(width: 18, alignment: .leading)
                                    Text(step).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            HStack(spacing: 12) {
                                Link("开通服务 / 获取凭证", destination: guide.registrationURL)
                                Link("官方操作指南", destination: guide.instructionsURL)
                            }
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("官方免费说明").font(HXTypography.section)
                            Text(guide.freePolicy).fixedSize(horizontal: false, vertical: true)
                            Text("核对日期：" + TranslationSetupGuide.verifiedDate + " · 最新规则以官方为准")
                                .font(HXTypography.caption).foregroundStyle(HXTextStyle.secondary)
                            Link("查看官方额度与计费说明", destination: guide.pricingURL)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("确认配置成功").font(HXTypography.section)
                            Text("返回配置页，点击「测试连接」。出现「连接成功」后保存，再启用该服务；需要默认使用时，在「默认云端服务」中选择它。")
                                .fixedSize(horizontal: false, vertical: true)
                            Text("测试会发送真实翻译请求并按服务商规则消耗额度。HelloX 不读取剩余额度，也不会在免费额度耗尽时自动停用服务。")
                                .font(HXTypography.caption).foregroundStyle(HXTextStyle.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 16)
                    .textSelection(.enabled)
                }
            }
            .codexScrollChrome()
            HStack {
                Spacer()
                Button("返回配置") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(HXDialogButtonStyle(primary: true))
            }
            .padding(20)
        }
        .frame(width: 560, height: 640)
        .font(HXTypography.body)
        .foregroundStyle(HXTextStyle.primary)
        .background(HXDialogStyle.background(colorScheme))
        .buttonStyle(HXDialogButtonStyle())
    }
}
