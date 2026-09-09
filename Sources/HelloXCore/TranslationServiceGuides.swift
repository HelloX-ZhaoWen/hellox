import Foundation

/// User-facing instructions for the exact services used by HelloX.
public struct TranslationSetupGuide: Sendable {
    public static let verifiedDate = "2026-09-09"
    public let freePolicy: String
    public let registrationURL: URL
    public let pricingURL: URL
    public let instructionsURL: URL
    public let steps: [String]
}

public extension TranslationVendor {
    var setupGuide: TranslationSetupGuide? {
        switch self {
        case .local: nil
        case .zhipu:
            TranslationSetupGuide(
                freePolicy: "官方价目表将 GLM-4.7-Flash 的输入、输出 Token 价格列为免费。HelloX 默认使用 glm-4.7-flash；更换模型后按新模型价格计费。免费不代表没有并发或速率限制。",
                registrationURL: URL(string: "https://bigmodel.cn/usercenter/apikeys")!,
                pricingURL: URL(string: "https://bigmodel.cn/pricing")!,
                instructionsURL: URL(string: "https://docs.bigmodel.cn/cn/guide/start/quick-start")!,
                steps: [
                    "打开智谱开放平台，注册或登录账号。进入「个人中心 → API Keys」。",
                    "创建一个新的 API Key，并复制完整的 Key。",
                    "在 HelloX 添加「智谱免费翻译」，将 Key 填入「API Key」，「模型」保留 glm-4.7-flash。"
                ]
            )
        case .baidu:
            TranslationSetupGuide(
                freePolicy: "通用文本翻译标准版每月免费 5 万字符；个人认证高级版每月免费 100 万字符；企业认证尊享版每月免费 200 万字符。超出免费额度按 49 元／百万字符计费。HelloX 当前按标准版限制，单次最多 1000 字符并支持常见语种。",
                registrationURL: URL(string: "https://fanyi-api.baidu.com/access/0")!,
                pricingURL: URL(string: "https://fanyi-api.baidu.com/doc/13")!,
                instructionsURL: URL(string: "https://api.fanyi.baidu.com/doc/23")!,
                steps: [
                    "打开百度翻译开放平台，登录百度账号，按页面提示完成开发者注册。",
                    "在「管理控制台」开通「通用翻译 API」。标准版无需实名认证；需要高级版时先完成个人认证。",
                    "在「开发者信息」查看并复制 APPID 和密钥，确认已开通的是通用文本翻译服务。",
                    "在 HelloX 添加「百度翻译」，将 APPID 和密钥分别填入同名字段。"
                ]
            )
        case .aliyun:
            TranslationSetupGuide(
                freePolicy: "机器翻译通用版每月免费 100 万字符，主账号与子账号共享。每月 1 日 0 点更新，未用完不结转；官方将免费额度用于试用场景。用完先抵扣资源包，没有资源包则进入后付费，通用版按 50 元／百万字符计费。",
                registrationURL: URL(string: "https://mt.console.aliyun.com/")!,
                pricingURL: URL(string: "https://help.aliyun.com/zh/machine-translation/product-overview/billing-overview")!,
                instructionsURL: URL(string: "https://help.aliyun.com/zh/machine-translation/getting-started/prepare-accounts-for-developers")!,
                steps: [
                    "注册或登录阿里云，完成实名认证，进入机器翻译控制台开通「机器翻译通用版」。",
                    "进入 RAM 控制台的「身份管理 → 用户」，创建用于 API 调用的 RAM 用户；为该用户添加 AliyunMTFullAccess 权限，或由管理员仅授权 alimt:TranslateGeneral。",
                    "进入该用户的「认证管理 → AccessKey」，点击「创建 AccessKey」，按提示完成验证并保存 AccessKey ID 和 AccessKey Secret。Secret 仅在创建时显示。",
                    "在 HelloX 添加「阿里云翻译」，AccessKey ID 填入「Access Key ID」，AccessKey Secret 填入「AccessKey Secret」。"
                ]
            )
        case .volcengine:
            TranslationSetupGuide(
                freePolicy: "官方文本翻译计费规则为每月前 200 万字符免费，超出部分按 49 元／百万字符计费，日结。汉字、外语字母、数字、符号和空格均按字符统计。此额度属于机器翻译服务。",
                registrationURL: URL(string: "https://console.volcengine.com/translate")!,
                pricingURL: URL(string: "https://www.volcengine.com/docs/4640/68515")!,
                instructionsURL: URL(string: "https://www.volcengine.com/docs/4640/127684")!,
                steps: [
                    "注册或登录火山引擎账号，完成实名认证，进入机器翻译控制台开通服务。",
                    "从控制台头像菜单进入「API访问密钥」，创建并保存 Access Key ID 和 Secret Access Key。",
                    "如果使用子用户：管理员在「访问控制」找到该用户，点击「添加权限」，授予 TranslateFullAccess；再在用户详情的「密钥」页获取该用户的密钥。",
                    "在 HelloX 添加「火山机器翻译」，将 Access Key ID 和 Secret Access Key 分别填入同名字段。"
                ]
            )
        case .niutrans:
            TranslationSetupGuide(
                freePolicy: "小牛官网标注：注册账号每日可获 100 积分，约可翻译 20 万字符。实际可抵扣服务、字符消耗与剩余额度以控制台为准；额度外使用按服务商积分或字符流量规则计费。文本 API 文档标注免费用户并发为 5、单次最多 5000 字符。",
                registrationURL: URL(string: "https://niutrans.com/")!,
                pricingURL: URL(string: "https://niutrans.com/price/")!,
                instructionsURL: URL(string: "https://niutrans.com/documents/contents/transapi_text_v2")!,
                steps: [
                    "在小牛翻译云平台注册账号并绑定手机号，登录后进入控制台。",
                    "在左侧「API应用」找到「文本 API」，点击「开通」。",
                    "在已开通的文本 API 服务中查看并复制 APPID 和 API-KEY。",
                    "在 HelloX 添加「小牛翻译」，APPID 填入「APPID」，API-KEY 填入「APIKEY」。"
                ]
            )
        }
    }
}
