# SystemHelper · 日文原帖（@tanaka_yuto）逐条核验

> **核验对象**：X 用户 `@tanaka_yuto` 于 2026-11-02 01:29 发布的日文帖
> <https://x.com/tanaka_yuto/status/2117066492672110700>（约 8,500 浏览）
> 标题句：「プリインストールアプリに潜む、『監視SDK』」（预装应用里潜藏的"监控 SDK"）
> **本地样本**：`1.2-20220907` / `3.0.1-20260313` / `4.0.0-20260910`（同一包名 `com.mobiletools.systemhelper`）
> **第二来源**：通信人家园（C114）帖《SystemHelper组件争议背后：手机反诈不该成为隐私收集的"灰色后门"》
> <https://www.txrjy.com/thread-1442229-1-1.html>（2026-11 上旬；**游客不可读**，正文需登录，本报告据标题与同期转载/整理稿间接核验，见 §8）
> **方法**：androguard 4.1.4 复核三份 APK 元数据 + jadx 反编译源码逐行比对 + dex 字符串计数
> **日期**：2026-11-07 ｜ **结论级别**：高置信（每条给出可复现的文件与行号）
>
> **关于文中出现的地址**：报告内的 IP 已替换为文档保留地址（`203.0.113.0/24`、`198.51.100.0/24`）；本地路径、主机名与设备标识已移除。域名保留，因为它们是被分析对象本身。

> **本文的范围与更正机制**：只核验公开帖文与公开文章中的**事实断言**，不评价作者本人。文中"成立 / 不成立 / 证据不支持"均指断言与代码的对应关系。若原作者或任何一方认为引述有误，欢迎提交 Issue 并附上证据，核实后即更正。

---

## 0. 一句话结论

**帖子部分成立，但它把三代产品、三个不同 APK 混成了一条叙事。**

- **对得上（4 条）**：联通自动注册的身份与收方、`device_provisioned` 假同意门、权限模型结论、**13 个品牌 Reader（对 4.0 完全吻合，且确实没有华为）**。
- **只对 3.0.1/4.0 成立、对 1.2 不成立（3 条）**：MCC 460 门、字段集（TAC/CID/PCI/BSSID）、24 小时重发。
- **对不上（1 条）**：三星 modem 固件版本（三版全零命中）。
- **不在本包内（1 条）**：AiGuard / GuardProvider —— 那是 `com.miui.guardprovider` 与 `com.miui.securitycenter`。
- **第二来源（通信人家园帖）**：正文需登录，据同期整理稿核验，"插移动卡照样上报""24 小时应用清单""跳过 com.android""无华为"四条**均被代码证实**（见 §8）。
- **第三来源（中文评论文章）**：方向对、**主体错**。"上传反诈服务器及第三方风控平台"**内容是真的**，但主体是 `com.miui.securitycenter`（`eps.caict.ac.cn`、`gateway-papa.cloud.weizhi.com`，厂商文档有披露），**不是 SystemHelper**；"后台运行数据"应改为"前台时长"；"照明弹豁免"无法用 APK 证实，但有可验证替代（见 §9）。

作者自己在帖末写了「私も間違ってるかもしれない」（我也可能搞错），所以下面按"可复现证据"逐条给结论，而不是按立场。

---

## 1. 原帖七条主张（日文原文摘要 + 中译）

