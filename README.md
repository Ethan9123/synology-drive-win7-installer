# Synology Drive Client · Win7 受控安装工具

为必须保留 Windows 7 的测试环境准备固定的 Synology Drive Client 与 VxKex-NEXT 安装包，并提供校验、安装状态检查和验收指引。

**当前是实验性方案，不是已通过生产部署验收的“一键安装”。** Win7 已停止支持，VxKex 没有恢复微软或群晖对 Win7 的支持。程序能打开，也不等于同步数据正确或安全软件能够共存。

## 从只读检查开始

双击 `一键安装.cmd`，或运行：

```powershell
powershell.exe -NoProfile -File .\Install-SynologyDrive.ps1
```

默认 `CheckOnly`：显示系统、固定组件和缓存校验结果。不下载、不请求管理员权限、不启动安装器、不写安装日志，也不修改注册表、BITS、杀毒软件或自启动。

完整流程要求 **Windows PowerShell 5.1（powershell.exe）**。原生 PS2 会在最前面停止，不再把部分语法兼容宣传为完整支持。PowerShell 7 用于开发测试，不作为安装宿主。若系统执行策略阻止脚本，先核验来源并遵循本机管理策略，不自动更改执行策略。

## 三种模式

| 模式 | 用途 | 权限与副作用 |
|---|---|---|
| `CheckOnly`（默认） | 本机与缓存只读检查 | 普通用户；不联网下载、不启动程序、不创建缓存/日志 |
| `DownloadOnly` | 在能访问上游的 Windows 准备机获取两个固定安装包 | 普通用户；只写缓存；不安装 |
| `Install` | 在隔离 Win7 SP1 测试机安装并检查预期版本 | 管理员；启动明确确认过的安装器；可能有上游安装器系统改动 |

准备安装包：

```powershell
powershell.exe -NoProfile -File .\Install-SynologyDrive.ps1 -Mode DownloadOnly
```

在另一台机器准备后，将完整仓库与 `downloads` 一起复制到测试机。先阅读 [验收与回退流程](docs/ACCEPTANCE.md)，再在测试机的管理员 Windows PowerShell 中执行：

```powershell
powershell.exe -NoProfile -File .\Install-SynologyDrive.ps1 -Mode Install -Offline
```

`-Offline` 禁止工具下载或查询发布 API，缓存缺失/不匹配就停止。Windows 的 Authenticode 验证仍可能尝试证书链/吊销查询，不能把这个开关理解为系统级断网；需要完全隔离时由测试环境限制网络，并记录签名验证结果。

`-CacheDirectory` 可指定缓存目录。旧中文脚本名仍保留，参数转发到新入口；默认也只读。

## 固定版本与校验

来源清单在 [config/installers.psd1](config/installers.psd1)。两套组件都固定版本、精确文件名、大小、SHA256 和官方 URL；运行时不追踪 `latest`，不按名称自动挑一个旧包或 Debug 包。

| 组件 | 固定版本 | 精确大小 | 状态 |
|---|---|---:|---|
| Synology Drive Client x86 | 4.0.3-17892 | 71,342,576 字节 | 官方包哈希已核对；执行时要求 Windows 验证签名 Valid 且发布者为 Synology Inc. |
| VxKex-NEXT Release | 1.2.3.2466 | 5,025,016 字节 | 与上游 asset digest 一致；没有嵌入签名；Win7 配对验收待完成 |

固定哈希：

```text
Synology: a8cfce9ee1a1c6705b28c013d5ab92029e499c34f6d8142dcb69f4d8e124c4a4
VxKex:    e8fa07f6919f48bd3c381dedcbd54dabc147c824522f1ac2a8fc60366f43f535
```

这些值依据 2026-11-16 从指定上游取得的样本。哈希一致只证明字节与这个基准相同，不证明上游、构建过程或文件行为安全。该组合仍标为 `PendingWin7Validation`。

缓存、下载、手工导入均使用同一套大小与哈希检查。传输先写独立 `.part` 文件，验证后才提交到目标文件；异常残留会清理。校验失败立即停止，不降低标准后换源重试。在线模式可以用验证通过的新包替换错误缓存；离线模式直接拒绝，不能因名字相同而放行。

安装时先将两个包复制到仅 Administrators/SYSTEM 可写的临时目录，并在任何安装器启动前验证两个包的身份和签名策略。每个安装器启动前再次校验，运行期间保留禁止写入/删除共享的文件句柄。这个机制不能防住已经控制管理员账号的攻击者；真实 Win7 安装器与文件锁的兼容性仍需验收。

升级必须一起更新清单中的版本、URL、文件名、大小、SHA256，并重新审阅安全公告和验收结果。不要通过清空 hash 或只改版本号升级/回退。固定版本也需要维护：4.0.3 的发布说明包含安全修复，不能仅凭旧版容易启动就退回 4.0.2。

## 镜像与防护

