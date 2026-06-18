# ShareLocalDir — 局域网目录分享 Web Server 设计

- 日期：2026-06-18
- 状态：已批准（待 spec review）
- 部署目标：macOS 14.6（target 级；project 级为 26.5，target 覆盖）
- 技术栈：SwiftUI + 原生 SwiftNIO（`swift-nio` 2.101+），App Sandbox + Hardened Runtime

## 1. 目标

用户在 macOS 上选择一个本地目录，一键开启一个 HTTP server，在局域网内（只读）分享该目录：其他设备用浏览器浏览目录树并下载文件。UI 显示可点击复制的 `http://<局域网IP>:<端口>` 网址，并提供二维码、在浏览器打开、菜单栏状态项等便利。

## 2. 非目标（YAGNI）

- 不做上传 / 写入（只读分享）。
- 不做鉴权 / HTTPS / 访问控制（局域网信任环境；v1）。
- 不做纯菜单栏后台 App（保留主窗口 + Dock 图标，仅加辅助状态项）。
- 不做速率限制、日志面板、多目录并行分享。

## 3. 架构与组件

每个文件小而聚焦、可独立理解。纯逻辑抽成无副作用静态方法便于单测。

```
ShareLocalDir/
├─ ShareLocalDirApp.swift          @main；装配 WindowGroup + StatusItemController；退出时 stop()
├─ AppState.swift                  @Observable @MainActor：唯一状态源
├─ ContentView.swift               主窗口 UI
├─ StatusItemController.swift      NSStatusItem 菜单，反映 AppState
├─ server/
│   ├─ FileShareServer.swift       封装 NIO：start/stop，端口回退，暴露绑定结果
│   ├─ HTTPFileHandler.swift       ChannelInboundHandler：路由 → 列目录 / 发文件
│   ├─ DirectoryIndex.swift        纯函数：生成目录列表 HTML（可单测）
│   ├─ MimeTypeMap.swift           纯函数：扩展名 → Content-Type（可单测）
│   └─ PathResolver.swift          纯函数：URL→磁盘路径 + 路径穿越防护（可单测）
├─ net/
│   └─ LocalNetwork.swift          getifaddrs 探测局域网 IPv4（可单测）
├─ qr/
│   └─ QRCodeImage.swift           CoreImage CIQRCodeGenerator → NSImage
└─ storage/
    └─ BookmarkStore.swift         安全作用域书签持久化（记住上次目录）
```

**职责边界**：`AppState`（MainActor）是唯一状态源；`FileShareServer` 只负责网络（跑在 NIO 事件循环，不碰 UI）；纯逻辑零副作用。

## 4. HTTP Server 设计（方案 A：原生 SwiftNIO）

- 管道：`NIOPosix.ServerBootstrap` + `NIOHTTPServerProtocolHandler`（HTTP/1.1）+ 自定义 `HTTPFileHandler`（`ChannelInboundHandler`）。
- 需要 import：`NIOCore`、`NIOPosix`、`NIOHTTP1`（由 `SwiftNIO` umbrella 产品提供）。

### 路由与响应

- `GET /` → 共享根目录索引。
- `GET /<子路径>` → 子目录索引 或 文件下载。
- 目录：HTML 列表（名称、大小、修改时间；「上级目录」链接；点击进入子目录或下载文件）。
- 文件：流式传输（`NonBlockingFileIO` + `FileRegion`）；`Content-Type` 由 `MimeTypeMap` 给；支持 `Range`（返回 `206 Partial Content`，便于大文件/移动端/续传）。无 Range 时返回 `200 OK` 全量。
- 其他 method → `405 Method Not Allowed`。
- 找不到 → `404 Not Found`。

### 安全（路径穿越防护）

`PathResolver` 将请求路径解码并对每个 segment 做 `%`-decoding，再：
1. 拒绝绝对路径与含 `..` 的 segment（按规范化后判定）。
2. 用 `URL(fileURLWithPath:).standardizedFileURL.resolvingSymlinksInPath()` 解析。
3. 确认解析结果仍在共享根（`rootURL` 同样标准化）「之内」——标准化路径 `hasPrefix(rootStandardizedPath + "/")` 或相等。
4. 任一检查失败 → `403 Forbidden`，绝不读取根之外文件。

