import HelloXCore
import Testing
@testable import HelloXApp

@MainActor
struct TranslationLanguageSwapTests {
    private func makeModel() -> TranslationWindowModel {
        TranslationWindowModel(context: .manual, appModel: AppModel(translationProfileState: .init(
            profiles: [], defaultProfileID: nil, apiKeys: [:], isOfflineTranslationEnabled: false
        )))
    }

    @Test func swappingLanguagesKeepsTheSourceTextAndReversesThePair() {
        let model = makeModel()
        model.sourceLanguage = .japanese
        model.targetLanguage = .english
        model.sourceText = "こんにちは"
        model.swapLanguages()
        #expect(model.sourceLanguage == .english)
        #expect(model.targetLanguage == .japanese)
        #expect(model.sourceText == "こんにちは")
        model.swapLanguages()
        #expect(model.sourceLanguage == .japanese)
        #expect(model.targetLanguage == .english)
    }

    @Test func automaticSourceResolvesToAnExplicitTarget() {
        let model = makeModel()
        model.swapLanguages()
        #expect(model.sourceLanguage == .simplifiedChinese)
        #expect(model.targetLanguage == .english)
        model.sourceLanguage = .auto
        model.targetLanguage = .simplifiedChinese
        model.sourceText = "This is a complete English sentence for language detection."
        model.swapLanguages()
        #expect(model.sourceLanguage == .simplifiedChinese)
        #expect(model.targetLanguage == .english)
    }
}
