# Synology Drive Client - Win7 一键安装工具包

在官方已停止支持的旧版 Windows（主要是 **Windows 7**）上自动安装并配置**最新版 Synology Drive Client**，通过 [VxKex-NEXT](https://github.com/YuZhouRen86/VxKex-NEXT) 注入 Win10 API 兼容层。

> 适用：Windows 7 (32 / 64 位) · 也支持 Win8/8.1（自动跳过兼容层）
> 目标版本：Synology Drive Client 4.0.x 及更高

---

## 快速使用

1. 下载本仓库（点右上角 `Code` → `Download ZIP` 或 `git clone`）
2. 拷贝到目标 Win7 电脑（任意位置）
3. 临时关闭 360 / Defender，或将文件夹加入白名单
4. **右键 `一键安装.cmd` → 以管理员身份运行**
5. 按提示完成（约 3-5 分钟）
6. 重启电脑验证开机自启

详细步骤见 [使用说明.txt](使用说明.txt)。

---

## 文件说明

| 文件 | 用途 |
|------|------|
| `一键安装.cmd` | 主入口，双击启动完整安装流程 |
| `安装Synology Drive Client.ps1` | 7 步自动化安装脚本（PowerShell） |
| `检查开机自启动.cmd` | 独立的自启状态检查 / 修复工具 |
| `verify-autostart.ps1` | 自启检查脚本（被 .cmd 调用） |
| `诊断启动问题.cmd` | 装完打不开时用——定位启动失败根因 |
| `diagnose-launch.ps1` | 启动诊断脚本（被 .cmd 调用） |
| `使用说明.txt` | 完整文档 + FAQ + 故障排查 |
| `downloads/` | 安装包缓存（运行后生成，可批量部署复用） |

---

## 原理

### 为什么 Win7 装不上？

Synology Drive Client 从 **3.3.0-15082** 起依赖 UCRT (Universal C Runtime) 中的 `api-ms-win-crt-*.dll` 系列 API。运行时报错：

```
缺少 api-ms-win-crt-runtime-l1-1-0.dll
```

微软官方要求升级到 Win10 才能正常使用 UCRT，光装 VC++ Redistributable 补不齐。

- 微软说明：<https://learn.microsoft.com/zh-cn/answers/questions/3770956/>
- 群晖更新日志：<https://www.synology.cn/zh-cn/releaseNote/SynologyDriveClient>

### 解决方案

[VxKex-NEXT](https://github.com/YuZhouRen86/VxKex-NEXT) 是一个 Windows 7 的 API 扩展层，提供了缺失 Win10 API 的 Win7 实现。通过 IFEO（映像文件执行选项）钩子注入，所有调用方（Run 注册表项、任务计划、手动启动）都会经过兼容层。

### 工具做了什么

主脚本 7 步流程：

1. **环境检查** — 管理员权限、PowerShell 版本、OS 识别
2. **下载 Synology Drive Client (x86)** — BITS 走官方 HTTPS
3. **下载 VxKex-NEXT** — GitHub Releases API 抓最新版
4. **安装 VxKex-NEXT** — 启动官方安装程序
5. **安装 Synology Drive** — 启动官方安装程序
6. **配置 VxKex 兼容层** — 自动定位 `SynologyDrive.app\bin`，路径复制到剪贴板，弹出 GUI 供手动添加
7. **验证 / 启用开机自启动** — 检查 `HKCU\Run` + 启动文件夹，未配置可一键修复

### 版本信息与升级

脚本默认安装以下经验证的版本（截至 2026-06）：

| 组件 | 版本 | 下载源 |
|------|------|--------|
| Synology Drive Client | `4.0.3-17892` (x86) | `global.synologydownload.com` |
| VxKex-NEXT | `1.2.0.2226`（运行时自动抓 GitHub 最新） | `github.com/YuZhouRen86/VxKex-NEXT` |

**升级 Synology Drive 版本**：只改 `安装Synology Drive Client.ps1` 顶部的 `$synoVersion` 一个变量即可。最新版本号见 [archive.synology.com 版本列表](https://archive.synology.com/download/Utility/SynologyDriveClient)。

> ⚠️ **版本配对**：原始方案在 4.0.1 / 4.0.2 上实测通过。若最新版（如 4.0.3）配置完 VxKex 仍无法启动，把 `$synoVersion` 回退到 `4.0.2-17889` 再试——这是已知稳妥的版本。VxKex 请始终用最新版（新 API 覆盖更全）。

**下载源说明**：群晖官方下载域名是 `global.synologydownload.com`，路径里 32 位在 `Installer/i686/`、64 位在 `Installer/x86_64/`（文件名后缀分别是 `-x86` / `-x64`）。国内访问 GitHub 不稳定时，脚本会自动尝试 `gh-proxy.com` 镜像；都失败则提示在另一台电脑下载、放进 `downloads/` 后重跑（脚本会自动识别已下载文件并跳过）。

---

## 反误报设计

> ⚠️ **实测确认**：`KexSetup_Release`（VxKex 安装包）在下载时就会被 **Windows Defender 直接判为病毒/PUA 并隔离**（`contains a virus or potentially unwanted software`）——这不是本工具能规避的，因为 VxKex 的工作原理就是 hook 系统 DLL 加载，天然命中启发式。360 同理。**部署前请先给 VxKex 安装包 / 本文件夹加白名单，或临时关闭实时防护。**

本工具**脚本本体**最大程度避开特征（VxKex 二进制无法规避，但脚本可以）：

- ✅ 纯文本 `.cmd` + `.ps1`，**不编译 exe**，不混淆，不 Base64
- ✅ 不使用 `Invoke-Expression` / `IEX` / `-EncodedCommand`
- ✅ 下载用系统自带 **BITS** 服务（`Start-BitsTransfer`）
- ✅ 所有 URL 走官方源（`global.synologydownload.com`、`github.com`）
- ✅ 不写 `HKLM\Run` 启动项、不静默执行（`HKLM` 仅写 TLS1.2 设置以便下载）
- ✅ 自启动只写当前用户 `HKCU\Run` 或启动文件夹，不是隐蔽位置
- ✅ VxKex 注册表配置保留手动 GUI 环节（自动写 IFEO 必触发杀软）

源码完全可在记事本中打开审阅。

---

## 开机自启动机制

### 双保险

| 机制 | 来源 | 描述 |
|------|------|------|
| 首选 | Synology 官方 | 安装时自动写 `HKCU\...\Run\SynologyDrive` |
| 备份 | 本工具 | 在 `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup` 创建 `.lnk` |

### 为什么自启场景兼容

VxKex-NEXT 通过 IFEO（Image File Execution Options）钩子工作——只要 `SynologyDrive.exe` 被 Windows 拉起，**无论从哪里拉起**，都会先过 VxKex 注入兼容层。所以不需要为开机自启单独做配置。

### 失效处理

随时双击 `检查开机自启动.cmd`（无需管理员），3 秒诊断 + 一键修复。

常见失效场景：
- 安装时取消了"随 Windows 启动"勾选
- 升级 / 重装时 Run 项被清除
- 360 优化大师把启动项禁用了
- 用户路径变更（USERPROFILE 迁移）

---

## 批量部署

第一台电脑运行后，`downloads/` 文件夹中会缓存所有安装包。将**整个文件夹（含 downloads）** 复制到其他电脑即可**离线安装**，无需重新下载。

---

## 装完打不开？用诊断工具

双击 **`诊断启动问题.cmd`**（无需管理员），它会自动定位根因：

1. 确认 `SynologyDrive.exe` 与 VxKex 是否都装好
2. **逐个检查 bin 下每个 exe 是否被 VxKex 接管**（读 IFEO 注册表的 `VerifierDlls` + `GlobalFlag` 0x100 位）——漏加任何一个 exe 都可能导致主程序连锁起不来，这是最常见的失败原因
3. 实际启动一次，失败则扫描应用程序事件日志，打印出 faulting module / 缺失的 DLL
4. 按优先级给出针对性修复建议

> VxKex NEXT 的工作方式：通过 IFEO 把自己的兼容层 DLL（`VerifierDlls`）注入到目标 exe。所以"某个 exe 没被接管"＝"它会因缺少 `api-ms-win-crt-*.dll` 而启动失败"。诊断工具正是逐个核对这一点。

## 故障排查

详见 [使用说明.txt](使用说明.txt) 的「故障排查」章节。常见问题：

- 双击 cmd 闪退 → 360 拦截 PowerShell，先暂停 360
- "无法加载脚本" → 已有 `-ExecutionPolicy Bypass`，确认是否以管理员运行
- 下载失败 → 国内 GitHub 不稳定，手动放 `downloads/` 后重跑脚本
- 装完仍报缺少 DLL / 打不开 → 跑 `诊断启动问题.cmd`，多半是漏加了某些 exe
- 360 报木马 → 误报，源码可见。把文件夹加白名单

---

## 兼容性

| 系统 | 支持情况 |
|------|----------|
| Windows 7 SP1 (x86/x64) | ✅ 主要目标 |
| Windows 8 / 8.1 | ✅ 自动跳过 VxKex |
| Windows 10 / 11 | ⚠️ 通常不需要本工具 |
| Windows XP / Vista | ❌ VxKex 不支持 |

PowerShell 要求：建议 **5.1**（WMF 5.1）。Win7 默认是 2.0，需先装：<https://www.microsoft.com/en-us/download/details.aspx?id=54616>
（本工具的脚本已做 PS 2.0 兼容处理，`检查开机自启动.cmd` / `诊断启动问题.cmd` 在 2.0 上也能跑；但主安装脚本抓 GitHub 需要现代 TLS，PS 5.1 体验更顺。）

### Win7 前置补丁（干净系统必装，否则签名/兼容层报错）

按顺序安装，**顺序不能反**：

1. **Service Pack 1 (SP1)** — 基础前提
2. **KB4490628**（服务栈更新 SSU）→ 重启
3. **KB4474419**（SHA-2 代码签名支持）→ 重启 — 没有它，新版安装包的数字签名无法验证
4. **KB2533623 + KB2670838** — VxKex-NEXT 及多数现代程序依赖

补丁都在 [微软更新目录](https://www.catalog.update.microsoft.com/) 按 KB 号搜索下载。

### 连不上 NAS？（服务端要求）

装好客户端只是第一步，还要 NAS 端满足：

- NAS 已安装 **Synology Drive Server** 套件，且 **DSM 7.0 或以上**
- 2025 年起的 DSM 7.3+ 兼容策略要求客户端 **≥ 4.0.0** 才能连接——所以本工具默认装 4.0.x 是对的，回退版本 `4.0.2-17889` 也满足此下限

> 官方规格表把 Windows 最低要求写成 **Windows 10 2004+**，并未列出 Win7——这正是本项目存在的原因（靠 VxKex 绕过官方限制）。

---

## 不会做的事

- ❌ 静默安装（所有安装程序都需要用户确认）
- ❌ 写 `HKLM\Run` 启动项（自启动用 `HKCU\Run` 或启动文件夹）
- ❌ 创建计划任务
- ❌ 上传 / 收集任何数据
- ❌ 删除或替换任何系统文件
- ❌ 自动写入 VxKex 注册表（避免被杀软拦截）

> 透明起见，本工具**确会**做的系统改动：按需配置开机自启动、写入 `HKLM` 的 TLS1.2 设置（为能从 GitHub/群晖下载）、必要时启用系统自带的 BITS 服务。均为正常运行所需且公开可见。

---

## 致谢

- 原始解决方案：[zhugh.com - 解决Windows 7无法使用Synology Drive Client](https://zhugh.com/synology/)
- VxKex-NEXT：<https://github.com/YuZhouRen86/VxKex-NEXT>

---

## License

MIT — 仅打包整理脚本，被分发的 Synology Drive Client / VxKex-NEXT 各自遵循其原始许可证。
