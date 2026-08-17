import HelloXCore
import SwiftUI

struct IntelligenceSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedID: UUID?
    @State private var editingProfile: TranslationProfile?
    @State private var testMessage = ""
    @State private var testFailed = false
    @State private var isTesting = false

    var body: some View {
        profilesPage
        .tint(HelloXTheme.accent)
        .onAppear {
            selectedID = model.defaultTranslationProfileID ?? model.translationProfiles.first?.id
        }
        .sheet(item: $editingProfile) { profile in
            TranslationProfileEditor(
                profile: profile,
                apiKey: model.apiKey(for: profile.id) ?? "",
                onSave: { updated, key in
                    model.saveTranslationProfile(updated, apiKey: key)
                    selectedID = updated.id
                    editingProfile = nil
                },
                onCancel: { editingProfile = nil }
            )
        }
    }

    private var profilesPage: some View {
        HStack(alignment: .top, spacing: 14) {
            profileList
                .frame(width: 300)
            profileDetail
                .frame(maxWidth: .infinity)
        }
    }

    private var profileList: some View {
        HelloXCard(padding: 0, showsBorder: false) {
            VStack(spacing: 0) {
                HStack {
                    Text("翻译配置")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    if let defaultProfile = model.translationProfiles.first(where: { $0.id == model.defaultTranslationProfileID }) {
                        Text("默认：\(defaultProfile.name)")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(HelloXTheme.accent)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .background(HelloXTheme.selectedBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: 7))
                            .lineLimit(1)
                    }
                    Menu {
                        ForEach(availableVendors) { vendor in
                            Button(vendor.displayName) {
                                let profile = model.addTranslationProfile(vendor)
                                selectedID = profile.id
                                editingProfile = profile
                            }
                        }
                    } label: {
                        HelloXIcon(icon: .add, size: 15)
                            .frame(width: 36, height: 36)
                            .background(HelloXTheme.selectedBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.compactRadius))
                    }
                    .menuStyle(.borderlessButton)
                    .help("新增翻译配置")
                }
                .padding(14)

                HStack(spacing: 10) {
                    HelloXRowIcon(icon: .translation, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("离线翻译")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Spacer()
                    Text(model.isOfflineTranslationEnabled ? "已启用" : "未启用")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(model.isOfflineTranslationEnabled ? HelloXTheme.success : HelloXTheme.secondaryText(for: colorScheme))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background((model.isOfflineTranslationEnabled ? HelloXTheme.success : HelloXTheme.secondaryText(for: colorScheme)).opacity(0.10), in: Capsule())
                    Toggle(isOn: Binding(
                        get: { model.isOfflineTranslationEnabled },
                        set: { model.setOfflineTranslationEnabled($0) }
                    )) {
                        Text("启用")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .toggleStyle(.switch)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

                if model.lastError == "至少保留一个启用的翻译服务。" {
                    HelloXStatusBanner(message: model.lastError!, kind: .error)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }

                if model.translationProfiles.isEmpty {
                    VStack(spacing: 8) {
                        HelloXIcon(icon: .intelligence, size: 26)
                            .foregroundStyle(HelloXTheme.accent)
                        Text("尚无云端翻译配置")
                            .font(.system(size: 12, weight: .semibold))
                        Text(model.isOfflineTranslationEnabled ? "离线翻译已启用" : "请启用至少一个翻译服务")
                            .font(.system(size: 10))
                            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                    }
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    VStack(spacing: 4) {
                        ForEach(model.translationProfiles) { profile in
                            profileButton(profile)
                        }
                    }
                    .padding(8)
                }
            }
            .frame(minHeight: 500, alignment: .top)
        }
    }

    private func profileButton(_ profile: TranslationProfile) -> some View {
        let selected = profile.id == selectedID
        return Button { selectedID = profile.id } label: {
            HStack(spacing: 10) {
                HelloXRowIcon(icon: .cloud, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(profile.vendor.displayName)
                        .font(.system(size: 10))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                }
                Spacer(minLength: 2)
                Circle()
                    .fill(profile.isEnabled ? HelloXTheme.success : HelloXTheme.secondaryText(for: colorScheme).opacity(0.45))
                    .frame(width: 7, height: 7)
            }
            .padding(.horizontal, 10)
            .frame(height: 56)
            .foregroundStyle(selected ? HelloXTheme.accent : HelloXTheme.primaryText(for: colorScheme))
            .background(selected ? HelloXTheme.selectedBackground(for: colorScheme) : Color.clear, in: RoundedRectangle(cornerRadius: HelloXTheme.controlRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var profileDetail: some View {
        if let profile = selectedProfile {
            HelloXCard(showsBorder: false) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        HelloXRowIcon(icon: .cloud, size: 46)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name)
                                .font(.system(size: 18, weight: .bold))
                            Text("\(profile.vendor.displayName) · \(profile.isEnabled ? "已启用" : "未启用")")
                                .font(.system(size: 11))
                                .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                        }
                        Spacer()
                        Toggle(isOn: Binding(
                            get: { profile.isEnabled },
                            set: { model.setTranslationProfileEnabled(profile.id, enabled: $0) }
                        )) {
                            Text("启用")
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .toggleStyle(.switch)
                        .fixedSize(horizontal: true, vertical: false)
                    }

                    VStack(spacing: 14) {
                        profileField("配置名称", profile.name)
                        profileField("Base URL", profile.baseURL)
                        HStack(spacing: 12) {
                            if profile.vendor.requiresModel {
                                profileField("模型", profile.model.isEmpty ? "未设置" : profile.model)
                            }
                            if profile.vendor == .volcengine {
                                profileField("Access Key ID", accessKeyIDDisplayValue(for: profile))
                            }
                            if profile.vendor == .niutrans {
                                profileField("APPID", appIDDisplayValue(for: profile))
                            }
                            profileField(
                                profile.vendor == .volcengine ? "Secret Access Key" : profile.vendor == .niutrans ? "APIKEY" : "API Key",
                                model.hasAPIKey(for: profile.id) ? "••••••••••••••••" : "未设置"
                            )
                        }
                    }

                    HStack(alignment: .top, spacing: 9) {
                        HelloXIcon(icon: .privacy, size: 15)
                            .foregroundStyle(HelloXTheme.accent)
                        Text("云端凭证保存在 HelloX 应用配置中。云端翻译只发送需要翻译的文本，不上传原始截图。")
                            .font(.system(size: 10.5))
                            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HelloXTheme.controlBackground(for: colorScheme), in: RoundedRectangle(cornerRadius: HelloXTheme.controlRadius))

                    Spacer(minLength: 8)

                    HStack(spacing: 9) {
                        HelloXIconButton(icon: .pen, help: "编辑配置", isBorderless: true) {
                            editingProfile = profile
                        }
                        HelloXIconButton(icon: .copy, help: "复制配置", isBorderless: true) {
                            let copy = model.duplicateTranslationProfile(profile.id)
                            selectedID = copy?.id
                        }
                        if profile.id != model.defaultTranslationProfileID {
                            HelloXIconButton(icon: .success, help: "设为默认", isBorderless: true) {
                                model.setDefaultTranslationProfile(profile.id)
                            }
                        }
                        HelloXIconButton(icon: .close, help: "删除配置", role: .destructive, isBorderless: true) {
                            model.deleteTranslationProfile(profile.id)
                            selectedID = model.defaultTranslationProfileID ?? model.translationProfiles.first?.id
                        }
                        Spacer()
                        HelloXIconButton(icon: .play, help: "测试连接", role: .accent) {
                            test(profile)
                        }
                            .disabled(isTesting)
                    }

                    if isTesting {
                        ProgressView("正在测试…")
                            .controlSize(.small)
                    }
                    if !testMessage.isEmpty {
                        HelloXStatusBanner(
                            message: testMessage,
                            kind: testFailed ? .error : .success
                        )
                    }
                }
                .frame(minHeight: 460, alignment: .top)
            }
        } else {
            HelloXCard(showsBorder: false) {
                VStack(spacing: 12) {
                    HelloXRowIcon(icon: .intelligence, size: 48)
                    Text("请选择一个翻译配置")
                        .font(.system(size: 15, weight: .bold))
                    Text("从左侧选择现有配置，或新建一个服务。")
                        .font(.system(size: 11))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
    }

    private var selectedProfile: TranslationProfile? {
        model.translationProfiles.first { $0.id == selectedID }
    }

    private var availableVendors: [TranslationVendor] { [.zhipu, .volcengine, .niutrans] }

    private func profileField(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
            Text(value)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .background(HelloXTheme.surface(for: colorScheme), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accessKeyIDDisplayValue(for profile: TranslationProfile) -> String {
        let value = profile.options["accessKeyID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "未设置" : value
    }

    private func appIDDisplayValue(for profile: TranslationProfile) -> String {
        let value = profile.options["appID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "未设置" : value
    }

    private func test(_ profile: TranslationProfile) {
        isTesting = true
        testMessage = ""
        testFailed = false
        let started = Date()
        Task { @MainActor in
            defer { isTesting = false }
            do {
                let request = TranslationRequest(text: "Hello", sourceLanguage: .english, targetLanguage: .simplifiedChinese)
                _ = try await model.provider(for: request, profileID: profile.id).translate(request)
                testMessage = "连接成功 · \(Int(Date().timeIntervalSince(started) * 1_000)) ms"
            } catch {
                testFailed = true
                testMessage = error.localizedDescription
            }
        }
    }
}

private struct TranslationProfileEditor: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var profile: TranslationProfile
    @State private var apiKey: String
    let onSave: (TranslationProfile, String) -> Void
    let onCancel: () -> Void

    init(
        profile: TranslationProfile,
        apiKey: String,
        onSave: @escaping (TranslationProfile, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _profile = State(initialValue: profile)
        _apiKey = State(initialValue: apiKey)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HelloXCard(showsBorder: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(credentialDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                    TextField("名称", text: $profile.name)
                        .textFieldStyle(.plain)
                        .helloXBorderlessFieldChrome()
                    Picker("厂商", selection: $profile.vendor) {
                        ForEach([TranslationVendor.zhipu, .volcengine, .niutrans]) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .pickerStyle(.menu)
                    .buttonStyle(.borderless)
                    .onChange(of: profile.vendor) { _, vendor in
                        profile.baseURL = vendor.defaultBaseURL
                        profile.model = vendor.defaultModel
                        profile.isEnabled = false
                    }
                    TextField("Base URL", text: $profile.baseURL)
                        .textFieldStyle(.plain)
                        .helloXBorderlessFieldChrome()
                    if profile.vendor.requiresModel {
                        TextField("模型", text: $profile.model)
                            .textFieldStyle(.plain)
                            .helloXBorderlessFieldChrome()
                    }
                    if profile.vendor == .volcengine {
                        TextField("Access Key ID", text: Binding(
                            get: { profile.options["accessKeyID"] ?? "" },
                            set: { profile.options["accessKeyID"] = $0 }
                        ))
                            .textFieldStyle(.plain)
                            .helloXBorderlessFieldChrome()
                        SecureField("Secret Access Key", text: $apiKey)
                            .textFieldStyle(.plain)
                            .helloXBorderlessFieldChrome()
                    } else {
                        if profile.vendor == .niutrans {
                            TextField("APPID", text: Binding(
                                get: { profile.options["appID"] ?? "" },
                                set: { profile.options["appID"] = $0 }
                            ))
                                .textFieldStyle(.plain)
                                .helloXBorderlessFieldChrome()
                        }
                        SecureField(profile.vendor == .niutrans ? "APIKEY" : "API Key", text: $apiKey)
                            .textFieldStyle(.plain)
                            .helloXBorderlessFieldChrome()
                    }
                }
            }

            HStack {
                Spacer()
                HelloXIconButton(icon: .close, help: "取消", role: .destructive, isBorderless: true, action: onCancel)
                HelloXIconButton(icon: .confirm, help: "保存配置", role: .accent) {
                    onSave(profile, apiKey)
                }
            }
        }
        .padding(24)
        .frame(width: 560, height: 430)
        .background(HelloXGlowBackground())
        .tint(HelloXTheme.accent)
    }

    private var credentialDescription: String {
        switch profile.vendor {
        case .volcengine:
            return "Access Key ID 和 Secret Access Key 将保存在 HelloX 应用配置中（不使用 macOS 钥匙串）。"
        case .niutrans:
            return "APPID 和 APIKEY 将保存在 HelloX 应用配置中（不使用 macOS 钥匙串）。"
        default:
            return "API Key 将保存在 HelloX 应用配置中（不使用 macOS 钥匙串）。"
        }
    }
}
