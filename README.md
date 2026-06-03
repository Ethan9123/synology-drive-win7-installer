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
| VxKex-NEXT | `1.1.4.2085`（运行时自动抓 GitHub 最新） | `github.com/YuZhouRen86/VxKex-NEXT` |

**升级 Synology Drive 版本**：只改 `安装Synology Drive Client.ps1` 顶部的 `$synoVersion` 一个变量即可。最新版本号见 [archive.synology.com 版本列表](https://archive.synology.com/download/Utility/SynologyDriveClient)。

> ⚠️ **版本配对**：原始方案在 4.0.1 / 4.0.2 上实测通过。若最新版（如 4.0.3）配置完 VxKex 仍无法启动，把 `$synoVersion` 回退到 `4.0.2-17889` 再试——这是已知稳妥的版本。VxKex 请始终用最新版（新 API 覆盖更全）。

**下载源说明**：群晖官方下载域名是 `global.synologydownload.com`，路径里 32 位在 `Installer/i686/`、64 位在 `Installer/x86_64/`（文件名后缀分别是 `-x86` / `-x64`）。国内访问 GitHub 不稳定时，脚本会自动尝试 `gh-proxy.com` 镜像；都失败则提示在另一台电脑下载、放进 `downloads/` 后重跑（脚本会自动识别已下载文件并跳过）。

---

## 反误报设计

VxKex-NEXT 本身会被 360 / 部分杀软标记（其工作原理就是 hook 系统 DLL 加载，无法规避）。但本工具脚本本体最大程度避开特征：

- ✅ 纯文本 `.cmd` + `.ps1`，**不编译 exe**，不混淆，不 Base64
- ✅ 不使用 `Invoke-Expression` / `IEX` / `-EncodedCommand`
- ✅ 下载用系统自带 **BITS** 服务（`Start-BitsTransfer`）
- ✅ 所有 URL 走官方源（`global.synologydownload.com`、`github.com`）
- ✅ 不写 `HKLM` 启动项，不静默执行任何操作
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

## 故障排查

详见 [使用说明.txt](使用说明.txt) 的「故障排查」章节。常见问题：

- 双击 cmd 闪退 → 360 拦截 PowerShell，先暂停 360
- "无法加载脚本" → 已有 `-ExecutionPolicy Bypass`，确认是否以管理员运行
- 下载失败 → 国内 GitHub 不稳定，手动放 `downloads/` 后重跑脚本
- 装完仍报缺少 DLL → 检查 VxKex 是否添加了 bin 下**所有** exe
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

---

## 不会做的事

- ❌ 静默安装（所有安装程序都需要用户确认）
- ❌ 修改 `HKLM` 注册表启动项
- ❌ 创建计划任务
- ❌ 上传 / 收集任何数据
- ❌ 自动写入 VxKex 注册表（避免被杀软拦截）

---

## 致谢

- 原始解决方案：[zhugh.com - 解决Windows 7无法使用Synology Drive Client](https://zhugh.com/synology/)
- VxKex-NEXT：<https://github.com/YuZhouRen86/VxKex-NEXT>

---

## License

MIT — 仅打包整理脚本，被分发的 Synology Drive Client / VxKex-NEXT 各自遵循其原始许可证。
