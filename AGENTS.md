# AGENTS.md

适用于整个仓库；子目录规则在其范围内优先，当前任务的明确要求优先于默认约定。

## 项目概况

- 原生 macOS 菜单栏工具：通过本机 `codex app-server` 展示账户用量，并独立提供 Xcode 开发存储扫描与清理。
- Swift 6、SwiftUI、Foundation、AppKit、ServiceManagement；Xcode 26，XCTest。
- 应用最低 macOS 13，测试 Target 最低 macOS 14；发布支持 `arm64` 和 `x86_64`。
- 保持 `MenuBarExtra` / `LSUIElement` 应用形态和严格并发检查；新增 API 检查系统版本兼容性。

## 协作与修改

- 默认简体中文沟通，英文代码标识符，注释遵循现有风格。用户熟悉 JS/TS 与 React，重点解释 Swift 和 macOS 特有机制。
- 修改前检查分支、工作区、相关源码与 README；保留已有未提交改动，避免无关重构和新依赖。
- 新增 Swift 文件时，同步维护 `CodexUsageStatus.xcodeproj/project.pbxproj` 的文件引用与 Target Sources。
- 修改持久化设置或公共协议前检查兼容性；用户可见行为变化时同步更新中英文 README。
- 未明确要求时不提交或推送；提交使用 Conventional Commits。

## 架构与并发

源码位于 `CodexUsageStatus/`，保持 View → Store → Provider / Service 分层：

- `UsageViews.swift` / `UsageStore.swift` / `UsageModels.swift`：用量展示、刷新状态与设置、快照模型。
- `CodexProtocol.swift` / `CodexAppServerClient.swift` / `JSONLineFramer.swift`：协议模型、子进程 JSON-RPC 与行组帧；通过 `RateLimitProviding` 注入。
- `DeveloperStorageViews.swift` / `DeveloperStorageStore.swift` / `DeveloperStorageService.swift` / `DeveloperStorageModels.swift`：存储展示、选择与确认、扫描与清理、数据模型。
- `StorageCommandRunner.swift`：命令超时、输出收集与进程回收；`LaunchAtLoginController.swift`：登录启动。

UI 状态使用 `@MainActor` + `ObservableObject`，客户端使用 actor 隔离。阻塞扫描和进程等待放到后台；仅使用 `async` 或 `Task` 不代表已离开 MainActor。明确任务取消和资源释放，防止旧回调污染新状态；continuation 恰好恢复一次。外部命令使用可执行路径与参数数组，设置超时并排空管道。不通过降低检查、吞异常或无依据的 `@unchecked Sendable` 掩盖问题。

## 业务与安全边界

### Codex 用量

- 保持账户链路只读：复用 CLI 登录，不直接读取认证文件、不消费重置卡、不发起模型任务，不记录认证信息或完整协议载荷。
- 修改协议时核对目标 CLI 的 schema 或官方资料；按 `windowDurationMins` 识别 300 / 10080 分钟窗口，不假设 primary / secondary 的含义。
- 区分缺失、未知与零值；稀疏通知合并不能清空已有数据。
- 保留刷新设置、唤醒及重置校准、有限断线恢复；本地倒计时和推送通知不增加轮询，避免重复并发刷新。

### 开发存储

- 存储扫描与 Codex 查询独立，缓存当前为 5 分钟；仅处理 `~/Library/Developer/Xcode/iOS DeviceSupport` 和 `~/Library/Developer/CoreSimulator/Devices`。
- 区分空目录、缺失、读取失败和过期数据；按分配空间统计，不承诺等量释放。
- 删除须确认具体清单，执行前复核路径、目录及子项身份、符号链接、挂载点、设备状态和 `lsof +D` 占用；目标变化或检查不完整时拒绝执行。
- 模拟器通过 `simctl delete <UDID>` 删除，不自动关闭设备、不降级为直接删除文件夹、不自动重试删除；保留现有设备状态限制。
- 批量清理串行执行，逐项报告结果；避免逐项重复全量扫描，同卷空间变化只统计一次。
- 测试使用临时 home 和命令替身；未经明确授权，不删除真实开发目录或设备数据。

## 验证与交付

在仓库根目录执行，按改动选择 `build` 或 `test`：

```bash
xcodebuild -project CodexUsageStatus.xcodeproj \
  -scheme CodexUsageStatus -destination 'platform=macOS' \
  -derivedDataPath /tmp/codex-usage-status-derived \
  CODE_SIGNING_ALLOWED=NO test
```

- 测试位于 `CodexUsageStatusTests/`，可用 `-only-testing:CodexUsageStatusTests/<TestClass>` 缩小范围；纯文档修改无需构建。
- 真实 Codex 集成测试需显式启用 `CODEX_INTEGRATION_TESTS`，命令见 README；不得把跳过视为验证通过。
- UI 改动按需验证菜单栏、弹层滚动、设置和确认流程；禁用签名的构建不能验证登录启动、签名或公证。
- 发布使用 zsh 脚本 `scripts/package-release.sh`；脚本语法检查使用 `zsh -n`。打包会覆盖同名产物，不作为默认验证；公证和上传需明确授权。
- 结束前检查差异，不加入构建产物或敏感信息；简述完成内容、实际验证及关键未验证项。
