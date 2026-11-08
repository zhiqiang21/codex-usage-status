# Codex Usage Status

[English](README.md) | 简体中文

原生 macOS 菜单栏工具，通过本机 `codex app-server` 显示 Codex 的：

- 5 小时和 7 天窗口的剩余百分比
- 两个窗口各自的重置倒计时
- 可用重置卡数量（仅在大于 0 时显示）

应用保持只读，不会消费重置卡，也不会直接读取或记录 Codex 认证文件。

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
