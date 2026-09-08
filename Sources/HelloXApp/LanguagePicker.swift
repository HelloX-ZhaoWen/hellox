import HelloXCore
import SwiftUI

struct HelloXLanguagePicker: View {
    let title: String
    @Binding var selection: SupportedLanguage
    let includesAuto: Bool

    private var options: [HXDropdownOption<SupportedLanguage>] {
        SupportedLanguage.allCases
            .filter { includesAuto || $0 != .auto }
            .map { language in
                let englishName = Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue) ?? ""
                return HXDropdownOption(
                    language,
                    language.displayName,
                    searchTerms: "\(englishName) \(language.rawValue)"
                )
            }
    }

    var body: some View {
        HXDropdown(
            title,
            selection: $selection,
            options: options,
            searchPlaceholder: "搜索语言",
            menuWidth: 220,
            triggerWidth: 144
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}