默认仅官方直连：已运行的 BITS 可用时先尝试 BITS，再尝试 `Invoke-WebRequest`。不会启动、重启或更改 BITS 配置。Web 请求仅在当前进程临时选择 TLS1.2，随后恢复原值；不会开启系统 TLS1.1 或重写 WinHTTP/SCHANNEL 注册表。

GitHub 第三方代理默认关闭。确需使用时，可在准备机明确加 `-AllowGitHubMirror`；它只用于固定的 VxKex 资源，仍必须匹配清单 SHA256。代理不是上游发布者，也不能提供新的预期 hash。GitHub 不可达时，更建议用另一台机器获取官方包后离线复制。

**遇到杀毒软件拦截就停止核查，不关闭实时防护，不给整个文件夹或 PowerShell 加排除。** 保存准确文件哈希、产品/引擎版本和告警，向安全软件厂商复核。源码公开或多个人都遇到同一告警，都不足以证明它是误报。

VxKex 通过 IFEO/DLL 加载扩展兼容性。当前固定版本的源码还包含系统目录 DLL、免 UAC 提示的配置任务和登录后向 Explorer 注入 DLL 的逻辑。执行 `Install` 必须在看到这些说明后输入这一个 VxKex 包的完整 SHA256，确认只在隔离测试机上试验；确认不跨运行保存。此例外仅接受清单中的 VxKex 和 `NotSigned` 状态，不能绕过 `HashMismatch`、`NotTrusted`、其他发布者或未知版本。

## 安装结果如何解释

- 仅有目录不再被当成已经安装；查找确切程序与文件版本，VxKex 设置程序使用 `KexCfg.exe`。
- 已有其他版本会停止，避免自动升级影响依赖同一兼容层的其他程序。
- 非零失败码会阻断后续步骤；即使退出码为 0，找不到预期版本也算取消/未完成。
- 遇到 3010/1641，标记需要重启并停止后续步骤；工具不主动重启。上游安装器本身的重启行为要实机确认。
- 预期版本已存在只说明版本探测命中，不是已安装文件的完整安全审计。
- 找到两个预期版本后，只提示继续配置和验收，不宣称部署成功。不自动启动同步客户端或创建自启项。

`diagnose-launch.ps1` 是主动启动诊断，会尝试运行 Synology 客户端；`verify-autostart.ps1` 可在用户明确选择后修改快捷方式（默认跳过）。二者不属于只读预检，不能代替默认入口。

## Win7 前置条件与常见问题

测试基线为 Win7 SP1、Windows PowerShell 5.1，以及适用的官方系统更新。记录 SHA-2 支持、根证书和系统时间、UCRT、DLL 目录能力、平台更新、实际安全软件与 TLS 状态。累计更新可能替代旧 KB，不能只根据 `Get-HotFix` 缺一条编号就断言缺能力。

- 缺 `api-ms-win-crt-*`：先核查微软 UCRT 更新（KB2999226 支持 Win7 SP1）及运行库；这与缺少更高版本 Windows API 是两类问题。
- 下载 TLS 失败：工具不自动改全机安全策略。由管理员单独评估官方更新/设置，或使用离线分发。
- 签名失败：区分无签名、文件修改、信任链/根证书、时间或吊销查询问题；不关闭证书验证。
- 多个安装版本或已安装不同 VxKex：停止自动流程，先评估其他应用依赖和迁移/回退。

## 开发验证

```powershell
./tests/download-validation.ps1
./tests/safety-contracts.ps1
# 仅 Windows PowerShell 5.1：只运行 CheckOnly 与缺缓存的 DownloadOnly -Offline
./tests/entrypoint-checks.ps1
```

下载与安装编排测试只使用合成数据、模拟签名和模拟进程，不运行安装器或真实网络。CI 在 Windows PowerShell 5.1 和 PowerShell 7 执行回归与解析检查，再用 Windows PowerShell 5.1 检查真实只读入口。CI 成功不能替代 Win7 实机验收。

## 资料

- [验收、停止条件和回退记录](docs/ACCEPTANCE.md)
- [本次改动与迁移说明](docs/CHANGE-NOTES.md)
- [VxKex 固定 Release](https://github.com/YuZhouRen86/VxKex-NEXT/releases/tag/1.2.3.2466)
- [VxKex 安装源码](https://github.com/YuZhouRen86/VxKex-NEXT/blob/52f59fea708c9df6691904ee430d9d64a057933f/KexSetup/perform.c)
- [Synology 官方归档](https://archive.synology.com/download/Utility/SynologyDriveClient)
- [微软 UCRT 更新](https://support.microsoft.com/en-gb/servicing/os/windows/2020/04/update-for-universal-c-runtime-in-windows)
- [微软 TLS1.0/1.1 弃用说明](https://learn.microsoft.com/en-us/windows/win32/secauthn/tls-10-11-deprecation-in-windows)
- [微软文件复核入口](https://www.microsoft.com/en-us/wdsi/filesubmission)
