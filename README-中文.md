# LAN Downloader — 第一版源码

用途：Windows 11 通过 Caddy 在局域网提供视频，iPhone 一次多选并创建独立的 iOS 后台下载任务，下载文件显示在系统「文件」App 的「我的 iPhone → LAN Downloader」中，之后可用 APlayer 打开。无需 ZIP。

> 状态：代码原型。此环境没有 Xcode / iPhone，**尚未经过云端实际编译或真机锁屏、100GB 文件验证**。不要把它当作已经完成测试的正式应用。

## 1. Windows 端

将 `windows/Generate-Manifest.ps1` 和 `windows/Start-LANDownloader.bat` 放在同一个文件夹；Caddy 仍放在 `C:\Caddy\caddy.exe`。

默认共享目录：`E:\迅雷下载`；服务器地址：`http://192.168.0.245:8080`。如果实际 IP 不同，修改 BAT 文件里的 `BASEURL`，再在 iPhone App 里修改地址。

双击 `Start-LANDownloader.bat`。它会先扫描视频，生成 `E:\迅雷下载\_lan_manifest.json`，然后启动 Caddy。**每次新增或删除视频后，需重新运行生成脚本并刷新 App 清单**；不需要重新打包安装 App：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "windows\Generate-Manifest.ps1" -Root "E:\迅雷下载" -BaseURL "http://192.168.0.245:8080"
```

服务只在可信局域网使用：目前 Caddy 文件共享**无身份认证、HTTP 明文**，不要开放 WAN 端口，也不要把工作敏感文件放在共享目录。

## 2. GitHub Actions 云端构建

1. 新建个人 GitHub 仓库，上传此项目的全部目录与 `.github/workflows/build-ios.yml`（`.github` 是隐藏目录，上传时也要包含）。
2. 在 Actions 选项卡选择 `Build unsigned iOS IPA`，点击 `Run workflow`。
3. 等构建绿色通过后，在该次执行的 Artifacts 下载 `LANDownloader-unsigned-IPA`，解压获得 `LANDownloader-unsigned.ipa`。
4. 用你自己的全能签和**有效且包含设备权限**的证书签名，再安装到 iPhone。此 IPA 只包含未签名 App，不含证书、Provisioning Profile。
5. 本项目的 Bundle ID 为 `com.lantransfer.downloader`；证书签名工具可能要求替换为你配置文件允许的 Bundle ID。

## 3. iPhone 端

首次打开 App 允许本地网络访问。点击「刷新文件清单」，勾选多个视频或全选，点击「加入后台下载队列」。切到「下载」查看进度。完成后去「文件 → 我的 iPhone → LAN Downloader」，用 APlayer 打开文件。用 1GB、10GB 文件验证，再尝试 100GB。Windows 不能休眠。不要手动从多任务界面强制关闭 App。

## 4. 已知限制

- 目前断点续传仅指**失败后重新下载**，不支持从中断字节继续：若要真正断点续传，需要存储 `resumeData` 并测试服务端 HTTP Range 支持。
- 用户手动取消时，目前不会生成可恢复的 resumeData。
- 下载完成时，iOS 系统可能需要存放临时文件及目标文件的空间；即使使用 move，不保证峰值占用严格等于一份文件。下载前务必检查手机空间。
- 大量任务同时添加后实际并发数由 iOS 自行调度；锁屏吞吐速度不能保证。当前版本没有并发数量限制或暂停功能。
- 以当前记录 ID（相对路径）为唯一标识；如果切换到另一台共享路径相同的电脑，可能发生任务 ID 冲突。不要同时混用多个来源。
- HTTP 明文及 ATS 放宽只适合个人可信局域网。可后续改为仅允许局域网地址范围或采用 HTTPS。
- `UIBackgroundModes` 及网络签名配置需要在真实云端 Xcode 工程中进一步校验。
