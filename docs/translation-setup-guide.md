# HelloX 云翻译密钥申请与免费说明

## 一、使用前说明

本教程覆盖 HelloX 已接入的智谱、百度、阿里云、火山和小牛五家云翻译。按所选服务申请自己的凭证，填入 HelloX 后测试并启用即可。

官方政策核对日期：**2026-09-09**。以下是官方说明的简明转述，最新规则以各节链接及服务商控制台为准。按月免费额度、每日赠送积分和免费模型的适用条件不同；HelloX 不读取账户剩余额度，也不会在免费额度耗尽时自动替你关闭服务。

在 HelloX 的「设置 → 翻译服务 → 添加翻译服务」选择一家服务，即可看到该服务的「申请教程」「开通服务 / 获取凭证」和「官方免费说明」入口。已有配置可点击「详情」查看。

## 二、申请与配置

### 1. 智谱免费翻译

**官方免费说明：**官方价目表将 GLM-4.7-Flash 的输入、输出 Token 价格列为免费。HelloX 默认使用 glm-4.7-flash；更换模型后按新模型价格计费。免费不代表没有并发或速率限制。 [官方额度与计费说明](https://bigmodel.cn/pricing)

申请入口：[打开服务商页面](https://bigmodel.cn/usercenter/apikeys)。操作依据：[官方申请 / 接入指南](https://docs.bigmodel.cn/cn/guide/start/quick-start)。

1. 打开智谱开放平台，注册或登录账号。进入「个人中心 → API Keys」。
2. 创建一个新的 API Key，并复制完整的 Key。
3. 在 HelloX 添加「智谱免费翻译」，将 Key 填入「API Key」，「模型」保留 glm-4.7-flash。

| HelloX 字段 | 填写内容 |
| --- | --- |
| 「模型」 | glm-4.7-flash（默认免费模型） |
| 「API Key」 | 智谱 API Keys 页面生成的完整 Key |

点击「测试连接」，出现「连接成功」及耗时后，点击「保存」。返回翻译服务列表，打开该服务的启用开关；需要默认使用时，在「默认云端服务」中选择它。

### 2. 百度翻译

**官方免费说明：**通用文本翻译标准版每月免费 5 万字符；个人认证高级版每月免费 100 万字符；企业认证尊享版每月免费 200 万字符。超出免费额度按 49 元／百万字符计费。HelloX 当前按标准版限制，单次最多 1000 字符并支持常见语种。 [官方额度与计费说明](https://fanyi-api.baidu.com/doc/13)

申请入口：[打开服务商页面](https://fanyi-api.baidu.com/access/0)。操作依据：[官方申请 / 接入指南](https://api.fanyi.baidu.com/doc/23)。

1. 打开百度翻译开放平台，登录百度账号，按页面提示完成开发者注册。
2. 在「管理控制台」开通「通用翻译 API」。标准版无需实名认证；需要高级版时先完成个人认证。
3. 在「开发者信息」查看并复制 APPID 和密钥，确认已开通的是通用文本翻译服务。
4. 在 HelloX 添加「百度翻译」，将 APPID 和密钥分别填入同名字段。

| HelloX 字段 | 填写内容 |
| --- | --- |
| 「APPID」 | 百度翻译开放平台的 APPID |
| 「密钥」 | 与该 APPID 对应的密钥 |

点击「测试连接」，出现「连接成功」及耗时后，点击「保存」。返回翻译服务列表，打开该服务的启用开关；需要默认使用时，在「默认云端服务」中选择它。

### 3. 阿里云翻译

**官方免费说明：**机器翻译通用版每月免费 100 万字符，主账号与子账号共享。每月 1 日 0 点更新，未用完不结转；官方将免费额度用于试用场景。用完先抵扣资源包，没有资源包则进入后付费，通用版按 50 元／百万字符计费。 [官方额度与计费说明](https://help.aliyun.com/zh/machine-translation/product-overview/billing-overview)

申请入口：[打开服务商页面](https://mt.console.aliyun.com/)。操作依据：[官方申请 / 接入指南](https://help.aliyun.com/zh/machine-translation/getting-started/prepare-accounts-for-developers)。

1. 注册或登录阿里云，完成实名认证，进入机器翻译控制台开通「机器翻译通用版」。
2. 进入 RAM 控制台的「身份管理 → 用户」，创建用于 API 调用的 RAM 用户；为该用户添加 AliyunMTFullAccess 权限，或由管理员仅授权 alimt:TranslateGeneral。
3. 进入该用户的「认证管理 → AccessKey」，点击「创建 AccessKey」，按提示完成验证并保存 AccessKey ID 和 AccessKey Secret。Secret 仅在创建时显示。
4. 在 HelloX 添加「阿里云翻译」，AccessKey ID 填入「Access Key ID」，AccessKey Secret 填入「AccessKey Secret」。

| HelloX 字段 | 填写内容 |
| --- | --- |
| 「Access Key ID」 | 已获得翻译权限的 RAM 用户 AccessKey ID |
| 「AccessKey Secret」 | 同一组 AccessKey Secret |

点击「测试连接」，出现「连接成功」及耗时后，点击「保存」。返回翻译服务列表，打开该服务的启用开关；需要默认使用时，在「默认云端服务」中选择它。

### 4. 火山机器翻译

**官方免费说明：**官方文本翻译计费规则为每月前 200 万字符免费，超出部分按 49 元／百万字符计费，日结。汉字、外语字母、数字、符号和空格均按字符统计。此额度属于机器翻译服务。 [官方额度与计费说明](https://www.volcengine.com/docs/4640/68515)

申请入口：[打开服务商页面](https://console.volcengine.com/translate)。操作依据：[官方申请 / 接入指南](https://www.volcengine.com/docs/4640/127684)。

1. 注册或登录火山引擎账号，完成实名认证，进入机器翻译控制台开通服务。
2. 从控制台头像菜单进入「API访问密钥」，创建并保存 Access Key ID 和 Secret Access Key。
3. 如果使用子用户：管理员在「访问控制」找到该用户，点击「添加权限」，授予 TranslateFullAccess；再在用户详情的「密钥」页获取该用户的密钥。
4. 在 HelloX 添加「火山机器翻译」，将 Access Key ID 和 Secret Access Key 分别填入同名字段。

| HelloX 字段 | 填写内容 |
| --- | --- |
| 「Access Key ID」 | 火山引擎 Access Key ID |
| 「Secret Access Key」 | 同一组 Secret Access Key |

子用户授权与服务开通步骤见[官方开通指南](https://www.volcengine.com/docs/4640/130262)，当前身份及子用户密钥操作见[Access Key 管理](https://www.volcengine.com/docs/6291/65568)。

点击「测试连接」，出现「连接成功」及耗时后，点击「保存」。返回翻译服务列表，打开该服务的启用开关；需要默认使用时，在「默认云端服务」中选择它。

### 5. 小牛翻译

**官方免费说明：**小牛官网标注：注册账号每日可获 100 积分，约可翻译 20 万字符。实际可抵扣服务、字符消耗与剩余额度以控制台为准；额度外使用按服务商积分或字符流量规则计费。文本 API 文档标注免费用户并发为 5、单次最多 5000 字符。 [官方额度与计费说明](https://niutrans.com/price/)

申请入口：[打开服务商页面](https://niutrans.com/)。操作依据：[官方申请 / 接入指南](https://niutrans.com/documents/contents/transapi_text_v2)。

1. 在小牛翻译云平台注册账号并绑定手机号，登录后进入控制台。
2. 在左侧「API应用」找到「文本 API」，点击「开通」。
3. 在已开通的文本 API 服务中查看并复制 APPID 和 API-KEY。
4. 在 HelloX 添加「小牛翻译」，APPID 填入「APPID」，API-KEY 填入「APIKEY」。

| HelloX 字段 | 填写内容 |
| --- | --- |
| 「APPID」 | 控制台「API应用」中的文本 API APPID |
| 「APIKEY」 | 对应文本 API 的 API-KEY |

点击「测试连接」，出现「连接成功」及耗时后，点击「保存」。返回翻译服务列表，打开该服务的启用开关；需要默认使用时，在「默认云端服务」中选择它。

## 三、测试与常见问题

### 1. 如何确认配置完成

「测试连接」会发送一条真实的 Hello 翻译请求，按服务商规则消耗额度。测试成功后保存、启用服务，再打开「文本翻译」，选择该服务并翻译一段文字；出现译文即为当前配置可用。仅保存未启用的配置不会成为可用服务。

### 2. 提示密钥错误或没有权限

确认字段填入完整值，成对密钥来自同一账号或同一应用。百度需要开通通用翻译 API；小牛需要开通文本 API；火山子用户和阿里云 RAM 用户需要相应翻译权限。重新申请或重置密钥后，也要更新 HelloX 中保存的值。

### 3. 提示限流、额度或余额不足

在服务商控制台查看请求限制、剩余额度和账单。限流时降低请求频率后重试；免费额度不足时，可等待下个发放周期或切换仍有额度的服务，付费继续使用则按服务商规则办理。不能将「创建密钥免费」理解为「所有 API 调用免费」。

### 4. 为什么没有有道教程

有道未接入 HelloX：官方文本翻译 API 只提供一次性体验金，耗尽后按量收费，不符合此前“不收费才接入”的条件。详见[有道文本翻译定价](https://ai.youdao.com/DOCSIRMA/html/transapi/trans/price/wbfy/index.html)。本地离线翻译无需云端密钥。
