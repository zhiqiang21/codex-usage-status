# Codex Usage Status

[English](README.md) | 简体中文

原生 macOS 菜单栏工具，通过本机 `codex app-server` 显示 Codex 的：

- 5 小时和 7 天窗口的剩余百分比
- 两个窗口各自的重置倒计时
- 可用重置卡数量（仅在大于 0 时显示）

Codex 账户查询保持只读，不会消费重置卡，也不会直接读取或记录 Codex 认证文件。应用还提供本机开发目录占用统计，以及需确认具体清单的单项和批量永久清理功能。

## 环境要求

- macOS 13 或更高版本
- 已安装并登录 ChatGPT 账户的 Codex CLI

普通用户不需要安装 Xcode。Xcode 只用于开发或自行编译本项目。

默认自动检测：

```text
/opt/homebrew/bin/codex
/usr/local/bin/codex
```

也可以在应用弹层中手动选择 `codex` 可执行文件。

## 下载与安装（普通用户）

1. 从项目发布页下载最新的 `CodexUsageStatus-版本号-macos-universal.zip`。
2. 双击 ZIP 文件解压，得到 `CodexUsageStatus.app`。
3. 把 `CodexUsageStatus.app` 拖到访达的“应用程序”文件夹。
4. 在“应用程序”中双击 `CodexUsageStatus`。
5. 启动后到屏幕右上角的菜单栏查看用量。

这是菜单栏应用，所以启动后不会出现普通窗口，也不会在 Dock 中显示图标。

正式发布包经过 Apple 签名和公证后可以直接双击运行。如果下载的是开发者临时提供的未公证版本，首次启动时请在访达中右键点击应用，选择“打开”，再确认一次“打开”。只应对可信来源的安装包执行此操作。

## 使用说明（第一次使用）

### 1. 确认 Codex CLI 可以正常使用

打开 macOS 自带的“终端”，输入：

```bash
codex --version
```

如果能看到版本号，说明 Codex CLI 已安装。如果提示 `command not found`，并且电脑中已经安装 Node.js 和 npm，可以执行官方安装命令：

```bash
npm install --global @openai/codex
```

然后确认已经登录 ChatGPT 账户：

```bash
codex login
```

按照终端提示在浏览器中完成登录。可以继续运行下面的命令检查登录状态：

```bash
codex login status
```

本应用复用 Codex CLI 的登录状态，不需要填写 API Key。

> 当前版本只支持通过 ChatGPT 账户登录的 Codex。API Key 和 Amazon Bedrock 登录方式不能查询这里展示的账户用量。

### 2. 认识菜单栏显示

菜单栏采用双行布局，并用半透明玻璃质感底色和细边框标识模块边界。默认同时显示两个窗口；浅色模式使用深色图标与文字，暗黑模式使用白色图标与文字并降低底色亮度：

- 时钟图标后的百分比表示 5 小时剩余额度；下行显示本机时区的重置时刻，如 `18:00`。跨天时显示 `明 01:00`。
- 日历图标后的百分比表示一周剩余额度；下行使用 `MM.dd` 格式显示重置日期，如 `11.08`。
- 卡片图标后的数字表示可用重置卡次数，下行标注“重置卡”；“显示重置卡次数”开关默认开启。关闭、数量为 0 或未知时整组隐藏，详情面板仍显示数量。
- `…` 表示正在读取，`--%` / `--` 表示额度或重置时间暂不可用，“待重置”表示已到重置时刻、等待后端更新。另一个窗口仍可正常显示。

在下拉面板的“显示模式”中，可以选择“5 小时”“一周”或“全部”。选择立即生效并自动保存。悬停状态栏可查看完整重置日期。日期标记和详情表格倒计时每分钟在本地更新。

### 3. 查看详细信息

点击菜单栏中的用量区域，会打开详情面板。面板中可以查看：

- 通过“窗口 / 剩余 / 重置”三列表格，查看 5 小时和一周的剩余百分比、进度条和重置倒计时。
- 鼠标悬停在重置倒计时上，可查看具体重置日期。
- 可用重置卡数量。
- 底部显示上次更新时间，鼠标悬停可查看预计下次刷新时间。