## 5. Entitlements 与沙盒（关键）

当前工程 **无 entitlements 文件**，且 `ENABLE_APP_SANDBOX=YES`。沙盒里**绑定监听端口必须**有 `com.apple.security.network.server`，否则 bind 失败。

新建 `ShareLocalDir/ShareLocalDir.entitlements`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.network.server</key><true/>
    <key>com.apple.security.files.user-selected.read-only</key><true/>
    <key>com.apple.security.files.bookmarks.app-sandbox</key><true/>
</dict>
</plist>
```

- `network.server`：监听端口必需。
- `files.user-selected.read-only`：`NSOpenPanel(canChooseDirectories:)` 选目录；Powerbox 授予该目录及其**整棵子树**读权限。只读分享足够。
- `files.bookmarks.app-sandbox`：持久化安全作用域书签，记住上次目录。

服务期间对该目录 `startAccessingSecurityScopedResource()`，停止时 `stopAccessingSecurityScopedResource()`。

### pbxproj 改动（仅两处，不动源文件注册）

CLAUDE.md 的「不要手改 pbxproj 注册源文件」仅针对源文件（文件同步组自动处理）。以下两类改动必须手动改 pbxproj：

1. **链接 SwiftNIO 产品**：当前 `packageReferences` 有 `swift-nio` 引用，但 target 的 `packageProductDependencies` 为空 → `import` 编译不过。新增 `XCSwiftPackageProductDependency`（`productName = SwiftNIO`，`package` 指向现有引用）并加入 target 的 `packageProductDependencies`。
2. **Entitlements 路径**：在 Debug/Release 两个 target 配置加 `CODE_SIGN_ENTITLEMENTS = ShareLocalDir/ShareLocalDir.entitlements;`。

## 6. 端口回退

- 首选 `7321`，被占用则 `+1`，最多尝试到 `7321+49`（共 50 次）。
- 「占用」判定：`bootstrap.bind(host:"0.0.0.0", port:)` 抛错（EADDRINUSE 经 NIO 抛出）→ 尝试下一端口。
- 全部失败 → 向 `AppState` 报错并保持未运行。
- 绑定 `0.0.0.0`（监听所有网卡），显示用局域网 IP。

## 7. 局域网 IP 探测

`LocalNetwork` 用 `getifaddrs` 枚举接口，筛选：
- `AF_INET`（IPv4 优先；可附带给 IPv6 的形式供后续）。
- 排除 loopback（`127.0.0.0/8`）与未启动接口。
- 优先 `en` 以太/Wi-Fi 接口的地址；取第一个匹配项。
- 无匹配 → 回退 `127.0.0.1`，UI 提示「未找到局域网 IP」。
- 多地址场景：主 URL 用首个非环回 IPv4（v1 不做多地址选择 UI）。

## 8. 状态管理与生命周期

`AppState`（`@Observable @MainActor`）字段：
- `selectedFolderURL: URL?`
- `isRunning: Bool`
- `serverURL: URL?`（`http://<ip>:<port>`）
- `statusText: String`（用于状态项）
- `errorMessage: String?`

流程：
- 启动 `start()`：校验已选目录 → `startAccessingSecurityScopedResource()` → `FileShareServer.start(rootURL:preferredPort:7321)` → 回调绑定端口 → 组装 `serverURL`（探测到的 IP + 端口）→ 更新状态/状态项。
- 停止 `stop()`：关 Channel → `stopAccessing` → 清 `serverURL`/状态。
- 同时只允许一个 server；`isRunning` 时禁用目录选择。
- App 退出（`applicationWillTerminate` 或 `ApplicationDelegate`）确保 `stop()`，避免端口/句柄泄漏。

并发：server 跑在 NIO 事件循环（非 MainActor）；跨 actor 回调用 `@MainActor` 方法或 `MainActor.run`/`Task { @MainActor in }` 更新 `AppState`。

## 9. UI 设计

### 主窗口（ContentView）