| # | 日文原文（摘要） | 中译 |
|---|---|---|
| ① | 「正体は中国聯通(China Unicom)の自動登録クライアント…送信先がそのまま残っています: dm.wo.com.cn:18080/register ← TLSなしのHTTP平文。送るのは IMEI・IMSI・ICCID・基地局識別子(TAC/CID/PCI)・WiFiスキャン(BSSID)…失敗時はSQLiteに保存して24時間のジッターで再送します」 | 真实身份是联通自动注册客户端，收方明文写在代码里：`dm.wo.com.cn:18080/register`，无 TLS 的 HTTP 明文。发送 IMEI、IMSI、ICCID、基站标识（TAC/CID/PCI）、WiFi 扫描（BSSID）。失败时存 SQLite，以 24 小时抖动重发 |
| ② | 「『ユーザー許可』ゲートの正体は device_provisioned フラグ = 初期セットアップ完了の印であって、プライバシー同意ではありません。同意ダイアログは存在しない。起動条件は中国SIM（MCC 460）の挿入。日本SIMでは送信しません」 | "用户许可"门的真身是 `device_provisioned`（初始设置完成标志），不是隐私同意；不存在同意弹窗；激活条件是中国 SIM（MCC 460），日本 SIM 不发送 |
| ③ | 「Xiaomi専用ではない。コード内にブランド別Readerが13個: Xiaomi / SamSung / OPPO / VIVO / OnePlus / Realme / Nubia / ZTE / TDTECH / WIKO / PTAC / 聯通…（Samsung機からはmodemファームのバージョンまで集める）」 | 非小米专属。代码内有 13 个品牌 Reader（列举 12 个），联通销售渠道机不分品牌（三星机连 modem 固件版本都采） |
| ④ | 「別コンポーネント guardprovider の AiGuard…foregroundServiceType=0xA0 は『マイク｜画面投影』のビットマスク。AudioRecord.setAudioSource(4) = VOICE_CALL、MediaProjection.Callback = 画面capture、AI Vision SDK → detection-aigc.engine.miui.com（ディープフェイク検出）」 | 另一组件 guardprovider 的 AiGuard 更深：`0xA0` = 麦克风｜投屏 的位掩码；`setAudioSource(4)=VOICE_CALL`；MediaProjection 截屏；AI Vision SDK 送 `detection-aigc.engine.miui.com`（深度伪造检测） |
| ⑤ | 「このguardprovider 3.0.8…『System security components』としてGoogle Playで全世界配信…JPリージョンでは通常dormant…有効化はリモートのサーバ設定次第」 | GuardProvider 3.0.8 以"System security components"名义在 Google Play 全球分发；日本设备会被更新；JP 区域通常休眠（需麦克风/画面授权 + 区域判定 + 服务端配置），代码与特权权限都在设备上，激活取决于远端配置 |
| ⑥ | 「PixelやGalaxyに同じAPKを入れれば監視されるか？→ されません。CAPTURE_VOICE_COMMUNICATION_OUTPUT等もREAD_PRIVILEGED_PHONE_STATEも、全部 signature｜privileged…sideloadではIMEIすら読めません」 | 装到 Pixel/Galaxy 上会被监控吗？不会。capture 系与 `READ_PRIVILEGED_PHONE_STATE` 都需 signature｜privileged；侧载连 IMEI 都读不到。权限模型在此正常运作，问题本质是 OEM 预装 |
| ⑦ | 「反電信ネットワーク詐欺法（2022年施行）…全中国OEM・キャリアに共通する構造…PLOS One 2023…Nokia(HMD)ですら製造ライン起因で位置・SIM・serialを中国サーバへ平文送信…日本ではXiaomiがSIMフリー開放市場2位」 | 背景是 2022 年施行的《反电信网络诈骗法》：运营商实名制、互联网企业配合公安的技术义务，是全中国 OEM 与运营商的共同结构；PLOS One 2023 实测三星/小米/华为/Realme 均采集应用清单与持久硬件 ID，退出后仍继续；2019 年诺基亚 HMD 因产线问题把位置/SIM/serial 明文发往中国服务器；日本市场上小米是 SIM-free 开放市场第二 |

---

## 2. 逐条核验