右上角的刷新按钮可以立即重新读取数据。

### 4. 设置自动刷新

在“自动刷新”行的下拉菜单中选择刷新频率：

- 5 分钟。
- 10 分钟，默认选项。
- 30 分钟。
- 1 小时。

选择后会自动保存，下次启动不需要重新设置。休眠唤醒或到达额度重置时间时，应用也会主动校准一次。

### 5. 设置登录时启动

安装到“应用程序”后，可以在详情面板中开启“登录时启动”。如果系统要求批准，请根据提示前往：

```text
系统设置 → 通用 → 登录项与扩展
```

### 6. 退出应用

点击菜单栏用量区域，在详情面板底部点击“退出”。

### 查看开发存储与批量清理

详情面板中的“开发存储”独立显示以下目录的磁盘占用，不依赖 Codex 登录或查询成功：

```text
~/Library/Developer/Xcode/iOS DeviceSupport
~/Library/Developer/CoreSimulator/Devices
/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime
~/.codex
```

先点击“开发存储”展开该区域，再点击目录标题展开按占用降序排列的版本或设备列表，可查看完整路径、修改时间，以及模拟器名称、系统版本、UDID 和实时状态；“在 Finder 显示”可查看内部文件。辅助文件和无法识别的目录也会显示，但只提供查看功能。面板可以滚动。

“iOS 模拟器运行时”只统计指定 AssetsV2 目录中的资源包，不叠加挂载卷容量，能识别元信息时显示版本和构建号。应用通过 `simctl runtime list --json` 核实资源包与唯一系统标识的对应关系；仅对系统允许删除、状态就绪且没有关联设备处于启动、运行或关闭等未确认空闲状态的运行时启用“卸载运行时”。卸载需逐个确认，清单会显示关联设备，说明重新使用这些设备需要安装对应 Runtime。执行前再次检查文件身份和实时状态，通过 `simctl runtime delete <identifier>` 管理卸载，不直接删除 AssetsV2 文件、不主动关闭设备、不自动重试。若工具、权限或映射检查失败，可通过“在 Xcode 中管理”打开 Xcode，然后前往 Settings → Components。资源仍存在时会如实报告，不改为原始文件删除。

“Codex 数据”按子目录统计，包括归档会话（`archived_sessions`）、生成图片（`generated_images`）和会话记录（`sessions`）；只读取文件元信息，不读取认证、会话、数据库或图片内容。`cache`、`log` 条目提供“查看可清理项”，按需列出具体文件，再勾选、全选或取消选择：

- 缓存仅开放 `cache/codex_apps_server_info`、`cache/codex_apps_tools`、`cache/remote_plugin_catalog` 下直属的普通 `.json` 文件。
- 日志仅开放 `log` 下修改时间超过 7 天的普通 `.log` 文件、数字编号轮转日志及对应 `.gz` 文件。
- 归档会话、生成图片、SQLite/WAL/SHM、认证、配置、插件、工作树和其他未知缓存均不开放清理；不会清空父目录。

每次文件删除均需确认具体路径、大小及修改时间。缓存可能重新生成；旧日志删除后无法用于历史排障。执行前复核完整文件身份并用精确路径执行 `lsof`，变化、占用、符号链接或检查不完整时停止该项。刷新 Codex 统计后，之前加载的候选文件及其勾选会失效，需重新加载。

首次打开面板时扫描；再次打开时，超过 5 分钟的缓存会刷新。每个目录还提供独立的手动刷新按钮。多组目录的遍历在后台串行执行；Runtime 和 Codex 日常监控不保留递归文件身份清单，只有准备卸载或加载候选文件时才生成对应校验证据，以减少内存占用。存储扫描不使用 Codex 的自动刷新频率。大小以 MiB/GiB 表示，权限不足时标记扫描不完整，无法读取不会显示为零；刷新失败保留的数据会标记为过期。