```
┌──────────────────────────────────────────────┐
│ 共享目录  [ …/Users/me/Documents     ] [选择]  │
│                                              │
│ 状态  ● 运行中 / 未运行                       │
│ 地址  http://192.168.1.20:7321       [复制]   │
│       [ QR 二维码 ]            [在浏览器打开]  │
│                                              │
│              [    启动 / 停止    ]             │
└──────────────────────────────────────────────┘
```

- 未选目录：启动置灰 + 提示「选择目录后点击启动」。
- 运行中：显示地址、二维码、「在浏览器打开」；按钮变「停止」，禁用目录选择。
- 文案走 String Catalog（项目已开启 `LOCALIZATION_PREFERS_STRING_CATALOGS`）。

### 菜单栏状态项（StatusItemController）

`NSStatusItem` 图标反映状态（●运行/○停止），菜单：
- 复制地址
- 在浏览器打开
- 停止 / 启动
- 显示主窗口
- 退出

仅作主窗口的辅助；不改为 LSUIElement 后台 App。

## 10. 便利功能

- **复制地址**：`NSPasteboard` 写入 `serverURL.absoluteString`；按钮反馈。
- **二维码**：`QRCodeImage` 用 `CIFilter.qrCodeGenerator`（`inputMessage` = URL 字符串）→ `NSImage`，无第三方依赖。
- **在浏览器打开**：`NSWorkspace.shared.open(serverURL)`。

## 11. 目录记忆（BookmarkStore）

- 选中目录后生成安全作用域书签，存入 `UserDefaults`。
- 下次启动读取并 `resolve()` 还原 `URL`（`startAccessing` 时再校验可达性）。
- 失败（目录已移动/删除）→ 清空并提示重新选择。

## 12. 错误处理

- 端口全部占用 / 目录访问失败 → UI 内联 `errorMessage` + 状态项变「未运行」。
- 客户端请求处理异常 → handler 内部返回对应 4xx/5xx，不影响 server 存活。
- IP 探测失败 → 地址回退 `127.0.0.1`，提示「未找到局域网 IP」。
- 书签失效 → 提示重新选择目录。

## 13. 测试策略

新增 **ShareLocalDirTests** unit test target（需改 pbxproj 添加 target；文件同步组下测试源文件自动编译）。

纯逻辑单测（无网络、无 UI）：
- `PathResolver`：合法子路径解析、`..` 拒绝、绝对路径拒绝、符号链接逃逸拒绝、URL 编码路径解码。
- `DirectoryIndex`：HTML 转义（`<`/`&`/引号）、名称排序、上级目录链接正确性。
- `MimeTypeMap`：常见扩展名映射、未知扩展名默认 `application/octet-stream`。
- `LocalNetwork`：环回地址被排除、空接口回退（用注入式设计便于测）。

NIO server 的端到端（可选，用 `URLSession`/`NIOClientTCPChannel` 本地回环拉取索引页与文件字节）作为集成冒烟测试。

## 14. 项目改动清单（实现时落地）

1. `ShareLocalDir/ShareLocalDir.entitlements` 新建（见 §5）。
2. pbxproj：
   - 新增 `XCSwiftPackageProductDependency`（`SwiftNIO`）+ 加入 target `packageProductDependencies`。
   - 两个 target 配置加 `CODE_SIGN_ENTITLEMENTS`。
   - 新增 `ShareLocalDirTests` target（+ 链接依赖、host app）。
3. 新增源文件（见 §3，文件同步组自动纳入编译）。
4. 替换 `ContentView.swift` 模板内容；`ShareLocalDirApp.swift` 装配状态项与退出清理。

## 15. 风险与备注

- **SwiftNIO 产品未链接** 是当前最大阻断项——不修就编不过。
- **沙盒 + 网络监听**：必须 `network.server`，自动签名（`CODE_SIGN_STYLE=Automatic`）下应可签。
- **目录子树读取**：`user-selected.read-only` + Powerbox 选目录即可读整棵子树，无需更宽权限。
- 路径穿越是安全核心，必须有单测覆盖。
- 多网卡/多 IP 场景 v1 仅取首个非环回 IPv4。
