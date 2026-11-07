# tools

面向**用户自己设备**的两个 PowerShell 脚本，配合 [01](../docs/01-reverse-1.2.md) §11 的处置方案使用。只操作通过 ADB 连接的本地设备、或在 Windows hosts 里加一条黑洞记录，不向任何服务器发送内容。

| 脚本 | 作用 |
|---|---|
| [`kill_systemhelper.ps1`](kill_systemhelper.ps1) | 分层处置：定位安装位置（data / system / product）→ 停用或移除当前用户副本 → 逐项撤销运行时权限与 AppOps → 清理本地采集数据 → 处置后验证；可选在 Windows hosts 中黑洞化上报域名（需管理员） |
| [`dump_evidence.ps1`](dump_evidence.ps1) | 取证：用 `run-as` / `su` 把 `databases/systemhelper` 与 `shared_prefs` 拉到本机 `.\evidence`，把每一条上报 JSON 解码成可读文本，输出 `summary.txt`（上报次数、时间跨度、出现过的 IMEI/IMSI/号码/基站/应用数） |

## 用法

```powershell
# 先确认设备已连接
adb devices

# 1) 取证：看看它到底收走了什么（不改动设备）
.\dump_evidence.ps1

# 2) 处置：默认只 disable-user，可逆
.\kill_systemhelper.ps1

# 3) 彻底移除当前用户副本（可恢复出厂后回归，见 01 §11）
.\kill_systemhelper.ps1 -Remove -PurgeData

# 4) 顺带在 Windows hosts 里黑洞化上报域名（需管理员）
.\kill_systemhelper.ps1 -BlockHosts
```

## 注意

- 默认动作是 `pm disable-user`，**可逆**；`-Remove` 才会 `pm uninstall --user 0`，而系统分区里的原件仍在。
- `-PurgeData` 需要 root 或应用可 `run-as`。
- 3.0.1 起数据库表名从 `history` 改为 `dmregister`，`dump_evidence.ps1` 里的 SQL 需按版本调整（见 [03](../docs/03-compare-3.0.1.md) §12）。
- 脚本按"现状"提供，执行前请自行阅读一遍；参数含义见每个文件头部的注释块。