- **永久删除**：只删除选中的 DeviceSupport 版本。后续调试对应系统的真机时，可能需要重新生成或下载支持文件。
- **删除设备**：通过 `simctl delete <UDID>` 删除选中的模拟器设备，包括应用和本地数据；不会删除系统 Runtime。此操作不能恢复，需要时须重新创建设备。

展开目录后，可用复选框选择多个可清理条目；每组提供“全选”和“全部取消”，全选会跳过不可清理条目。DeviceSupport、模拟器设备和 Codex 候选文件允许批量选择，Runtime 仅逐个卸载，“删除所选”会展示完整的可滚动确认清单，取消确认会保留勾选。刷新后已变化或消失的条目会自动取消选择。单项按钮仍可使用。

已关闭的模拟器，以及 `simctl` 明确标记为不可用且状态为 `Creating` 的创建残留设备，均可单项或批量选择删除。正常创建中、启动中、运行中、关闭中，以及无法核实实时身份的设备保持禁用。

每次操作均需确认具体目标清单。DeviceSupport 和模拟器设备目录删除会复核路径、目录及子项身份和设备状态，并使用 `lsof +D` 检查目录后代是否被占用；Codex 文件检查精确文件路径，Runtime 卸载则复核系统管理标识及关联设备状态。目标变化、运行中的设备、状态未知、符号链接目标、挂载点或无法完整检查占用时，清理会停止；不会自动关闭设备、重试或改为直接删除模拟器文件夹。

模拟器实时状态及删除功能需要安装 Xcode，并正确设置当前开发者目录；工具或 CoreSimulator 服务不可用时，磁盘统计仍可使用，但设备删除会禁用。

批量清理在后台串行执行并显示进度，避免并发删除带来的磁盘争用；总占用仅在批次前后分别扫描每个涉及目录一次，同一卷只统计一次可用空间变化。批次中只复核当前目标，结束后统一更新列表；某项失败不会重试，其他已确认条目继续独立处理，并逐项展示结果。

清理后分别显示重新测量的目录占用变化和卷可用空间变化。关闭状态栏面板，或展开、折叠任一目录时，会清除本次删除结果提示；已开始的后台清理继续执行并更新占用，但被清除的结果不会重新出现。APFS 共享块、快照及其他进程可能影响结果，扫描占用不等于保证可释放的空间。请勿删除仍需保留的设备数据。

## 系统状态监控

详情面板中的“系统状态”显示当前电脑的系统盘容量、内存已用估算、整机 CPU 利用率，以及主要联网接口的上传和下载速度。系统监控独立于 Codex CLI；未登录 Codex 或用量查询失败时仍可使用。

在“系统监控设置”中，每项指标都有独立的“菜单栏”和“详情”开关，修改立即生效并自动保存。默认详情五项全开、菜单栏五项全关；菜单栏开启后，按磁盘、内存、CPU、上传、下载的顺序显示。菜单栏空间有限，可按需选择指标。

- 系统刷新可选 **1 秒、2 秒、5 秒**，默认 **2 秒**，不影响 Codex 用量的 5／10／30／60 分钟刷新设置。
- 系统盘容量每 **30 秒**更新，读取启动盘数据卷，不扫描目录，不统计磁盘读写速度或外接磁盘。
- 内存已用估算为“匿名内存减可清除部分，加 wired 与压缩器实际占用”，使用实际内存页大小；与活动监视器可能存在口径和采样时差。
- CPU 按两次采样的忙碌时间增量计算，显示整机 **0–100%** 利用率。
- 上传和下载显示当前主要联网接口的实时字节速度（B/s、KB/s、MB/s、GB/s，十进制单位）。优先选择 IPv4 主要接口，缺失时使用 IPv6；不同时累加物理接口与 VPN 隧道。界面显示实际接口名称。
- CPU 和网速首次显示“等待采样”；切换接口、计数重置、休眠唤醒后重新建立基线，无主要接口时显示“未连接”。单项读取失败会显示原因，不影响其他指标。
- 菜单栏启用项持续采集；只在详情启用的指标仅在面板打开期间采集。全部关闭后停止采集，设置入口仍可使用。

系统指标仅在本机读取和展示，不会上传或保存历史记录，也不需要管理员权限。