| # | 断言 | 本地证据 | 判定 |
|---|---|---|---|
| ① | 联通自动注册客户端，`dm.wo.com.cn:18080/register`，明文 HTTP | 1.2/3.0.1：`http://dm.wo.com.cn:18080/register`；4.0：`https://dm.wo.com.cn:18081/register` + 证书失败降级回 `:18080` | ✅ 对 1.2/3.0.1；⚠️ 对 4.0 已过时 |
| ① | IMEI/IMSI/ICCID/TAC/CID/PCI/BSSID | 3.0.1/4.0 逐字段一致；1.2 为 LAC/CellID、**无 BSSID**，但**多一个 MSISDN** | ✅ 对 3.0.1+；⚠️ 1.2 字段集不同 |
| ① | 失败落 SQLite，24 小时抖动重发 | 1.2：`systemhelper/history` 上限 100，成功即 `clearHistory()`；3.0.1/4.0：`systemhelper/dmregister` 上限 10，成功后起 `HistoryPostThread` **取最新一条、先删后发** | ✅ 落库与重发属实；「ジッター」只对 3.0.1+ 成立（见 §4） |
| ② | 门 = `device_provisioned`，无同意弹窗 | 30 个厂商适配器的 `checkUserPermission()` 一律 `Settings.Global.getInt(cr,"device_provisioned",0)==1`，日志写 `isBootWizardCompleted` | ✅ 完全一致 |
| ② | MCC 460 才发，日本 SIM 不发 | 3.0.1/4.0：`isChinaNetwork()` 要求 MNC `startsWith("460")`，否则 `"mnc is not in china!"` return false；发送路径先过这道门 | ✅ 对 3.0.1/4.0；**❌ 对 1.2**（见 §3.1） |
| ③ | 13 个品牌 Reader（列举 12 个），含 WIKO，无华为 | **4.0 恰好 13 个品牌**（含 `MOTO`、`WIKO`，**无 `HUAWEI`**）；3.0.1 为 12 个（无 MOTO）；1.2 为 58 个（**含 `HUAWEI`**、无 WIKO） | ✅ 对 4.0（数量与名单均吻合）；版本错位才导致表面"不符"；`modem` 仍零命中 |
| ④ | AiGuard：`0xA0`、`VOICE_CALL`、MediaProjection、`detection-aigc` | 三份样本 dex：`VOICE_CALL` 0、`AudioRecord` 0、`detection-aigc` 0、`guardprovider` 0、`aiguard` 0；`MediaProjection` 仅来自 support 库 | ❓ 本包内不存在，属另一 APK |
| ⑤ | GuardProvider 3.0.8 在 Google Play 全球分发 | 工作区无该样本 | ❓ 无法验证 |
| ⑥ | 侧载无效；capture 权限需 signature｜privileged | 与本包定性一致：`sharedUserId` + `READ_PRIVILEGED_PHONE_STATE` + `priv-app` 才能读 IMEI | ✅ 一致 |
| ⑦ | 2022 年反诈法 / PLOS One 2023 / Nokia 2019 / 日本市场位次 | APK 内不可验证 | ⚠️ 背景论据，非样本结论 |

---

## 3. 必须纠正的三处

### 3.1 「日本SIMでは送信しません」只对 3.0.1 之后成立

1.2 的发送判定（`RegisterThread.java:90-110`）：

```java
if (checkIMEI(IMEI1) && checkIMEI(IMEI2)) {
    if (!isNetworkConnected)                { insertRecord(...); }        // 断网 → 入库
    else if (isWifiConnected)               { return doEncrpytPost(...); } // ★ 有 WiFi 就发，不校验 SIM
    else if (!isRoaming && isUnicomNetwork) { return doEncrpytPost(...); } // 蜂窝：仅联通 MNC
    else                                    { insertRecord(...); }
}
```

**WiFi 分支没有任何 MCC/MNC 判断。** 插日本 SIM、连 WiFi、IMEI 合法、`device_provisioned=1` → 照发。

MCC 460 门是 3.0.1 引入的（3.0.1 `e1/g.java:60-96`，4.0 `e1/g.java:50-84`）：

```java
if (!g1.d.f2652e)              { log("isUserPermissionOpen is false!"); return false; }
if (!l.s(bVar).booleanValue()) { log("mnc is not in china!"); return false; }        // ★ MCC 460 门
if ((l.w(ctx) && l.s(bVar)) || (!o.h(ctx) && l.u(bVar))) { ... }                    // WiFi 也要求中国网络
```

而且这道门在异常路径上 **fail-open**：`isChinaNetwork()` 的 catch 块直接 `return TRUE`（`g1/l.java:206-215`），即读卡信息抛异常时按"在中国"放行。

> 另：3.0.1/4.0 的联通 MNC 白名单从 3 个扩到 4 个 —— `46001 / 46006 / 46009 / 46010`（`g1/l.java:230,239`）。

### 3.2 「ユーザー許可」关掉≠不采：1.2 关门仍入库，默认值还是「同意」

`RegisterThread.java:112-122`：

```java
if (GlobalSetting.isUserPermissionOpen) { handleRegisterResult(register(this.mDeviceInfo)); return; }
databaseHelper.insertRecord(this.mDeviceInfo.getJsonString());   // ★ 门关着仍然落库
MyLog.d(TAG, "User Permission Closed!");
```

`GlobalSetting.java:39`：

```java
public static boolean isUserPermissionOpen = true;   // ★ 默认同意
```

厂商适配器未匹配时，这个默认值不会被任何 `checkUserPermission()` 覆盖 → 直接按"已同意"运行。

3.0.1 反而更"干净"：门关着直接 `return false`，连库都不写（`e1/g.java:59-63`）。

### 3.3 品牌 Reader 是 58 / 12 / 13 个 —— 版本不同，名单不同（**本条此前判错，已更正**）

原判"58 个 vs 13 个不符"是拿 **1.2** 去对 **4.0 时代**的名单。实测三版差异极大：

