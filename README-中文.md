# 当前更新：App 内视频浮窗

请先阅读 [播放器更新说明](播放器更新说明.md)，包含完整上传步骤、双引擎依赖许可证、功能边界及本次验证状态。

# 局域网文件传输 · LAN Downloader v0.2

这是基于 LeChiffre8094/LANDownloader 的 v0.1 源码（提交 `47ec0d29f866b0464efea84b147a140f34ab8165`）修改的可编辑 iPhone 项目，不是效果图。最低 iOS 16。

**交付状态：源码、Xcode 项目、图标和构建工作流已制作；Windows 静态检查和 Caddy 协议测试已完成。尚未用 Xcode 编译，尚未执行 XCTest，尚未在 iPhone 上验证 v0.2。未生成 IPA，也未推送到你的 GitHub。v0.1 的真机成功不能等同于 v0.2 已验证。**

## 电脑端：一个 BAT 放进哪个目录，就共享哪个目录

1. 把 `windows/Start-LANDownloader.bat` 复制到要共享的文件夹，例如 `E:\迅雷下载`、`D:\其他下载`。可以复制到多个目录。
2. Caddy 只需安装一次。现有 `C:\Caddy\caddy.exe` 可以直接复用；也支持 BAT 旁的 `caddy.exe`、`%LOCALAPPDATA%\Caddy\caddy.exe`、PATH 或 `CADDY_EXE` 环境变量。
3. 双击 BAT。窗口会显示共享目录、端口和电脑 IPv4 地址。无需在 CMD 输入指令，不生成文件清单。
4. 手机和电脑在同一局域网。在 App 的“服务器”页保存名称、地址、端口，例如“迅雷下载”、`192.168.0.245`、`8080`。
5. 保持窗口打开；按 Ctrl+C 停止该目录的共享。

默认优先使用 8080。端口占用时自动在 8080–8199 中找空闲端口；每个目录的端口保存在 `%LOCALAPPDATA%\LANDownloader`，下次优先复用。**同一电脑同时共享多个目录，请把各自的端口分别保存到 App。** 如果窗口提示端口变更，请更新 App 中的端口；已有下载任务仍保留旧地址，需要原地址恢复后才能继续。

首次启动 Windows 防火墙可能提示，请允许专用网络。脚本不会自动改防火墙、不会关闭其他 Caddy 进程，也不会自动下载或覆盖 Caddy。多网卡会显示多个地址，选择与手机同网段的那一个。不要重复双击同一目录的 BAT，以免同一目录启动多份服务。

BAT 内部使用 Windows 自带 PowerShell 5.1 和 `caddy file-server --root <BAT 所在目录> --listen :端口 --browse`。需要 Windows 10/11；脚本目录含中文、空格、`&`、`%`、`!`、括号的启动包装已测试。

共享的是整个文件夹及其子目录；其中的 BAT/caddy.exe 也可能出现在清单里。请只共享适合向当前局域网开放的目录，不做公网端口映射。Caddy 根目录里的符号链接可能指向外部目录。目录中若有 `index.html` / `index.txt`，Caddy 可能返回首页而非目录清单，请使用没有这些首页文件的共享目录。

## App 的四个界面

- **文件浏览**：蓝白配色、圆角服务器卡片、服务器切换、当前目录搜索、分类条、子目录/上级/根目录导航、单选/多选/全选、底部批量下载按钮。
- **文件类型筛选**：独立选择面板，“确认”应用筛选，“取消”不改变筛选。
- **下载管理**：下载中/已完成分段，任务进度、已传输字节、状态和错误、暂停/继续/重试/从头下载、取消、打开和分享已完成文件。
- **服务器管理**：保存/编辑/删除/选择多台电脑，名称、地址、端口。也可以把同一台电脑不同端口保存为不同目录。

界面使用 SwiftUI 原生布局和安全区；Info.plist 增加 `UILaunchScreen`，解决旧项目缺少现代启动页声明可能造成的兼容显示问题。布局不通过放大固定画布实现。**黑边消除、横屏、不同尺寸和动态字体效果还需真机或模拟器确认。**

按已确认原型采用蓝白布局和蓝色 WiFi＋文件夹双向箭头图标。列表使用真实文件类型图标，**没有把原型中的示例电影海报当作实际文件缩略图，也未实现远程视频海报提取**。

## 文件分类

| 分类 | 主要扩展名 |
| --- | --- |
| 视频 | mp4, mkv, mov, m4v, avi, ts, m2ts, mts, webm, flv, wmv, mpg, mpeg, 3gp, 3g2, vob, ogv, rm, rmvb, asf |
| 图片 | jpg, jpeg, png, heic, heif, gif, bmp, webp, tif, tiff, svg, avif, raw, dng |
| 音频 | mp3, flac, m4a, wav, aac, ogg, opus, aiff, alac, wma, ape |
| 文档 | pdf, doc, docx, xls, xlsx, ppt, pptx, txt, rtf, md, csv, epub, pages, numbers, key, json, xml, log, srt, ass, vtt |
| 压缩包 | zip, rar, 7z, tar, gz, bz2, xz, tgz, zst, iso |
| 其他 | 未匹配类型 |

扩展名不区分大小写。“全部”展示所有类型。文件夹始终可见，以便导航；选择和全选只作用于当前目录的可见文件，不递归下载文件夹。分类支持表示可识别和下载，**不代表 iOS 可以原生播放所有视频编码**；Quick Look 不支持的格式可分享给其他 App。