## 常见问题

### 提示“未找到 Codex CLI”

先在终端运行 `codex --version`。如果终端可以找到，但应用仍然找不到：

1. 打开应用详情面板。
2. 点击面板右下角的齿轮，展开“Codex CLI”设置。
3. 点击“选择…”。
4. 选择实际的 `codex` 可执行文件。

常见位置是：

```text
/opt/homebrew/bin/codex
/usr/local/bin/codex
```

### 提示“请先登录 ChatGPT 账户”

在终端运行：

```bash
codex login
```

登录完成后，回到应用点击右上角的刷新按钮。

### 菜单栏没有显示用量

- 打开“活动监视器”，搜索 `CodexUsageStatus`，确认应用正在运行。
- 菜单栏空间不足时，先退出部分其他菜单栏应用。
- 本应用不会显示在 Dock 中，请到屏幕右上角查找。

### 数据长时间没有变化

- 点击详情面板右上角的刷新按钮。
- 检查 Codex CLI 是否仍处于登录状态。
- 确认自动刷新频率不是设置成了 1 小时。
- 如果数据旁边出现过期提示，应用会按照 1、2、5、10、30 秒的间隔有限重试。

### “登录时启动”没有生效

确认应用已经移动到“应用程序”文件夹，然后重新关闭并开启“登录时启动”。如果仍然无效，到“系统设置 → 通用 → 登录项与扩展”中检查是否需要手动批准。

## 开发者构建与测试

开发环境需要 Xcode 26（项目使用 Swift 6）。普通用户不需要执行本节中的命令。

```bash
xcodebuild \
  -project CodexUsageStatus.xcodeproj \
  -scheme CodexUsageStatus \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/codex-usage-status-derived \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project CodexUsageStatus.xcodeproj \
  -scheme CodexUsageStatus \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/codex-usage-status-derived \
  CODE_SIGNING_ALLOWED=NO \
  test
```

若要额外验证本机 Codex CLI 的真实 JSON-RPC 链路：

```bash
xcodebuild \
  -project CodexUsageStatus.xcodeproj \
  -scheme CodexUsageStatus \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/codex-usage-status-derived \
  CODE_SIGNING_ALLOWED=NO \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CODEX_INTEGRATION_TESTS' \
  -only-testing:CodexUsageStatusTests/ProtocolDecodingTests/testLiveCodexAppServerWhenEnabled \
  test
```

若要使用“登录时启动”，请在 Xcode 中以 “Sign to Run Locally” 构建，并将应用放到 `/Applications` 后再启用。

## 生成发布包

运行：

```bash
./scripts/package-release.sh
```

脚本会执行 Release 构建，并在 `dist/` 中生成：

```text
CodexUsageStatus.app
CodexUsageStatus-0.1.0-macos-universal.zip
CodexUsageStatus-0.1.0-macos-universal.zip.sha256
```

ZIP 同时包含 Apple 芯片和 Intel 架构。未配置发布证书时，脚本使用 ad-hoc 签名，适合本地测试或可信范围内分发，但用户首次打开时会遇到 macOS 安全提示。

公开分发时，应使用 Apple Developer Program 提供的 Developer ID Application 证书签名并完成公证：

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
NOTARYTOOL_PROFILE="codex-usage-status-notary" \
./scripts/package-release.sh
```

`NOTARYTOOL_PROFILE` 是预先通过 `xcrun notarytool store-credentials` 保存到钥匙串的配置名称。完成签名和公证后，把 ZIP 以及 `.sha256` 文件上传到项目发布页，普通用户即可按“下载与安装”一节使用，不需要 Xcode。

## 刷新策略

- 可选 5 分钟、10 分钟、30 分钟、1 小时，默认 10 分钟。
- 详情表格的重置倒计时每分钟在本地更新，不会增加网络请求。
- 手动刷新会重新计算下一次刷新时间。
- 到达任一窗口的配额重置时间或系统睡眠后发现数据过期时，会立即校准。
- `account/rateLimits/updated` 通知只在本地合并额度字段，不会绕过用户选择额外轮询。