| | 1.2 | 3.0.1 | 4.0 |
|---|---|---|---|
| `DeviceInfoReader*` 类数 | **58** | **12** | **13** |
| 含 `HUAWEI` | ✅ | ❌ | ❌ |
| 含 `WIKO` | ❌ | ✅ | ✅ |
| 含 `MOTO` | ✅ | ❌ | ✅ |
| 其余 | MEIZU、Lenovo、Coolpad、TCL、Gree、HISENSE、KONKA、ChangHong、LETV、PHILIPS、QIKU、Spreadtrum… | Liantong、Nubia、OPPO、OnePlus、PTAC、Realme、SamSung、TDTECH、VIVO、Xiaomi、ZTE | Liantong、MOTO、Nubia、OPPO、OnePlus、PTAC、Realme、SamSung、TDTECH、VIVO、WIKO、Xiaomi、ZTE |

**4.0 的 13 个品牌，与帖子截图那份名单逐一对得上**（Liantong、MOTO、Nubia、OPPO、OnePlus、PTAC、Realme、SamSung、TDTECH、WIKO、VIVO、Xiaomi、ZTE），且同样**没有华为/荣耀**。作者手里是 4.0 一代的包，不是 1.2。

所以"没有华为"这个观察是**对的，但只对 3.0.1/4.0**；1.2 里 `DeviceInfoReaderHUAWEI.java` 明确存在，`HUAWEI` 字符串命中 5 次。割接点就在 3.0.1：58 个厂商适配器被砍到 12 个，同时加进 WIKO。

> 仍然站不住的只有一条：**「Samsung機からはmodemファームのバージョンまで集める」**。三份样本 dex 里 `modem` / `Modem` / `baseband` / `Baseband` / `gsm.version.baseband` **全部零命中**，三星适配类只处理 VoLTE/VoNR 通话类型、内存、5G 概念机判定。

---

## 4. 「24時間のジッターで再送」的准确机制

帖子这句话把两件事合成了一件，拆开看：

| 机制 | 1.2 | 3.0.1 / 4.0 |
|---|---|---|
| 失败落库 | `history` 表，上限 100 | `dmregister` 表，上限 10（超出按 `ID ASC` 删最旧） |
| 重发时机 | 下一次上报时把**整批** History 附在同一条 JSON 里发；成功即 `clearHistory()` | 成功后启动 `HistoryPostThread`，每次只取**最新一条**，**先删后发** |
| 抖动 | **无** | 首次触发 `new Random().nextInt(86400000)`（0–24h），三条闹钟各自随机 |
| 断网期间 | 只入库，不重试 | 只入库，不重试（无独立重试定时器） |

所以：**「24 小时抖动重发」是 3.0.1+ 的行为（抖动用于首次触发离散化，重发靠下一次成功上报顺带），1.2 既没有抖动，也是一次性整批补发。**

---

## 5. AiGuard / GuardProvider：不属于本包

### 5.1 本地样本边界

三份 APK 的 dex 字符串计数：

```
VOICE_CALL 0 · AudioRecord 0 · MediaProjection 0（除 support 库）· detection-aigc 0
guardprovider 0 · aiguard 0 · foregroundServiceType 0 · 0xA0 0
```

**本包既无录音、也无投屏、也无 AIGC 端点。** 帖子 ④ 描述的是 `com.miui.guardprovider`（内含 `aiguard.AiGuardService`，独立进程 `:ai`）与 `com.miui.securitycenter`（`com.miui.electricrisk` 模块），是另外的 APK。

### 5.2 帖子的技术细节本身成立的部分

位掩码解释正确：

```
0x80 = FOREGROUND_SERVICE_TYPE_MICROPHONE
0x20 = FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
0xA0 = 0x80 | 0x20
```

`AudioRecord` 的 `source=4` 确实等于 `MediaRecorder.AudioSource.VOICE_CALL`。

### 5.3 外部独立核验（未经本地样本验证，仅作交叉参考）