## 目录读取、安全和 URL

优先发送 `Accept: application/json` 读取 Caddy 自带的 browse 响应。这里的 JSON 由 Caddy 动态生成，用户无需创建任何 JSON 文件。旧的 `Generate-Manifest.ps1` 仅为 v0.1 历史兼容保留，v0.2 不调用它。

如果服务器返回 HTML，使用固定版本 SwiftSoup 2.6.0 解析 Caddy 表格中的链接，不运行脚本，不加载网页资源，不使用 HTML 的 `<base>` 作为下载基准。仅接受同协议、同主机、同端口、共享根目录内的直接子项；拒绝上级导航、脚本地址、认证信息、查询/片段、编码后的路径分隔符和控制字符。服务器重定向也会检查范围。

目录响应最多 8 MB，避免把异常页面整体无限载入；文件内容使用系统下载任务直接落盘，不整文件读入内存。HTML 回退没有可信字节大小时显示“大小未知”，不会把四舍五入后的网页显示值当成准确大小。Caddy 默认有目录条数限制，文件特别多时建议分到子目录，App 在返回达到 10000 项时提示。

## 后台下载及数据兼容

保留原 AppDelegate 后台事件桥接和原后台会话标识：

```swift
URLSessionConfiguration.background(withIdentifier: "com.lantransfer.downloader.background.v1")
config.sessionSendsLaunchEvents = true
config.isDiscretionary = false
config.allowsCellularAccess = false
config.waitsForConnectivity = true
```

保留下载代理回调中**同步移动临时文件**的关键行为；任务记录仍写在 Application Support 的 `downloads.json`，兼容 v0.1 的记录字段及旧任务 ID。后台事件完成通知会等待排队中的记录保存完成。旧 `serverURL` 首次升级迁移为一个已保存服务器。

新任务使用独立 UUID，记录创建时的完整 URL；服务器切换、编辑或删除不改写该 URL。不同服务器的同名文件不会混成同一个任务。已有进行中/暂停/已完成任务不会重复入队；要重新下载已完成文件，可先移除对应记录。

- 暂停使用 `cancel(byProducingResumeData:)`，续传信息保存在 Application Support。
- 继续优先使用系统 resume data；服务端或系统无法续传时可能重头下载。失败任务可重试，或在菜单选择“从头下载”。
- 锁屏下载由 iOS 调度。**从多任务界面强制划掉 App 会影响后台任务**，这不是保持屏幕唤醒即可修复的问题。电脑睡眠/断网也会影响传输。
- 文件按原名保存在 Documents，仅冲突时生成 `文件 (1).扩展名`，不覆盖旧文件。
- 开启文件共享，可在“文件 App → 浏览 → 我的 iPhone → 局域网文件传输”查看；有些系统仍可能显示内部目录名 LANDownloader。
- 移除记录不会删除已下载文件。文件被用户移动或删除后，打开时会提示。
- 新建/恢复任务前检查可用空间及其他运行任务剩余大小，并保留约 200 MB 余量；收到进度回调时继续检查。大小未知、App 被挂起或其他 App 同时占用空间时，不能保证提前预测耗尽，最终写入错误仍会记录。
- 文件大小和进度字节使用 Int64，支持超过 4 GB 的文件；实际大文件真机测试尚未执行。

尽量保持原 Bundle ID 和签名安装身份；换签名或卸载重装可能失去原沙盒数据。升级前建议完成正在运行的任务并备份重要文件。背景会话标识未改变，但跨签名升级的任务恢复需要实机确认。

## 在 Mac / Xcode 编辑和编译

直接打开 `LANDownloader.xcodeproj`。首次打开需要网络下载 SwiftSoup 2.6.0；图标已经包含在 Assets.xcassets/AppIcon.appiconset 中。

`project.yml` 是维护用的 XcodeGen 配置，可重新生成项目：

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project LANDownloader.xcodeproj -scheme LANDownloader -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

项目默认禁用签名，以便云端生成未签名 IPA。若在 Xcode 直接连接真机运行，需要自行配置 Team、签名，并启用代码签名。

## Windows 用户：GitHub Actions → 全能签

1. 把 ZIP 内 `LANDownloader-v0.2` 文件夹的**内容**更新到现有仓库根目录；不要把整个文件夹再嵌套一层。确保隐藏的 `.github/workflows/build.yml` 一起上传。
2. GitHub → Actions → **Build unsigned iOS IPA** → Run workflow。推送到 main 也会触发。
3. 工作流在 macos-15 上生成 Xcode 项目，执行模拟器 XCTest，再编译设备版本并打包。
4. 成功后下载 `LANDownloader-v0.2-unsigned-IPA` artifact，解压得到 `LANDownloader-v0.2-unsigned.ipa`。
5. 用你现有的全能签流程签名安装。此工程不包含签名证书和描述文件。

**此交付尚未运行上述 Actions。** 如果工作流失败，请保留失败步骤日志；测试结果也会尽量作为单独 artifact 上传。不要把静态检查通过理解为 Xcode 编译通过。

## 验证范围

详见 `VALIDATION-中文.md`，包括已完成检查、未运行测试以及 iPhone 验收步骤。

参考：
- Caddy browse 内容协商：https://caddyserver.com/docs/caddyfile/directives/file_server
- Caddy 命令行目录服务：https://caddyserver.com/docs/command-line#caddy-file-server
- SwiftSoup：https://github.com/scinfu/SwiftSoup
