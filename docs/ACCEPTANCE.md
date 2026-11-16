# Win7 分阶段验收

状态：**待实机执行**。固定样本与离线测试不是部署批准。每次验收记录仓库提交、两个安装包 SHA256、系统镜像标识、架构、PS/CLR、NAS/Drive Server 版本、安全软件版本和日期。

| 阶段 | 操作 | 通过条件 |
|---|---|---|
| 0 基线 | 隔离 Win7 SP1；做完整镜像/快照；运行默认 CheckOnly | 不创建缓存/安装日志、不改系统；记录 PS、补丁能力、TLS、BITS、安全产品、任务、IFEO、shell 扩展、自启 |
| 1 准备包 | 受支持 Windows 准备机官方直连 DownloadOnly；核验来源、hash、签名、告警 | 版本与清单一致；VxKex 无签名风险经过明确审查；拦截未解释则停止 |
| 2 离线回归 | Win7 SP1 x86/x64 + PS5.1 跑合成数据测试；PS2 只测入口提前拒绝 | 无真实网络/安装进程；正确清理临时文件；PS2 不创建目录或改系统 |
| 3 网络 | 准备机跑 DownloadOnly；覆盖 BITS 不可用、直连失败、断网、错误缓存 | 不启用/重启 BITS，不改 TLS；失败不留可选半包；镜像默认关闭 |
| 4 安装器 | 已批准的克隆测试机执行 Install；实时防护开启；观察取消、失败和重启 | 签名策略成立；前一个组件失败不启动后一个；文件锁/临时目录不妨碍安装器；0 退出但无预期版本要失败 |
| 5 系统影响 | 安装前后对比系统目录、IFEO、MSIEXEC、计划任务、Explorer 模块、普通用户权限 | 改动与源码/预期一致，解释清楚任务实际账号、ACL 和参数边界；不凭源码直接宣布存在或不存在提权漏洞 |
| 6 功能 | 仅测试 NAS、测试账号、专用目录；配置 VxKex；测传输、冲突、删除、中文名、大文件、断网重连、重启自启 | 文件内容 SHA256 一致；无意外删除传播；不只看登录页/进程存活；确认客户端自动更新不会悄悄改变版本组合 |
| 7 回退 | 卸载并对照基线，恢复完整快照，再重复一遍 | 任务、IFEO、DLL、shell 扩展、自启均可恢复；不误删原有兼容层配置；有可重复证据 |

## 只读取证

在目标机普通 Windows PowerShell 中逐段运行；不要把主动启动诊断或自启修复当成预检。

```powershell
$PSVersionTable
[Environment]::Version
Get-WmiObject Win32_OperatingSystem | Select-Object Caption,Version,OSArchitecture,ServicePackMajorVersion,ProductType
Get-WmiObject Win32_Service -Filter "Name='BITS'" | Select-Object Name,State,StartMode
Get-HotFix | Select-Object HotFixID,InstalledOn
Get-WmiObject -Namespace root\SecurityCenter2 -Class AntiVirusProduct | Select-Object displayName,productState
Get-AuthenticodeSignature -LiteralPath '.\downloads\Synology Drive Client-4.0.3-17892-x86.exe' | Format-List Status,StatusMessage,SignerCertificate,TimeStamperCertificate
Get-AuthenticodeSignature -LiteralPath '.\downloads\KexSetup_Release_1_2_3_2466.exe' | Format-List Status,StatusMessage,SignerCertificate,TimeStamperCertificate
```

签名检查可能发起 Windows 自身的证书链/吊销查询；完全断网时把无法验证记录为未知/失败，不假装有效。`Get-HotFix` 列表不能证明所有累计更新覆盖的能力。

## 停止条件

- 身份、大小或 hash 不同；来源清单不完整；出现未审新版本、Debug、任意同名 EXE。
- Synology 签名非 Valid 或发布者不匹配；VxKex 出现 NotSigned 之外的签名错误。
- 安全软件拦截尚未解释，或只能通过全局关闭防护、整目录白名单才能继续。
- 任务权限、Explorer 行为或安装改动无法解释；与安全补丁代理等已有软件冲突。
- 程序版本、文件内容或同步行为与预期不一致；实际卸载回退未证明可恢复。

记录失败样本 hash、准确告警、日志、重现步骤。不要把包含业务文件、NAS 密码或令牌的日志公开到 Issue。

## 回退

安装开始前必须有完整快照/镜像。当前工具不会写 TLS/BITS/杀毒设置，但上游兼容层安装器会修改系统；删除工具目录不能撤销这些改动。

优先恢复测试机快照。若做卸载验证，按上游正常卸载流程操作，检查计划任务、IFEO、MSIEXEC、系统目录 DLL、shell 扩展及自启，与基线逐项比较。不要一律删除整个 IFEO 或 VxKex 注册表树，因为其他程序可能在使用。

代码回退与机器回退分开：保留 PR 前提交和测试日志，可撤销本次提交；生产流程不可为恢复便利而重新启用无 hash 缓存、自动 latest、全局停杀软或 TLS1.1。

## 验收记录模板

```text
代码提交：
系统镜像/架构/SP：
PS/CLR 与安全产品版本：
Synology/VxKex 文件名与 SHA256：
准备机及目标机签名结果：
安装前后任务/IFEO/模块差异：
Synology Drive Server 版本与测试账号范围：
同步内容 hash、冲突/删除/断网/重启结果：
安装取消/失败/重启返回值：
卸载和快照恢复结果：
未解决问题与是否允许进入下一阶段：
```
