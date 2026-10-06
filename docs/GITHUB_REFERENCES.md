# 全功能 GitHub 源码对照与额度读取改进

调研时间：2026-09-08（Asia/Shanghai）。范围为当前 5 个页面、菜单栏中的 12 项功能。
使用 GitHub CLI 搜索 Typeless、quota menu bar、Accessibility、Keychain、迁移和更新相关仓库，
再读取下列固定 commit 的实现与许可证；没有运行下载的第三方脚本，也没有因仓库存在就认定其安全。

## 已落地的改进

当前额度可在用户开启“自动读取官方额度”后直接同步，无需手动切换官方页面。
核心参考是 Typeless / typeless-toolkit 的当前会话和周额度接口，以及 Quotio / CodexBar 的请求隔离。
实现不增加运行时 Node/Python 依赖：CommonCrypto 解码当前会话，URLSession 查询固定官方 HTTPS 地址。

每次查询先核对本地邮箱、会话代次、服务端邮箱与用户 ID，再读取额度，结束时再次确认会话。
认证只存在于本次请求内存；不写入账户目录、日志、诊断或剪贴板，不转发重定向，不刷新 token。
默认关闭并说明用途；退出此模式后仍可使用原来的 Accessibility 路径。

文件/应用/唤醒事件驱动刷新；常规最短间隔 60 秒，手动刷新 5 秒；失败退避 30–900 秒，
遵循 Retry-After 秒数（上限 24 小时）。同一会话仅有一个请求与一个待处理事件，不新增持续网络定时器。
旧额度保留原观察时间，超过 5 分钟不可用于守护；身份不匹配或会话失效立即拒绝缓存。

## 逐功能取舍

