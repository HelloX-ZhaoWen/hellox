import Testing
@testable import HelloXApp

@MainActor
struct DropdownTests {
    @Test func languageSearchMatchesDisplayNameEnglishAndCode() {
        let state = HXDropdownListState<String>()
        let options = [
            HXDropdownOption("zh-Hans", "简体中文", searchTerms: "Chinese zh-Hans"),
            HXDropdownOption("en", "英语", searchTerms: "English en"),
            HXDropdownOption("ja", "日语", searchTerms: "Japanese ja")
        ]
        for query in [" 英语 ", "ENGLISH", "en"] {
            state.query = query
            #expect(state.filtered(options).map(\.value) == ["en"])
        }
        state.query = "zh-Hans"
        #expect(state.filtered(options).map(\.value) == ["zh-Hans"])
        state.query = "不存在的语言"
        #expect(state.filtered(options).isEmpty)
    }

    @Test func keyboardMovementSkipsDisabledOptionsAndStopsAtBoundaries() {
        let state = HXDropdownListState<Int>()
        let options = [
            HXDropdownOption(1, "第一项"),
            HXDropdownOption(2, "不可选", isEnabled: false),
            HXDropdownOption(3, "第三项")
        ]
        state.move(1, in: options)
        #expect(state.highlighted == 1)
        state.move(1, in: options)
        #expect(state.highlighted == 3)
        state.move(1, in: options)
        #expect(state.highlighted == 3)
        state.move(-1, in: options)
        #expect(state.highlighted == 1)
        state.move(-1, in: options)
        #expect(state.highlighted == 1)
    }

    @Test func emptyResultsAndDisabledListsHaveNoKeyboardCandidate() {
        let state = HXDropdownListState<Int>()
        state.move(1, in: [])
        #expect(state.highlighted == nil)
        state.move(-1, in: [HXDropdownOption(1, "不可选", isEnabled: false)])
        #expect(state.highlighted == nil)
    }
}
