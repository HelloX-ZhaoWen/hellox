import Foundation

public enum PendingPermissionAction: Codable, Equatable, Sendable {
    case capture(mode: CaptureMode, targetProcessID: Int32?)
    case screenRecording
    case captureAndOCR
    case captureAndTranslate
    case translateSelection(processID: Int32)
    case manage(PrivacyPermission)

    public var requiredPermissions: [PrivacyPermission] {
        switch self {
        case .capture(let mode, _):
            switch mode {
            case .scrolling: [.screenRecording, .accessibility]
            case .region, .window, .fullScreen: [.screenRecording]
            }
        case .screenRecording, .captureAndOCR, .captureAndTranslate: [.screenRecording]
        case .translateSelection: [.accessibility]
        case .manage(let permission): [permission]
        }
    }

    public var featureName: String {
        switch self {
        case .capture(let mode, _): mode.localizedName
        case .screenRecording: "选区录屏"
        case .captureAndOCR: "截图文字识别"
        case .captureAndTranslate: "截图翻译"
        case .translateSelection: "划词翻译"
        case .manage(let permission): permission.displayName
        }
    }

}

public final class PendingPermissionActionStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    public init(
        defaults: UserDefaults = .standard,
        key: String = "com.hellox.pending-permission-action.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func save(_ action: PendingPermissionAction) {
        guard let data = try? encoder.encode(action) else { return }
        defaults.set(data, forKey: key)
    }

    public func load() -> PendingPermissionAction? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(PendingPermissionAction.self, from: data)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
