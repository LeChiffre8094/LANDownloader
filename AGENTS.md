# LAN Downloader 开发规则

## 项目与沟通
- 本项目是 iOS 16+ 原生 SwiftUI App，显示名称为“局域网文件传输”。以现有源码和用户当前需求为准，做有针对性的增量修改。
- 用简体中文解释修改、使用方式和验证结果。不要把已实现、已编译、已通过自动测试、已通过真机测试混为一谈。
- 开始修改前检查 Git 状态和相关源码，保留用户已有改动；不要凭对话记忆重建整个项目。

## 代码位置
- `iOS/LANDownloader/ContentView.swift`：文件列表、分类面板、下载列表、服务器管理和文件预览。
- `DownloadManager.swift`（同目录）：系统后台下载、任务恢复、续传、持久化、文件保存。
- `DirectoryBrowser.swift`：Caddy 目录读取与链接校验。
- `Models.swift`：文件分类、任务记录、服务器配置。
- `LANDownloaderApp.swift`：App 入口与后台事件桥接。
- `project.yml`：XcodeGen 项目配置；`.github/workflows/build.yml`：macOS 测试及未签名 IPA 构建。
- `Tests/`：XCTest；`windows/Start-LANDownloader.bat`：共享 BAT 所在目录。

## 后台下载必须保留的行为
- 使用 `URLSessionConfiguration.background`，保留会话标识 `com.lantransfer.downloader.background.v1` 和 AppDelegate 后台完成回调桥接。
- 保留 `sessionSendsLaunchEvents = true`、`isDiscretionary = false`、`allowsCellularAccess = false`、`waitsForConnectivity = true`，除非用户明确要求改变相关行为。
- 下载完成时必须在代理回调返回前同步移动系统临时文件；不能只派发异步移动后就返回。
- 不把大文件整体载入内存。大小、进度字节使用 Int64，并处理未知大小、空间不足和失败。
- 已有任务持有创建时的完整源 URL；切换、编辑或删除服务器不得改写任务 URL。
- 保持旧版 `downloads.json` 可读取。必要的数据结构变更要提供迁移，不静默丢弃旧记录。
- 保留原文件名，仅重名时加编号，禁止覆盖已有文件；移除记录不删除下载文件。
- 修复界面或播放器时，不顺带重写后台下载模块。确需修改时检查取消、暂停、重试、恢复和回调顺序。

## 浏览与电脑端
- 直接使用 Caddy browse，无需用户手工生成 JSON 清单；优先读取 Caddy 原生 JSON，HTML 回退使用解析器，不执行页面脚本。
- 保留同源、共享目录边界、直接子项和编码校验。拒绝路径穿越、外部链接及脚本地址。
- 保留中文、空格和特殊字符文件名；不可重复解码或简单拼接未编码 URL。
- 分类包含全部、视频、图片、音频、文档、压缩包、其他。搜索与全选默认仅作用于当前目录可见文件。
- BAT 共享自身所在目录，支持多目录独立端口；不得擅自终止用户已有 Caddy 服务或修改防火墙。

## 界面与播放器
- 以 `design/confirmed-prototype.png` 为视觉参考，使用原生自适应布局和安全区；保持中文标题、蓝白配色和现代 iPhone 全屏适配。
- 所有预览与播放页面必须有明确可见、可点击的返回/关闭入口，不能只依赖下滑手势；关闭后回到原列表。
- 新增播放引擎时放入独立模块；保留图片、文档等非视频预览能力。
- 第三方播放器依赖要核对官方接口、版本、许可证、iOS 最低版本及 CI 获取方式，固定可复现版本。
- 支持某种扩展名不等于支持所有编码。硬解、软解、字幕、音轨、HDR 与后台播放分别验证，不宣称“全格式均可播放”。
- 播放器是后续可选功能，只有用户提出实施要求时才集成。

## 构建与验证
- 配置变更以 `project.yml` 为维护入口；新增源码、资源或依赖后，确保交付的 Xcode 项目与生成配置一致。
- 小型 UI 文案或按钮修复做相关检查，不为凑数量新增只重复实现的测试。解析、文件完整性、迁移和任务状态变更需要针对性测试。
- Mac 环境：先 `xcodegen generate`；在可用 iPhone 模拟器上执行 scheme `LANDownloader` 的 XCTest，再构建设备版本。
- 设备构建：`xcodebuild -project LANDownloader.xcodeproj -scheme LANDownloader -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build`。
- Windows 没有 Xcode 时，可做静态与协议检查，并利用 GitHub Actions 验证；明确说明尚未运行的检查，不能用语法检查代替编译。
- UI 变更验证打开、关闭、横竖屏和安全区；后台下载需真机验证多任务、锁屏、暂停/继续、断网重试和大文件。模拟器单元测试不替代真机验证。
- 当前回归基线：v0.2 的 9 项 XCTest 已由用户提供的结果包确认通过；这一结果不自动适用于后续修改。

## 交付
- 默认保持现有 Bundle ID 和下载数据兼容，不要求用户卸载旧版来解决普通问题。
- 小修复提供保持仓库相对路径的补丁，并说明需替换哪些文件；较大版本提供完整可编辑项目 ZIP。
- 保留 GitHub Actions 未签名 IPA 流程，供用户自行签名安装。
- 报告修改内容、实际验证结果和剩余限制。没有明确授权，不推送远程仓库或发布版本。
- 本文件保持简短且可维护，记录长期规则；详细状态和历史放在 README、验证记录或变更说明中。
