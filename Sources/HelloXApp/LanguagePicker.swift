import HelloXCore
import SwiftUI

struct HelloXLanguagePicker: View {
    let title: String
    @Binding var selection: SupportedLanguage
    let includesAuto: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 7) {
                Text(selection.displayName)
                    .lineLimit(1)
                Spacer(minLength: 6)
                HelloXIcon(icon: .chevronRight, size: 12)
                    .rotationEffect(.degrees(90))
                    .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(HelloXTheme.primaryText(for: colorScheme))
            .padding(.horizontal, 10)
            .frame(minWidth: 140, minHeight: 34, alignment: .leading)
            .background(
                HelloXTheme.controlBackground(for: colorScheme),
                in: RoundedRectangle(cornerRadius: HelloXTheme.compactRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            HelloXLanguagePickerPopover(
                selection: $selection,
                includesAuto: includesAuto,
                isPresented: $isPresented
            )
        }
        .accessibilityLabel(title)
        .accessibilityValue(selection.displayName)
    }
}

private struct HelloXLanguagePickerPopover: View {
    @Binding var selection: SupportedLanguage
    let includesAuto: Bool
    @Binding var isPresented: Bool

    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private var availableLanguages: [SupportedLanguage] {
        SupportedLanguage.allCases.filter { includesAuto || $0 != .auto }
    }

    private var filteredLanguages: [SupportedLanguage] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return availableLanguages }
        return availableLanguages.filter { language in
            let englishName = Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue) ?? ""
            return language.displayName.localizedCaseInsensitiveContains(term)
                || englishName.localizedCaseInsensitiveContains(term)
                || language.rawValue.localizedCaseInsensitiveContains(term)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                TextField("搜索语言", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        HelloXIcon(icon: .close, size: 12)
                            .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                    }
                    .buttonStyle(.plain)
                    .help("清除搜索")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                HelloXTheme.controlBackground(for: colorScheme),
                in: RoundedRectangle(cornerRadius: HelloXTheme.compactRadius, style: .continuous)
            )

            if filteredLanguages.isEmpty {
                VStack(spacing: 8) {
                    HelloXIcon(icon: .translation, size: 22)
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                    Text("未找到匹配语言")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(HelloXTheme.secondaryText(for: colorScheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredLanguages) { language in
                                languageRow(language)
                                    .id(language.id)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .seamlessScrollChrome()
                    .onAppear {
                        guard query.isEmpty else { return }
                        proxy.scrollTo(selection.id, anchor: .center)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 270, height: 380)
        .background(HelloXTheme.surface(for: colorScheme))
        .onAppear {
            isSearchFocused = true
        }
    }

    private func languageRow(_ language: SupportedLanguage) -> some View {
        Button {
            selection = language
            isPresented = false
        } label: {
            HStack(spacing: 10) {
                Text(language.displayName)
                    .lineLimit(1)
                Spacer()
                if language == selection {
                    HelloXIcon(icon: .confirm, size: 14)
                        .foregroundStyle(HelloXTheme.accent)
                }
            }
            .font(.system(size: 12, weight: language == selection ? .semibold : .regular))
            .foregroundStyle(
                language == selection
                    ? HelloXTheme.accent
                    : HelloXTheme.primaryText(for: colorScheme)
            )
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(
                language == selection
                    ? HelloXTheme.selectedBackground(for: colorScheme)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: HelloXTheme.compactRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