同话题的公开技术核验（[gist: 关于"小米反诈监控"传闻的技术核验](https://gist.github.com/std-microblock/c38cacab22bf0fffb94b247e09a4d948)，2026-11-06 更新）与帖子有出入：

| 项 | 该核验的结论 | 与本包证据的关系 |
|---|---|---|
| `dm.wo.com.cn:18080` | 属实，「仅存在于预置 `com.mobiletools.systemhelper` 的机型」 | **与本地完全一致** |
| `detection-aigc.engine.miui.com` | 真实存在：`/pcc/attestation/token`、`/aiVideo/pcc/detection`、`/ai/audio/text/pcc/detection`，机密计算 + AES/GCM | 支持帖子 ④ 的方向，但属 GuardProvider |
| `fraud-detection.engine.miui.com` | **不是**反诈上报，是 NFC 门禁配置下发 `/nfc/antifraud/config`，上行仅机型代号与版本号 | 与"反诈特征上报"的想象不符 |
| 录屏实现 | GuardProvider 2.x：反射 `IMediaProjectionManager.createProjection` 绕过系统同意弹窗 | 与帖子 ④ 吻合 |
| 激活条件 | 机型云控 + 能力 + 开关四道约束；`marble`（Note 12 Turbo）默认关 | 支持⑤「dormant / 遠端設定次第」，但不支持"日本设备会被采"的暗示 |
| 「全機が録画」 | 不成立 | — |

> 该 gist 属外部资料，本工作区无法用样本复现，仅作参考，不构成本报告依据。

---

## 6. 关于 ⑦ 的日本语境

帖子最后那段把问题落到「調達・入国・重要施設持ち込みポリシー」（采购、入境、重要设施带机政策），这个落点本身与技术结论无关，但需要划清边界：

- **可验证**：本包确实是预装级（`sharedUserId`、`READ_PRIVILEGED_PHONE_STATE`、无法卸载）；侧载无效（权限模型正确）；数据发往联通域名。
- **不可验证**：日本市场位次、PLOS One 2023 的具体方法、Nokia HMD 2019 的细节——均为外部资料，需各自溯源。
- **不能推出**：从"代码与权限在设备上"推不出"已经在采集"。3.0.1+ 的实际触发还受 `device_provisioned`、MCC 460、网络类型三重约束。

---

## 7. 复核命令

```bash
# 1) 版本：1.2 无 MCC 门，3.0.1/4.0 才有
adb shell dumpsys package com.mobiletools.systemhelper | grep -E "versionName|versionCode"

# 2) 同意门：1 = 开机向导已完成，与隐私同意无关
adb shell settings get global device_provisioned
adb shell settings get secure operator_service_improve_plan

# 3) 本地队列（需 root）：1.2 表名 history，3.0.1+ 为 dmregister
adb shell su -c 'ls -l /data/data/com.mobiletools.systemhelper/databases/'
adb shell su -c 'sqlite3 /data/data/com.mobiletools.systemhelper/databases/systemhelper \
  "select ID,length(jsonString) from dmregister order by ID;"'

# 4) 观察上行：1.2/3.0.1 应能看到明文 JSON；4.0 应为 :18081 TLS，
#    若出现 :18080 明文，说明已触发证书失败降级
```

---

## 8. 第二来源：通信人家园（C114）帖与中文舆论链

### 8.1 可访问性说明

`https://www.txrjy.com/thread-1442229-1-1.html` 的正文对游客**全量拦截**（Discuz 返回"抱歉，您所在的用户组(游客)无法进行此操作"），电脑版、手机版、archiver 版均同。能确认的只有帖子元信息：

- 标题：**《SystemHelper组件争议背后：手机反诈不该成为隐私收集的"灰色后门"》**
- 发布时间：2026-11 上旬（首页"最新主题"第 2 条，紧邻 1442228/1442230）
- 板块：通信人家园论坛首页推送位

因此下面不引用该帖正文，而是核验同期中文转载/整理稿里**可被代码验证的断言**（整理稿：[不翻车《联通 SystemHelper 不只在小米：OPPO、vivo、国行三星都有，换卡照样上报》](https://bufanche.com/guides/unicom-systemhelper/)，2026-11-03）。

### 8.2 中文整理稿的断言 vs 代码

| 断言 | 代码验证 | 判定 |
|---|---|---|
| 「插的是中国移动的卡（46000），它照样往联通服务器注册」「激活条件不限联通卡」 | 3.0.1/4.0 的 `isChinaNetwork()` 只要求 MNC `startsWith("460")`，`46000/46002/46007`（移动）同样通过；WiFi 分支亦只要求中国网络。1.2 的 WiFi 分支**完全不校验 SIM** | ✅ 成立（并且比日文帖的"联通卡"表述更准确） |
| 「统计过去 24 小时用过哪些 App、装了哪些 App、使用时长和流量」 | 3.0.1/4.0：`g1/d.java` 的 appInfo 间隔常量 `86400000`（24h）；`UsageStatsManager.queryAndAggregateUsageStats()` 取前台时长，再按 UID 调 `TrafficStats` 拿分应用流量 | ✅ 对 3.0.1/4.0；⚠️ 1.2 默认是 **7 天**（`GlobalSetting.DEFAULT_APP_INFO_INTERVAL = 604800000`） |
| 「系统自带的（包名以 `com.android` 开头）跳过」 | 3.0.1/4.0：`f1/o.java:43` `if (!bVar2.a().getString("pkgName").startsWith("com.android"))` | ✅ 对 3.0.1/4.0；**1.2 无此过滤**（全源码无该判断） |
| 「代码里品牌名单 …WIKO…找不到华为和荣耀」 | 4.0 = 13 个品牌，含 MOTO/WIKO，无 HUAWEI/HONOR；3.0.1 = 12 个（无 MOTO）；1.2 = 58 个，**含 HUAWEI** | ✅ 对 4.0；❌ 对 1.2 |
| 「国行 vivo X200S 显示版本 `3.0.1-20251230`」 | 我们手里的 3.0.1 是 `3.0.1-20260313`，versionCode 同为 34 | ✅ 说明同 versionName 存在**按 OEM/批次重打的多个构建**；按版本号判行为会出错 |
| 「没 root 卸不掉；`pm uninstall -k --user 0` 只删当前用户」 | 与 §7 处置结论一致；包名三版相同 | ✅ 成立 |
| 「每次录约 3 秒屏，720×1280、24fps，加密上传小米云端」 | 属 `com.miui.guardprovider`；本包 dex 零命中 | ❓ 不属本包（见 §5） |
| 「系统安全组件报给 `fraud-detection.engine.miui.com`、`flash.sec.miui.com`」 | 本包无这两域名；外部核验（gist）称 `fraud-detection.engine.miui.com` 实为 **NFC 门禁配置下发**接口 | ⚠️ 与外部核验冲突，需以 guardprovider/securitycenter 样本另证 |
| 「检查的是有没有完成首次设置，没有另外检查隐私同意」 | 与 §3.2 完全一致：`device_provisioned` + 无弹窗 | ✅ 成立 |

### 8.3 该帖标题本身的判断，代码支持到哪一步

标题把问题定性为「手机反诈不该成为隐私收集的'灰色后门'」。就本包能证明的部分：

- **支持**：无界面、无同意弹窗、无关闭开关、不可卸载；采集范围（应用清单+时长+流量、位置、基站、WiFi、蓝牙配对）显著超出"终端注册"必要；`device_provisioned` 被当作"已同意"。
- **不支持**：本包**没有**任何反诈功能（字符串/端点/能力三层零命中），所以"以反诈为名"在本包层面**不成立**——反诈是这套生态里另一个组件（securitycenter/guardprovider）的叙事，不能挂到 SystemHelper 头上。
- **无法判断**：数据到 `dm.wo.com.cn` 之后是否被并入风控/反诈画像，APK 内看不到。

---

## 9. 第三来源：中文评论文章（通信人家园帖正文）

### 9.1 文本性质

这是那篇《SystemHelper组件争议背后：手机反诈不该成为隐私收集的"灰色后门"》的正文，属**评论/倡议**文体：事实断言与政策主张混写。下面只核验其中**能被代码判定**的事实句，主张部分单独评。

### 9.2 事实断言逐条核验

| # | 文章断言 | 代码证据 | 判定 |
|---|---|---|---|
| 1 | 包名 `com.mobiletools.systemhelper`，非小米独有，广泛预装于国内多品牌 | 包名三版一致；预装级证据齐全（`sharedUserId`、`READ_PRIVILEGED_PHONE_STATE`、3.0.1 用小米平台密钥、`TestActivity` 为调试页）。厂商适配器 1.2 有 58 家、3.0.1 有 12 家、4.0 有 13 家；外部实测 vivo X200S 显示 `3.0.1-20251230` | ✅ 成立（"广泛"的具体覆盖面 APK 无法界定） |
| 2 | 静默收集硬件信息、应用安装列表、24 小时使用时长、**后台运行数据** | 硬件/双卡标识、应用清单（3.0.1 起过滤 `com.android`）、前台时长均有；但取的是 `getTotalTimeInForeground()`，**三版 dex 中 `getTotalTimeInBackground` 零命中** | ⚠️ 三条对，**"后台运行数据"不准确**——只统计前台时长 |
| 3 | **上传至反诈服务器及第三方风控平台** | 本包：端点只有 `dm.wo.com.cn:18080/18081`（+百度地图 21 个），`反诈/96110/公安/风控` 零命中。**但同一台机器上的另一个包确有此能力**：`com.miui.securitycenter` 的"电诈防护 / 紧急报警"链路使用 `eps.caict.ac.cn/eps/collect`（信通院反诈接口）与 `gateway-papa.cloud.weizhi.com/papa/upload`（第三方风控网关），小米在《AI 通话预警隐私政策》《第三方数据共享说明》中对这类上传/共享有明示披露 | ⚠️ **归因错位，不是事实错误**。内容真实，主体是 securitycenter / guardprovider，不是 SystemHelper |
| 4 | 拥有普通 App 不具备的特权级权限 | `READ_PRIVILEGED_PHONE_STATE`（仅 `priv-app`/平台签名可得）、`PACKAGE_USAGE_STATS`、`QUERY_ALL_PACKAGES`、`sharedUserId` | ✅ 成立 |
| 5 | 全天候静默后台、定时唤醒联网 | `OnBootReceiver`（开机+4 分钟延迟）、`SIMStateReceiver`、`ConnectStateReceiver`、`AlarmManager` 精确闹钟；3.0.1+ 周期 24h 设备 / 24h 应用 / 12h 信令 / 30min 信令触发；`RegisterJobService` + `startForeground` 保活 | ✅ 成立 |
| 6 | 采集设备唯一标识 | IMEI1/2、IMSI1/2、ICCID1/2；但 `Build.SERIAL`、`getSerial`、`ANDROID_ID`、`OAID` **三版全零命中** | ✅ 成立，但**边界要收窄**：没有序列号/OAID/AndroidID |
| 7 | 24 小时应用使用时长 | 3.0.1/4.0 `g1/d.java` appInfo 间隔 `86400000`；1.2 为 `604800000`（7 天） | ✅ 对 3.0.1/4.0；⚠️ 对 1.2 是 7 天 |
| 8 | 用户看不到采集范围、无法自主开关、只能被动接受"默认采集" | 无 UI 设置页、无开关；`GlobalSetting.isUserPermissionOpen` 默认 `true`；1.2 门关着仍 `insertRecord` | ✅ 成立 |
| 9 | 系统组件游离于"照明弹"监管之外、拥有权限豁免 | 照明弹（`com.miui.securitycenter` 侧）是否展示 priv-app，不由本 APK 决定，**静态分析无法判定** | ❓ 无法用本包证据证实；见 §9.3 的可验证替代 |
| 10 | 以"反诈防护"为名 | 本包**零反诈能力**：无关键词、无端点、无拦截/预警/举报代码；业务是终端注册 + 网络质量 | ⚠️ 对本包不成立；但"反诈防护"确实是同机另一个组件（securitycenter / guardprovider）的真实业务与对外说法 |

### 9.3 第 9 条的替代验证路径

"照明弹看不到"是**观测口径**问题，不是代码属性。可以自己验的三条：

```bash
# a) 系统侧是否记录了它的权限使用（AppOps）
adb shell dumpsys package com.mobiletools.systemhelper | grep -iE "granted=true|READ_PRIVILEGED|PACKAGE_USAGE"
adb shell cmd appops get com.mobiletools.systemhelper

# b) 是否真的在跑（进程/服务/闹钟）
adb shell ps -A | grep systemhelper
adb shell dumpsys activity services com.mobiletools.systemhelper
adb shell dumpsys alarm | grep -i systemhelper

# c) 是否真的在上报（抓包，4.0 注意两个端口）
#    18080 明文可直接看到 JSON；18081 为 TLS
```

若 (a)(b) 都能查到，那么"完全不可见"这个说法要改成"**不在面向普通 App 的隐私面板里展示**"——更准确，也更难反驳。

### 9.4 文章的政策主张，逐条给可行性与落点

| 主张 | 技术可行性 | 对 SystemHelper 的实际落点 |
|---|---|---|
| ① 反诈 AI 端侧化、数据不出端 | 可行（本地模型 + 本地样本库）；本包采集的 RSRP/TAC/CID 等本就是网优数据，端侧聚合即可 | 本包**没有反诈能力**，这条对它无落点；对它有效的是"**本地完成注册去重、只上传必要字段**" |
| ② 权限/功能细粒度拆分（云查杀、本地查杀、上报开关分开） | 可行 | 对本包应拆成三个开关：**设备注册上报 / 应用清单上报 / 位置与信令上报**——这正好对应它三条独立采集链路 |
| ③ 取消系统组件权限豁免，纳入统一审计 | 可行（AppOps 本就记录所有 UID 的权限使用，缺的是**展示**与**用户可撤销**） | 对本包应做到：`READ_PRIVILEGED_PHONE_STATE`、`PACKAGE_USAGE_STATS`、`QUERY_ALL_PACKAGES` 三项**可在设置里撤销并验证生效** |

### 9.5 一句话评价这篇

**方向成立，归因错位。** 它把"反诈组件"（securitycenter / guardprovider）的行为套到了 SystemHelper 身上——"上传反诈服务器""第三方风控"这两句**内容是真的**（`eps.caict.ac.cn/eps/collect`、`gateway-papa.cloud.weizhi.com/papa/upload`，厂商隐私文档亦有披露），只是**不属于这个包**。但它指出的真问题——**特权组件无开关、无告知、不可审计、采集超出业务必要**——在 SystemHelper 上条条成立，而且比它写的更硬：`device_provisioned` 冒充同意、门关着也入库、默认值就是"同意"。

**要改口径的只有一处**：把"SystemHelper 上传反诈服务器"改成"**同机的反诈组件上传反诈/第三方风控，SystemHelper 上传联通 DM**"。这样既不失真，也不给"连包名都没分清"留反驳口。

---

## 10. 边界声明

- 本地结论均可用文内 `文件:行号` 复核；源码位于 `jadx_out/sources`（1.2）、`jadx_v301/sources`（3.0.1）、`jadx_v4/sources`（4.0）。
- 本帖 ④⑤ 涉及的两个组件本工作区无样本，**不并入 SystemHelper 的结论**；如需定性，须单独取 `com.miui.guardprovider` 与 `com.miui.securitycenter` 做同等级别反编译比对。
- 帖子的 ⑦ 属法域与第三方研究范畴，本报告不做背书。

---

## 10. 三版差异速查（原分散在各版本报告中的核对结论，已合并）

| 断言 | 1.2（20220907） | 3.0.1（20260313） | 4.0.0（20260910） |
|---|---|---|---|
| 激活是否要求中国 SIM | **无 MCC 门**：WiFi 分支不做任何 SIM 校验，插境外卡 + 连 WiFi 照发；蜂窝分支才要求联通 MNC | `isChinaNetwork()` 要求 MNC 以 `460` 开头；**异常路径直接 `return TRUE`，MCC 门失效** | 同 3.0.1 结构 |
| 联通 MNC 白名单 | `46001 / 46006 / 46009` | 增加 `46010` | `46001 / 46006 / 46009 / 46010` |
| "用户许可"门的真身 | `device_provisioned`；`isUserPermissionOpen` 默认 `true`，且**门关着仍 `insertRecord`** | 同（`isBootWizardCompleted`） | 同 |
| 补传与抖动 | 失败入 SQLite，100 条历史 | `dmregister` 上限 10、**先删后发**、首次触发 0–24h 随机抖动 | 同 3.0.1，上限 10 |
| 厂商适配器数量 | **58 家**（含 HUAWEI，无 WIKO） | **12 家**（首次去掉华为，首次加入 WIKO） | **13 家**（加 MOTO；帖子数的是这一版） |
| Samsung modem/基带版本 | 零命中 | 零命中 | 零命中（三版 `modem` / `baseband` 全零） |
| 传输 | 明文 HTTP `:18080` | 明文 HTTP `:18080` | HTTPS `:18081` 为主 + 证书失败降级 `:18080` |
| 录音 / 投屏 / AIGC 检测 | 无（`MediaProjection` 仅来自 support 库 `ContextCompat`） | 无 | 无（`VOICE_CALL` / `AudioRecord` / `detection-aigc` / `guardprovider` 计数均为 0） |
| 权限数量 | 见各版报告 | 17 项 | **19 项**（17 + `BLUETOOTH` + `BLUETOOTH_CONNECT`） |

> 帖子 ④⑤ 描述的 `AiGuard`、`foregroundServiceType=0xA0`、`AudioRecord(4)=VOICE_CALL`、`MediaProjection` 截屏、`detection-aigc.engine.miui.com`，属于同机的 `com.miui.guardprovider` 与 `com.miui.securitycenter`，不是本包。本报告对 SystemHelper 的结论不包含这些能力。

---

*本文为 **systemhelper** 研究集的一部分 · 许可 [CC BY 4.0](../LICENSE) · [返回目录](../README.md)*