| 现有功能 | 固定版本源码参考 | 结论与本轮处理 |
|---|---|---|
| 自动关闭升级提示 | [liuxiaoyu-fiveleven/Typeless-AD-Skipper](https://github.com/liuxiaoyu-fiveleven/Typeless-AD-Skipper/blob/3aac039589287f8e97d9ae5c0b42605625448dfc/README.md)；[AXSwift Observer](https://github.com/tmandry/AXSwift/blob/e18a18453d135ad45809a384ee5139e05ea52def/Sources/Observer.swift) | AD-Skipper 可见仓库只有 README/分发说明，无可审查源码或许可证；AXSwift 展示 AXObserver 和 run loop 注册。保留现有精确文案、唯一关闭按钮、动作前复验，不引入全局找按钮或坐标点击。 |
| 当前账号与额度 | [Typeless QuotaSync](https://github.com/fufu1209/Typeless/blob/f26f798eb7d9ff4331334f3d0725d17c629368d0/Sources/TypelessSwitchboard/Store/SwitchboardStore+QuotaSync.swift)；[typeless-toolkit liveStatus](https://github.com/Jia131313/typeless-toolkit/blob/e772db5dd0196088e6532231f4a09e5505ce3677/lib/common.js) | 两者使用 /user/usage_stats。采用固定官方接口和周用量字段；原生 Swift 只在内存读取当前会话，先 GET 身份、再 POST 空对象读取额度，不缓存原始响应，不在命令行传 token。 |
| 账号目录管理 | [Typeless AccountCRUD](https://github.com/fufu1209/Typeless/blob/f26f798eb7d9ff4331334f3d0725d17c629368d0/Sources/TypelessSwitchboard/Store/SwitchboardStore+AccountCRUD.swift)；[Quotio AccountService](https://github.com/nguyenphutrong/quotio/blob/a00101078db0bc9b91ecf46bf4a42b7ad9d6c1b7/Packages/QuotioCore/Sources/QuotioApplication/Accounts/AccountService.swift) | 可参考账号域模型和账号级缓存清除。现有标准化邮箱、去重、UUID、暂停和邮箱编辑失效逻辑已有覆盖，保留；不把目录条目当作有效会话。 |
| 可选密码保管 | [kishikawakatsumi/KeychainAccess](https://github.com/kishikawakatsumi/KeychainAccess/blob/e0c7eebc5a4465a3c4680764f26b7a61f567cdaf/Sources/Keychain.swift)；[CodexBar KeychainPromptCoordinator](https://github.com/steipete/CodexBar/blob/b18431b51a48257dc7080e28ccbf29a16732bd25/Sources/CodexBar/KeychainPromptCoordinator.swift) | 参考 service/account 隔离及交互提示协调。当前直接使用 Security.framework、按 UUID 保存密码，已满足所需边界；不增加依赖，不自动读取浏览器 Cookie，额度查询不接触其他账号密码。 |
| 账号切换与恢复 | [Typeless SmartSwitch](https://github.com/fufu1209/Typeless/blob/f26f798eb7d9ff4331334f3d0725d17c629368d0/Sources/TypelessSwitchboard/Store/SwitchboardStore+SmartSwitch.swift)；[free-typeless switch-account](https://github.com/schummiking/free-typeless/blob/00d5aa1476a0d92de7c948f2c13f639a86772859/scripts/switch-account.mjs) | 类似项目可做切换后核对，但含会话注入；后者未声明许可证。本项目保留官方网页交接、有限验证、停止跟踪和恢复流程。本轮仅让验证直接采用匹配当前会话的服务端额度。 |
| 换号后的额度核对 | [Quotio QuotaRefreshCoordinator](https://github.com/nguyenphutrong/quotio/blob/a00101078db0bc9b91ecf46bf4a42b7ad9d6c1b7/Packages/QuotioCore/Sources/QuotioApplication/Quota/QuotaRefreshCoordinator.swift)；[CodexBar TokenRefreshSequence](https://github.com/steipete/CodexBar/blob/b18431b51a48257dc7080e28ccbf29a16732bd25/Sources/CodexBar/UsageStore+TokenRefreshSequence.swift) | 采用账号/请求代次隔离、单请求合并、有限待处理事件、失败退避。开启自动额度后不再要求重启和两次页面切换；缓存保持原时间，5 分钟过期，旧会话的迟到结果不能覆盖新账号。 |
| 低额度守护 | [Typeless RotateMonitor](https://github.com/fufu1209/Typeless/blob/f26f798eb7d9ff4331334f3d0725d17c629368d0/Sources/TypelessSwitchboard/Store/SwitchboardStore+RotateMonitor.swift)；[Typeless QuotaCycleEngine](https://github.com/fufu1209/Typeless/blob/f26f798eb7d9ff4331334f3d0725d17c629368d0/Sources/TypelessSwitchboardCore/QuotaCycleEngine.swift) | 参考冷却、互斥和有序候选。保留默认关闭、真实空闲、新鲜额度和一次一轮；不采用按本机日期把用量清零、自动注册热备或注入式轮换。 |
| 低额度手动提醒 | [Typeless QuotaGuardTabView](https://github.com/fufu1209/Typeless/blob/f26f798eb7d9ff4331334f3d0725d17c629368d0/Sources/TypelessSwitchboard/UI/QuotaGuardTabView.swift)；[OpenUsage StatusItemController](https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/App/StatusItemController.swift) | 参考状态及可操作入口。现有“登录验证备用账号”和“稍后提醒”已覆盖低额度/未知活动场景，保留；服务器额度不会把 unknown 变成 idle。 |
| 备份与迁移 | [typeless-migrator backup](https://github.com/mercy719/typeless-migrator/blob/d0628790969621fa2577cdda307a6fa40742eaea/backup.sh)；[typeless-migrator migrate](https://github.com/mercy719/typeless-migrator/blob/d0628790969621fa2577cdda307a6fa40742eaea/migrate.sh) | 该项目备份/搬迁 Typeless 数据，另含设备身份处理。本项目保留仅账号元数据与规则的无秘密 JSON、导入预览、merge 和事务回滚，不复制官方数据库、登录态或设备身份。 |
| 诊断与切换记录 | [Typeless ReportExport](https://github.com/fufu1209/Typeless/blob/f26f798eb7d9ff4331334f3d0725d17c629368d0/Sources/TypelessSwitchboard/Store/SwitchboardStore+ReportExport.swift)；[CodexBar ProviderIdentitySnapshot](https://github.com/steipete/CodexBar/blob/b18431b51a48257dc7080e28ccbf29a16732bd25/Sources/CodexBarCore/ProviderIdentitySnapshot.swift) | 借鉴状态分层。类似项目报告包含账号信息/指纹；本项目继续白名单脱敏导出，只记录固定错误码。本轮网络错误不携带响应体、认证头或任意系统错误文本。 |
| 应用内更新 | [Sparkle SPUUpdater](https://github.com/sparkle-project/Sparkle/blob/39c97c96e6cd0e494068ae6d007ec7bf00b74f8b/Sparkle/SPUUpdater.h)；[OpenUsage UpdaterController](https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/App/UpdaterController.swift) | 现有实现已依赖 Sparkle 2.9.6，具备签名、渠道、准备后重启与安装状态，不新增更新器或改动发布链。本轮本机构建不等于公开发布。 |
| 常驻与系统设置 | [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern/blob/a04ec1c363be3627734f6dad757d82f5d4fa8fcc/Sources/LaunchAtLogin/LaunchAtLogin.swift)；[AXorcist AXObserverCenter](https://github.com/openclaw/AXorcist/blob/aa07d72fbb1861b56f5833b4cff8d9101c8dfbb3/Sources/AXorcist/Core/AXObserverCenter.swift)；[OpenUsage RefreshWakeSignal](https://github.com/robinebers/openusage/blob/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1/Sources/OpenUsage/App/RefreshWakeSignal.swift) | SMAppService、AX 观察与有界事件缓冲值得参考。保留原生登录项和权限流程；本轮增加会话/使用记录的文件事件和唤醒通知，处理请求期间的事件，完成回调不自行启动轮询。 |

本次“参考”包含采用实现思路、确认现有实现足够，以及明确排除不合适的做法；不表示复制或重做所有功能。
尤其不把第三方的会话注入、设备标识重置、自动注册和整目录迁移并入本工具。

## 仓库与许可证

| 仓库 | 读取版本 | 许可证/采用方式 |
|---|---|---|
| [Jia131313/typeless-toolkit](https://github.com/Jia131313/typeless-toolkit) | [`e772db5dd019`](https://github.com/Jia131313/typeless-toolkit/commit/e772db5dd0196088e6532231f4a09e5505ce3677) | MIT；参考思路，未引入依赖 |
| [fufu1209/Typeless](https://github.com/fufu1209/Typeless) | [`f26f798eb7d9`](https://github.com/fufu1209/Typeless/commit/f26f798eb7d9ff4331334f3d0725d17c629368d0) | MIT；当前会话格式原生改写，随附版权声明 |
| [kishikawakatsumi/KeychainAccess](https://github.com/kishikawakatsumi/KeychainAccess) | [`e0c7eebc5a44`](https://github.com/kishikawakatsumi/KeychainAccess/commit/e0c7eebc5a4465a3c4680764f26b7a61f567cdaf) | MIT；参考思路，未引入依赖 |
| [liuxiaoyu-fiveleven/Typeless-AD-Skipper](https://github.com/liuxiaoyu-fiveleven/Typeless-AD-Skipper) | [`3aac03958928`](https://github.com/liuxiaoyu-fiveleven/Typeless-AD-Skipper/commit/3aac039589287f8e97d9ae5c0b42605625448dfc) | 未声明；仅检查公开行为，不复制代码 |
| [mercy719/typeless-migrator](https://github.com/mercy719/typeless-migrator) | [`d06287909696`](https://github.com/mercy719/typeless-migrator/commit/d0628790969621fa2577cdda307a6fa40742eaea) | MIT；参考思路，未引入依赖 |
| [nguyenphutrong/quotio](https://github.com/nguyenphutrong/quotio) | [`a00101078db0`](https://github.com/nguyenphutrong/quotio/commit/a00101078db0bc9b91ecf46bf4a42b7ad9d6c1b7) | MIT；参考思路，未引入依赖 |
| [openclaw/AXorcist](https://github.com/openclaw/AXorcist) | [`aa07d72fbb18`](https://github.com/openclaw/AXorcist/commit/aa07d72fbb1861b56f5833b4cff8d9101c8dfbb3) | MIT；参考思路，未引入依赖 |
| [robinebers/openusage](https://github.com/robinebers/openusage) | [`70dea9a8fa21`](https://github.com/robinebers/openusage/commit/70dea9a8fa21ed205aa9ad625b416a1e7792d5a1) | MIT；参考思路，未引入依赖 |
| [schummiking/free-typeless](https://github.com/schummiking/free-typeless) | [`00d5aa1476a0`](https://github.com/schummiking/free-typeless/commit/00d5aa1476a0d92de7c948f2c13f639a86772859) | 未声明；仅检查公开行为，不复制代码 |
| [sindresorhus/LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern) | [`a04ec1c363be`](https://github.com/sindresorhus/LaunchAtLogin-Modern/commit/a04ec1c363be3627734f6dad757d82f5d4fa8fcc) | MIT；参考思路，未引入依赖 |
| [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle) | [`39c97c96e6cd`](https://github.com/sparkle-project/Sparkle/commit/39c97c96e6cd0e494068ae6d007ec7bf00b74f8b) | LICENSE 为 MIT 主体及 BSD/zlib 附属条款；现有依赖 |
| [steipete/CodexBar](https://github.com/steipete/CodexBar) | [`b18431b51a48`](https://github.com/steipete/CodexBar/commit/b18431b51a48257dc7080e28ccbf29a16732bd25) | MIT；参考思路，未引入依赖 |
| [tmandry/AXSwift](https://github.com/tmandry/AXSwift) | [`e18a18453d13`](https://github.com/tmandry/AXSwift/commit/e18a18453d135ad45809a384ee5139e05ea52def) | MIT；参考思路，未引入依赖 |

会话格式参考的完整版权声明见 [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md)。
Sparkle 已有依赖版本继续锁定 2.9.6，调研其仓库不表示更新依赖。
AD-Skipper 只有 README/分发入口，不能作为已审阅实现；free-typeless 无许可证，未复用代码。

## 验证与限制

- 先用失败测试固定旧实现无法直接读取额度的问题，再验证 API 解析、身份隔离、会话变化、
  两种平台文件格式、重定向拒绝、去重/退避、过期与事件触发。
- 2026-09-08 原生 Swift 对本机 Typeless 2.5.0 的真实只读请求通过：周用量 652 / 8000，
  服务端身份匹配、请求前后会话未变；整个过程未打开官方账户页或主页。
- 服务端接口和会话文件格式属于官方客户端内部实现，无公开稳定性承诺。格式变化时明确显示
  不可读，保留官方登录及原有 AX 读取入口，不采用自动改写或身份修复。
- Intel 文件格式通过离线加密样本验证；真实 Intel 客户端为 UNVERIFIED。
- 本轮没有重新执行真实双账号往返或制造录音；旧请求竞态与未知活动保护用聚焦测试覆盖。
  真实服务器弹窗、录音/处理中控件的既有现场限制不因额度查询通过而消失。

完整检查与本机安装证据见 [自动额度验证](QUOTA_API_VALIDATION.md)。
