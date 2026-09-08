import Foundation
import HelloXCore

struct SettingsSearchResult: Identifiable {
    let id: String
    let title: String
    let destination: SettingsDestination
    var keywords = ""
    var location: String { destination.title + (id.hasPrefix("page-") ? "" : " › " + title) }
}

enum SettingsSearchIndex {
    static func results(for query: String, profiles: [TranslationProfile],
                        bindings: [ShortcutAction: ShortcutBinding]) -> [SettingsSearchResult] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }
        var entries = SettingsDestination.allCases.map {
            SettingsSearchResult(id: "page-" + $0.rawValue, title: $0.title, destination: $0)
        }
        entries += ShortcutAction.configurableCases.map {
            SettingsSearchResult(id: "shortcut-" + $0.rawValue, title: $0.settingsTitle,
                                 destination: .shortcuts,
                                 keywords: $0.settingsDescription + " " + (bindings[$0]?.displayName ?? ""))
        }
        entries += [
            .init(id: "shortcut-reset", title: "恢复默认快捷键", destination: .shortcuts, keywords: "重置"),
            .init(id: "island-enabled", title: "启用 Mac 灵动岛", destination: .dynamicIsland, keywords: "显示 开关"),
            .init(id: "island-fullscreen", title: "在全屏空间显示", destination: .dynamicIsland),
            .init(id: "island-refresh", title: "刷新正在运行的应用", destination: .dynamicIsland),
            .init(id: "island-apps", title: "运行中应用", destination: .dynamicIsland, keywords: "菜单栏 运行应用 置顶 排序"),
            .init(id: "island-tools", title: "HelloX 功能", destination: .dynamicIsland, keywords: "排序"),
            .init(id: "translation-target", title: "截图翻译目标语言", destination: .intelligence, keywords: "中文 英文"),
            .init(id: "translation-offline", title: "使用本地离线翻译", destination: .intelligence, keywords: "系统翻译"),
            .init(id: "translation-languages", title: "系统翻译语言配置", destination: .intelligence,
                  keywords: "可翻译语言 语言包 下载 添加 移除 macOS 语言与地区 离线"),
            .init(id: "translation-default", title: "默认云端服务", destination: .intelligence),
            .init(id: "translation-services", title: "翻译服务", destination: .intelligence, keywords: "凭证 API Key 模型 详情"),
            .init(id: "translation-add", title: "添加翻译服务", destination: .intelligence,
                  keywords: "火山 机器翻译 小牛 智谱 配置 Access Key Secret APPID"),
            .init(id: "software-about", title: "关于 HelloX", destination: .software, keywords: "版本"),
            .init(id: "software-appearance", title: "应用外观", destination: .software, keywords: "主题 浅色 深色 跟随系统"),
            .init(id: "permission-screen", title: "屏幕录制权限", destination: .software, keywords: "授权 截图 录屏"),
            .init(id: "permission-accessibility", title: "辅助功能权限", destination: .software, keywords: "授权 滚动截图 划词翻译"),
            .init(id: "software-update", title: "软件更新", destination: .software, keywords: "检查更新 安装 升级"),
            .init(id: "software-links", title: "项目主页与隐私说明", destination: .software)
        ]
        entries += profiles.map {
            .init(id: "translation-profile-" + $0.id.uuidString, title: $0.name,
                  destination: .intelligence, keywords: $0.vendor.displayName + " 模型 凭证 详情")
        }
        // The default-service control is only visible with an enabled profile.
        if !profiles.contains(where: \.isEnabled) {
            entries.removeAll { $0.id == "translation-default" }
        }
        return entries.filter { entry in
            let text = entry.title + " " + entry.destination.title + " " + entry.keywords
            return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }.sorted { lhs, rhs in
            let leftExact = lhs.title.localizedCaseInsensitiveCompare(query.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            let rightExact = rhs.title.localizedCaseInsensitiveCompare(query.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
            if leftExact != rightExact { return leftExact }
            return false
        }
    }
}
