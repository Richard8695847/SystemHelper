# SystemHelper（com.mobiletools.systemhelper）逆向分析与根治报告

> 分析对象：`SystemHelper-com.mobiletools.systemhelper-1.2-20220907.apk`
> 分析方式：静态解包（jadx 1.4.7 反编译 / androguard 4.1.4 解析 / smali 交叉验证）
> 分析时间：2026-11-07
> 结论级别：**高置信**（代码、清单、字符串、证书四路互相印证）
>
> **关于文中出现的地址**：报告内的 IP 已替换为文档保留地址（`203.0.113.0/24`、`198.51.100.0/24`）；本地路径、主机名与设备标识已移除。域名保留，因为它们是被分析对象本身。

---

## 0. 一句话结论

这个 APK **不是一个面向用户的 App**，而是一个**中国联通「终端注册 / 设备管理（DM）」的预装采集模块**：

- 它必须拿到 `READ_PRIVILEGED_PHONE_STATE`（签名/系统级权限，普通应用装不上、装了也拿不到数据）才能读到 IMEI，说明它出厂就在 `priv-app` 里；
- 它在**开机、换卡、联网、定时闹钟**四个时机自动采集并上报，**没有用户可见界面、没有隐私弹窗、没有关闭开关**；
- 上报内容包括 IMEI1/2、IMSI1/2、ICCID1/2、本机号码、基站小区号/LAC、5G/VoLTE 状态、**GPS 经纬度**、**全部已安装应用 + 使用时长 + 分应用流量**；
- 通道是**明文 HTTP**（`usesCleartextTraffic="true"`），只有一层自制"加密"，密钥就是报文自身的 MD5；
- 服务器端点是 `dm.wo.com.cn`（联通沃 DM 平台）、`198.51.100.26:8080`（BONC 联通注册 WebService）、以及一个**花生壳动态域名 `cnc-labs.eicp.net`**（典型的开发/联调遗留）。

所以"隐私被侵犯"的根源不是"用户装了一个流氓软件"，而是**厂商 ROM 里预置了一个采集组件，而它的权限比普通 App 高得多**。

---

## 1. 样本档案（可用于投诉/举报的固定证据）

| 项 | 值 |
|---|---|
| 包名 | `com.mobiletools.systemhelper` |
| 版本 | `1.2-20220907`（versionCode `3`） |
| 应用名 | SystemHelper |
| 文件 MD5 | `8e9df43efd6d898f6db46053e69d37fb` |
| 文件 SHA-256 | `416d0fc0405fc19b243e72f2a7963517e5b88991a7dfac494934449969a6015d` |
| 文件大小 | 1,685,429 字节 / 408 个条目 |
| 签名方案 | v1 + v2（无 v3） |
| 签名主体 | `CN=NewDM, OU=RI, O=CU, L=BJ, ST=BJ, C=86` |
| 签名 SHA-1 | `0D:0B:1F:90:18:23:91:C7:75:04:B8:43:DD:39:37:B2:3D:74:9A:E6` |
| 签名 SHA-256 | `87:4B:8C:A2:29:7F:53:A3:73:B1:B9:35:C1:34:CB:0E:B1:FF:73:81:E5:44:91:B8:8C:64:3A:6B:9C:46:DB:77` |
| 证书有效期 | 2019-03-21 → **2069-03-08**（50 年，典型的内部自签调试证书） |
| 证书国家码 | `C=86`（中国）、`O=CU`（China Unicom 缩写）、`OU=RI` |
| `sharedUserId` | `com.mobiletools.systemhelper.uid` |
| minSdk / targetSdk | 24 / 33 |
| 内嵌上报公钥 | `assets/pub.cer`：`CN=UNICOM, OU=UNICOM, O=UNICOM`，**1024 位 RSA**，有效期 2019-05-24 → **2119-04-30** |

> 说明：`C=86 / O=CU`、`O=UNICOM`、`dm.wo.com.cn`、`webservice.chinaunicom.com` 四个独立证据指向同一归属：中国联通体系内的终端注册平台。证书本身是自签的（Issuer == Subject），不是任何公共 CA 签发。

---

## 2. 定性：它在系统里扮演什么角色

`AndroidManifest.xml` 里只有一个 Activity，名字叫 **`TestActivity`**，而且布局里只有一个 `TextView` 用来显示采集到的 JSON。**这说明它本身没有产品形态，是个后台服务型组件，Activity 只是联调时看数据的调试页。**

关键证据链（为什么判定为"预装系统级模块"而不是普通 App）：

1. **`android:sharedUserId="com.mobiletools.systemhelper.uid"`**
   声明了共享 UID。普通应用极少使用；使用它的目的是让**同一签名的一批预装应用共用同一个 Linux UID**，从而共享权限与数据目录。
2. **申请 `android.permission.READ_PRIVILEGED_PHONE_STATE`**
   该权限**只能由系统签名或 `/system/priv-app` 下的应用持有**。普通应用即使声明也永远拿不到。它声明了，说明装机位置在 `priv-app`。
3. **代码里真的去读 IMEI**
   `DeviceInfoReaderBase.java:254` `telephonyManager.getImei(0)` / `:255` `getImei(1)`。
   Android 10+ 上非特权应用调用 `getImei()` 直接抛 `SecurityException` 返回 null；能拿到值 → 证明是特权应用。
4. **静默修改系统设置**
   `DeviceInfoReaderBase.java:158-176` `checkAndOpenVoLTEAndroidR()` 通过反射调用隐藏 API `ImsMmTelManager.setAdvancedCallingSettingEnabled(true)`，**在用户不知情的情况下把 VoLTE 打开**。该 API 正常需要 `MODIFY_PHONE_STATE`（系统级）。
5. **58 个厂商适配类**
   `com/mobiletools/systemhelper/device/` 共 62 个类，其中 **58 个是 `DeviceInfoReader*.java`**（含基类），覆盖华为、小米、OPPO、vivo、三星、魅族、中兴、酷派、联想、格力、努比亚、鼎桥（DingQiao/TD Tech）、中国移动（PTAC）等。**这是典型的"运营商定制机 / 白牌机批量适配"工程特征**，个人开发者不会写 58 个厂商分支。
6. **绑定厂商私有系统服务**
   `RegisterIntentService.java:76-87` 绑定 `com.android.phone/com.android.phone.nubia.NBExtTelephonyService` 和 `com.gree.telephonymanager.GreeTelephonyManagerService` —— 只有预装应用才能 bind 这些系统服务。

---

## 3. 权限与组件攻击面

### 3.1 申请的权限（12 项）

| 权限 | 用途 | 风险 |
|---|---|---|
| `INTERNET` | 上报 | — |
| `RECEIVE_BOOT_COMPLETED` | 开机自启 | **高（不可关闭）** |
| `ACCESS_FINE_LOCATION` / `ACCESS_COARSE_LOCATION` / `ACCESS_BACKGROUND_LOCATION` | 定位 | **高（后台定位）** |
| `READ_PHONE_STATE` | IMEI/IMSI/ICCID/号码 | **高** |
| `READ_PRIVILEGED_PHONE_STATE` | 读 IMEI（特权） | **极高（仅系统应用）** |
| `PACKAGE_USAGE_STATS` | 读应用使用时长 | **极高（等同"看用户在用哪些 App"）** |
| `QUERY_ALL_PACKAGES` | 枚举全部已装应用 | **高** |
| `READ_EXTERNAL_STORAGE` | 读外部存储 | 中 |
| `ACCESS_NETWORK_STATE` | 网络判断 | 低 |
| `SCHEDULE_EXACT_ALARM` | 精确定时唤醒 | 中（保活） |

自定义权限：`com.mobiletools.systemhelper.permission`，`protectionLevel=0x2`（**signature**，只允许同签名应用调用）。

### 3.2 组件清单

| 类型 | 组件 | exported | 说明 |
|---|---|---|---|
| Activity | `Activity.TestActivity` | **true** | 无权限保护，任意应用可拉起；拉起后弹权限框并显示采集 JSON |
| Receiver | `control.OnBootReceiver` | **true**（priority `2147483647`） | 开机 / 快速开机 → 延迟 4 分钟采集，并注册三套 Alarm |
| Receiver | `control.SIMStateReceiver` | **true** | 监听 `SIM_STATE_CHANGED`，换卡即采集 |
| Receiver | `control.ConnectStateReceiver` | **true** | 监听 `CONNECTIVITY_CHANGE` |
| Receiver | `control.ScheduleRegisterReceiver` | false | Alarm 触发定时采集（默认 24h） |
| Receiver | `control.AppInfoRegisterReceiver` | false | Alarm 触发应用清单采集（默认 7 天） |
| Service | `service.RegisterHelperService` | **true** | AIDL 远程接口（signature 权限保护） |
| Service | `service.RegisterIntentService` | false | 厂商特化采集线程（努比亚/格力） |
| Service | `service.RegisterJobService` | false | `BIND_JOB_SERVICE`，保活用 |

### 3.3 AIDL 远程控制面（**这是最危险的一处设计**）

`IRegisterHelperService.aidl` 暴露 5 个事务（`RegisterHelperService.java:52-77`）：

```java
setServerAddress(String str)   // ← 改上报服务器地址
setScheduleInterval(int i)     // ← 改采集频率（同时把 appInfo 间隔改成 i*8/5）
cleanRegisterData()            // ← 清本地痕迹
logEnable(boolean z)           // ← 开日志
isLogEnable()
```

`setServerAddress` 允许把上报地址**改成任意 URL**。虽然该服务由 signature 权限保护，但结合 `sharedUserId`：**任何与它同签名的预装 APK 都能加入同一 UID、直接调用 `setServerAddress`，把整机 IMEI/IMSI/号码/应用清单/位置改投到第三方服务器。** 而这张签名证书是 2019 年的自签 `NewDM` 调试证书 —— 这类证书私钥在代工厂、方案商、集成商之间流转是常态。**签名私钥一旦外流，"谁都能把这条数据管道接走"就是现实风险。**

---

## 4. 采集了什么（字段级）

数据模型见 `control/DeviceInfo.java:17-53`，序列化见 `getJsonString()`（`:151-329`）。上报 JSON 的完整字段：

| JSON 字段 | 含义 | 敏感级别 |
|---|---|---|
| `Manuf` / `Model` / `HWVersion` / `SWVersion` | 厂商 / 机型 / 硬件版本 / 固件版本 | 中（可精确识别机型） |
| `OS` / `OSVersion` | Android 版本 | 低 |
| **`IMEI1` / `IMEI2`** | 双卡 IMEI | **极高（设备唯一标识，可跨 App 追踪）** |
| **`IMSI1` / `IMSI2`** | 双卡 IMSI（SIM 卡用户标识） | **极高** |
| **`ICCID1` / `ICCID2`** | 双卡 SIM 卡序列号 | **极高** |
| **`MSISDN1` / `MSISDN2`** | **本机手机号码** | **极高** |
| `MNC1` / `MNC2` | 运营商编码（46001/46006/46009 = 联通） | 中 |
| `NCLS1` / `NCLS2` | 网络类型（GSM/WCDMA/LTE/NR/NSA/SA） | 中 |
| **`CellID1/2` + `LAC1/2`** | 基站小区号 + 位置区码 | **高（可反查物理位置，精度 100~1000 米）** |
| `VolteEnabled1/2`、`5GEnabled1/2` | VoLTE / 5G 开关状态 | 低 |
| `DataSlot` | 数据主卡槽位 | 低 |
| `AccType` | 接入类型 | 低 |
| `IPv4` / `IPv6`（可选） | 公网 IP + 本机 IPv6 | 中 |
| `SignalInfo`（可选） | RSRP / RSRQ / SINR | 低 |
| **`AppInfo`** | **全部已安装/使用过的应用数组：`pkgName` + `appLabel` + `runTime`(前台分钟) + `tx1/rx1/tx2/rx2`(卡1/卡2 上下行 KB) + `totalData1/totalData2/totalDataWiFi`** | **极高（完整用户画像 + 分卡流量归因）** |
| **`History`** | 本地 SQLite 里积压的**最多 100 条历史报文**，一次性随包上传 | **极高（等于批量补交历史轨迹）** |
| `DeviceType` | 设备类型（手机/车机云镜/iPad 4G…） | 低 |
| `RegType` | 触发类型：`F`=首次开机、`B`=开机、`T`=换卡、`S`=定时、`A`=应用清单 | — |
| `SpecVersion` / `RegVersion` / `Time` | 协议版本 / 客户端版本 / 时间戳 | — |

### 应用清单采集细节（`QueryAppInfoThread.java`）

```java
// :73-90  查询时间窗内所有应用的使用统计
queryAndAggregateUsageStats(queryStartTime, queryEndTime)   // 默认窗口 = 7 天
appInfo.setRunTime(usageStats.getTotalTimeInForeground() / 60000);  // 前台分钟数
getNetworkStats(appInfo);                                   // 分应用流量（NetworkStatsManager）

// :119-125 通过隐藏/受限 API 读取每应用流量
// :158-160 还专门筛选"同时拥有 RECEIVE_SMS + READ_PHONE_STATE 的应用"
isHaveReceiveSmsAndReadPhoneState(...)
```

最后这个方法值得单独说明：`isHaveReceiveSmsAndReadPhoneState()`（`:158-160`）筛选的是**"同时具备 `RECEIVE_SMS` + `READ_PHONE_STATE` 权限、且包名不等于 `com.derekjiang.smsforward`"的应用**。在当前版本里**它没有调用点（死代码）**，但两点信息很关键：

1. 它暴露了开发阶段曾计划把采集范围扩展到**"识别哪些 App 能读短信"**；
2. 硬编码排除 `com.derekjiang.smsforward`（一个短信转发工具包名）说明开发方在设计时就考虑过"什么 App 会干扰它的上报链路"。

即便这一条当前未启用，也足以说明该模块的设计边界远超"设备注册"所需。

### 定位采集细节（`DMTelephonyCallback.java:197-208`）

```java
Location lastKnownLocation = locationManager.getLastKnownLocation("gps");
while (lastKnownLocation == null) {
    locationManager.requestLocationUpdates("gps", 2000L, 0.0f, listener);  // 2 秒一次，持续请求
}
GlobalSetting.lc = String.valueOf(lastKnownLocation);   // 经纬度拼进调试日志
```

虽然最终上报字段以基站为主，但**GPS 坐标被持续请求并缓存**，且 `GlobalSetting.lc` 里存的是完整 `Location.toString()`（含经纬度、精度、时间）。

### 唯一一处"脱敏"，而且有漏洞

`DeviceManager.sortAndAnonymousSubscriber()`：

```java
if (MNC1 不是联通（46001/46006/46009）) {
    ICCID1 = MD5(ICCID1);
    MSISDN1 = MD5(MSISDN1);
    IMSI1  = MD5(IMSI1);
    CellID1 = MD5(CellID1);
    LAC1    = MD5(LAC1);
}
```

也就是说：**插联通卡 → 全部明文上报；插移动/电信卡 → 才做 MD5。** 这是为了"减少非本方数据落库"，而不是为了保护用户。而且 MD5 无盐，手机号/IMSI 的取值空间极小，**彩虹表可秒查还原**，等于没脱敏。

---

## 5. 数据流与时序：它什么时候动手

```
开机 / QUICKBOOT
  └─ OnBootReceiver (:34-40)
       ├─ 延迟 240 秒 → BootAlarmAfter → 再次进入 OnBootReceiver
       ├─ ScheduleAlarmAfter(24h)   → ScheduleRegisterReceiver → RegType="S"
       └─ AppInfoAlarmAfter(7d)     → AppInfoRegisterReceiver → RegType="A"

SIM_STATE_CHANGED（换卡 / 卡就绪）
  └─ SIMStateReceiver (:46-53)
       ├─ simState 1/5 → 延迟 360 秒重试
       └─ 采集 → RegType="T"

CONNECTIVITY_CHANGE（联网）
  └─ ConnectStateReceiver

Alarm 到期
  └─ ScheduleRegisterReceiver → RegType="S"（默认每 24 小时一次）
  └─ AppInfoRegisterReceiver  → RegType="A"（默认每 7 天一次）
```

采集 → 组包 → 上传的编排在 `DeviceManager.getCurDeviceInfo()`（`:593-616`）：

```
privateGetDeviceInfo()        // 读机型/系统/运行环境
  → isSIM1Changed/isSIM2Changed  // 与 SharedPreferences 里的 ICCID 比对，判断换卡
  → sortAndAnonymousSubscriber() // 双卡排序 + 非联通卡 MD5
  → QueryAppInfoThread.start()   // 采应用清单（仅 RegType="A" 或 API>=23 全量路径）
      → GetIPAddressThread.start()（可选，GET_IP_ENABLED）
          → RegisterThread.start()
```

上传决策在 `RegisterThread.register()`（`:90-110`）：

```java
if (!网络已连接)      → 存本地 SQLite，等下次
else if (WiFi 已连)   → 直接上传     ← 注意：WiFi 下不判断运营商！
else if (!漫游 && MNC 是联通) → 上传
else                  → 存本地，不上传
```

**判定逻辑的含义**：只要手机连着任何 WiFi，无论插的是哪家卡，数据都会上传。所谓"仅联通网络"的限制实际上只在蜂窝数据下生效。

---

## 6. 外发链路与加密实现（含 4 个实质缺陷）

### 6.1 端点清单

| 端点 | 用途 | 代码位置 |
|---|---|---|
| `http://dm.wo.com.cn:18080/registerv3` | 主上报接口（默认） | `GlobalSetting.java:14` |
| `http://dm.wo.com.cn:18080/public/ip` | 查询公网 IP | `GlobalSetting.java:25` |
| `http://dm.wo.com.cn:6002/registerv3/getRegisterLog` | 上传运行日志 | `LogPostHelper.java:8` |
| `http://198.51.100.26:8080/bonc_Register/RegisterPort?wsdl` | BONC 注册 WebService（字节数组混淆） | `WebServiceHelper.java:6` |
| `http://cnc-labs.eicp.net:8080/registerService/web/getRegister` | 开发/联调遗留接口（花生壳动态域名） | `HttpHelper.java:9` |
| `http://webservice.chinaunicom.com/GetRegister` | SOAP Action 命名空间 | `WebServiceHelper.java:5,8` |

> `cnc-labs.eicp.net` 是**花生壳（Oray）动态域名**。运营商生产系统不会用花生壳；这说明**开发/测试服务器地址被硬编码进了正式包**，并且该域名的解析权在第三方动态 DNS 服务商手里。

### 6.2 加密方案（`RegisterThread.doEncrpytPost()` + `Cryptography.java`）

```java
byte[] md5   = MD5(jsonString);                                  // ① 密钥 = 报文 MD5
String sign  = Base64(RSA_encrypt(pub.cer, md5));                // ② 用"公钥"做签名
byte[] body  = AES_ECB_PKCS5(jsonString, key = md5);             // ③ AES/ECB 加密
POST "…/registerv3?ver=3.0&model=…&manuf=…&sign=…"  body=body   // ④ 明文 HTTP
```

**缺陷 1：传输层是明文 HTTP。** Manifest 里 `android:usesCleartextTraffic="true"`，全部端点都是 `http://`。报文头里的 `model`、`manuf`、`sign` 直接裸奔，任何人同一 WiFi 下抓包即可看到设备型号与全部通信节奏。

**缺陷 2：AES/ECB + 密钥 = 报文 MD5。** ECB 模式相同明文块产生相同密文块，可做块级重放与统计分析；密钥直接由明文派生（无盐、无随机数、无 KDF），同一个 JSON 永远得到同一份密文和同一个密钥。

**缺陷 3：`sign` 不是签名，是"公钥加密"。** 公钥就打包在 `assets/pub.cer` 里，**任何人解包 APK 都能生成合法 `sign`**。所以这套机制**零客户端身份认证** —— 任何人都能向 `dm.wo.com.cn` 批量伪造设备注册报文，污染运营商设备库。这是服务端设计缺陷，也意味着"这份数据是谁传的"在服务端根本无法证明。

**缺陷 4：1024 位 RSA。** `pub.cer` 是 1024 位（2019 年签发，标称有效到 2119 年）。1024 位 RSA 早已不在安全强度范围内。

### 6.3 服务器地址可被远程改写

`RegisterUtils.getServerAddress()` 读 SharedPreferences 的 `serverAddress`（默认 `dm.wo.com.cn:18080`），而该值可由 `IRegisterHelperService.setServerAddress()` 改写。**采集端的上报目的地是一个运行时可变的配置项，而不是硬编码常量。**

---

## 7. 本地留存

| 位置 | 内容 | 风险 |
|---|---|---|
| `databases/systemhelper`（表 `history`） | 最多 **100 条**完整上报 JSON（**明文**，含 IMEI/IMSI/号码/基站/应用清单） | 高：`allowBackup="false"` 挡住了云备份，但 root/取证工具可直接读 |
| `databases/<SignalDB>` | 信号强度历史 | 低 |
| `shared_prefs/com_mobiletools_systemhelper_preference.xml` | `iccid1`/`iccid2`（**明文存 SIM 卡号**）、`firstPowerOn`、`serverAddress`、采集间隔 | 高 |

`DatabaseHelper.insertRecord()`（`:63-73`）在超过 100 条时删最旧一条；`clearHistory()` 在**上报成功后**才清空。也就是说：**离线期间的所有采集记录会累积在本地，等联网后连同 `History` 字段一次性补传。**

---

## 8. 隐蔽手段汇总

| 手段 | 位置 | 说明 |
|---|---|---|
| 无界面、无通知 | 全局 | 唯一 Activity 是调试页；服务全程静默 |
| 开机自启 + 4 分钟延迟 | `OnBootReceiver:35-36` | 避开开机高峰，降低被用户察觉概率 |
| 三套 `setExactAndAllowWhileIdle` 闹钟 | `AlarmHelper:21-79` | 可穿透 Doze 模式唤醒 |
| `JobService` 兜底 | `RegisterJobService` | 闹钟被杀后仍可被系统调度拉起 |
| 隐藏 API 反射 | 53 个文件使用 `Platform.invokeMethod` / `Utils.invokeMethod` | 绕过公开 SDK 的限制读 IMSI/小区/基带信息 |
| 静默开 VoLTE | `DeviceInfoReaderBase:158-176` | 直接改用户网络设置 |
| 延迟 6 分钟等 SIM 就绪 | `SIMStateReceiver:50-51` | 确保能读到完整 IMSI |
| 上报失败静默入队 | `RegisterThread:118-121` | 不报错、不提示，等下次补传 |
| 日志开关默认关闭 | `GlobalSetting.LOG_ENABLE = false` | 默认不留 logcat 痕迹（`MyLog` 全部受此开关控制） |

---

## 9. 对个人的实际危害评估

拿到这份数据的人可以做到：

1. **设备指纹**：IMEI1+IMEI2+ICCID+IMSI 组合 → 唯一锁定这台手机，换号、换卡、恢复出厂都能重新关联。
2. **实名关联**：`MSISDN`（本机号码）+ `IMSI` → 直接对应到实名登记的用户。
3. **物理定位**：`CellID + LAC` 默认每天随定时上报刷新一次（`DEFAULT_SCHEDULE_INTERVAL = 86400000`），换卡、开机、重连时额外刷新，长期累积即为**移动轨迹**；配合 GPS 缓存，精度可到米级。
4. **行为画像**：`AppInfo` 里有每个 App 的前台使用分钟数，以及**按卡 1 / 卡 2 / WiFi 分别统计的上行、下行流量和总量**（`AppInfo.java:12-34`，字段 `tx1/rx1/tx2/rx2/totalDataWiFi`），7 天一个周期 → **用户用什么银行、什么社交、什么医疗、什么交友 App，各用了多久、各跑了多少流量，一目了然，甚至能按卡归因"这张卡主要用来干什么"。**
5. **采集意图外溢**：代码里遗留了 `isHaveReceiveSmsAndReadPhoneState()`（筛"能读短信 + 手机状态"的应用，并特意排除某个短信转发工具包），当前版本未调用，但说明设计上考虑过**进一步识别短信类/验证码类 App**。
6. **历史补传**：`History` 字段一次最多补交 100 条旧报文 → 即便用户某段时间关网，数据也不丢。

**这不是"可能被滥用"，而是"已经在被系统性收集"。** 是否被滥用，取决于这条管道上有多少环节、多少人有权限，以及那张 2019 年自签证书的私钥在谁手里。

---

## 10. 根因分析：为什么会有这个东西

分三层，从表到里：

### 第一层（表象）：这不是应用商店里的 App

它的权限集合（`READ_PRIVILEGED_PHONE_STATE`、`PACKAGE_USAGE_STATS`、`QUERY_ALL_PACKAGES`、后台定位）**在正常渠道安装流程下无法获得**。它能跑起来，只有一个解释：**它在出厂镜像里，位于 `/system/priv-app` 或 `/product/priv-app`，或者与某个特权应用共享 `sharedUserId`。**

→ 因此在设置里"停用"它，往往只是停用了当前用户的一份副本，系统分区里的原件还在，恢复出厂就回来。

### 第二层（机制）：运营商侧的"终端注册"是刚性业务需求

工信部对入网终端有设备注册/IMEI 核验要求，运营商需要知道"哪台设备、插了哪张卡、在哪个基站、用的什么网络制式"，用于：

- 终端入库与窜货管理（防止跨省/跨渠道串货）
- 网络质量与覆盖优化（基站 + 信号强度上报）
- 5G/VoLTE 开通率统计（`5GEnabled`、`VolteEnabled` 字段就是干这个的）
- 定制机补贴核销

→ 这套业务本身有其合理性。**问题出在实现上：为了让"注册成功率"最大化，工程上选择了"静默、全量、高权限、不可关闭"的实现方式。**

### 第三层（真正的根因，也是用户层面能改变的部分）：

1. **权限与业务不匹配（越权采集）**
   注册只需要 IMEI + ICCID + MNC + 网络制式。它却额外拿了 `PACKAGE_USAGE_STATS` + `QUERY_ALL_PACKAGES` + 后台定位 + GPS，去采**应用清单、使用时长、分应用流量、经纬度**。这已经超出"设备注册"的必要范围，属于**超范围收集**，直接违反《个人信息保护法》第 6 条"最小必要"原则。

2. **没有告知、没有同意、没有退出机制**
   全流程没有一个隐私弹窗，没有开关，没有"拒绝后仍可使用"的选项。`RegisterThread.run()` 里唯一的相关判断是 `GlobalSetting.isUserPermissionOpen`，而它**硬编码为 `true`**（`GlobalSetting.java:39`）。所谓"用户许可"是一个永远为真的常量。违反《个人信息保护法》第 13、14、17 条。

3. **合规设计缺位（技术层面）**
   - 明文 HTTP 传输敏感标识 → 违反《个人信息安全规范》传输加密要求
   - 本地明文存 100 条含 IMEI/号码的记录 → 违反存储加密要求
   - 上报地址可被 AIDL 改写、签名私钥为 2019 年调试证书 → **数据流向不可控**
   - `History` 批量补传 → 超出"实时注册"的必要性

4. **供应链问题**
   58 个厂商适配类 + 花生壳调试域名 + 50 年有效期的自签证书 + `TestActivity` 调试页留在正式包 → **这个包是"开发态"直接出厂的，没有经过发布前清理**。这说明厂商侧缺少上架/出厂前的安全与合规门禁。

**一句话根因：一个本应"最小必要、明示同意、加密传输"的设备注册模块，被做成了"高权限、静默、全量、不可关闭、明文传输、可被远程改地址"的采集管道，并且直接烧进了出厂镜像。**

---

## 11. 根治方案（四层，从"立刻止血"到"彻底清除"）

> 下面命令用 `adb`（Windows 上把 `adb` 加进 PATH，或用 Android SDK 的 `platform-tools\adb.exe`）。
> 先连上手机并开 USB 调试：`adb devices` 应能看到设备。

### 第 0 步：先确认它到底装在哪（决定后面用哪套方案）

```bash
adb shell pm path com.mobiletools.systemhelper
adb shell pm list packages -f | grep systemhelper
adb shell dumpsys package com.mobiletools.systemhelper | grep -E "codePath|flags|sharedUser|granted=true"
```

三种结果，对应三种处置：

| `codePath` 前缀 | 含义 | 走哪套方案 |
|---|---|---|
| `/data/app/...` | 用户自己装的（或某 App 静默装的） | **方案 A（最简单，直接卸载）** |
| `/system/priv-app/...`、`/product/priv-app/...`、`/system/app/...` | 出厂预装 | **方案 B（当前用户移除 + 权限封锁 + 网络阻断）** |
| 查不到，但 `dumpsys` 里有、或 `ps -A \| grep systemhelper` 有进程 | 被其他包名/共享 UID 承载 | **方案 C（挖出宿主包）** |

### 方案 A：普通安装 → 直接卸载（30 秒）

```bash
adb shell pm uninstall com.mobiletools.systemhelper
adb shell pm uninstall --user 0 com.mobiletools.systemhelper   # 若是多用户/工作资料
```

验证：

```bash
adb shell pm list packages | findstr systemhelper    # 应无输出
```

### 方案 B：预装 → 三步走（推荐，无需 root）

#### B-1 停用（最安全，可逆）

```bash
adb shell pm disable-user --user 0 com.mobiletools.systemhelper
adb shell am force-stop com.mobiletools.systemhelper
```

`disable-user` 之后它不再响应任何广播、闹钟、开机自启，**且随时可以用 `pm enable` 恢复**，不影响保修。

#### B-2 彻底移除当前用户副本（更干净）

```bash
adb shell pm uninstall --user 0 com.mobiletools.systemhelper
```

> 注意：`/system` 分区是只读的，`--user 0` 只是"对当前用户隐藏"，系统分区原件仍在。**恢复出厂设置后会复活。** 这也是为什么还需要 B-3。

#### B-3 逐项撤销已授予的运行时权限与 AppOps（双保险）

即使组件被禁用，某些 AppOps 仍可能残留。逐条执行：

```bash
# 运行时权限
adb shell pm revoke com.mobiletools.systemhelper android.permission.READ_PHONE_STATE
adb shell pm revoke com.mobiletools.systemhelper android.permission.ACCESS_FINE_LOCATION
adb shell pm revoke com.mobiletools.systemhelper android.permission.ACCESS_COARSE_LOCATION
adb shell pm revoke com.mobiletools.systemhelper android.permission.ACCESS_BACKGROUND_LOCATION
adb shell pm revoke com.mobiletools.systemhelper android.permission.READ_EXTERNAL_STORAGE

# AppOps（覆盖"使用情况访问"这类不走运行时权限的能力）
adb shell appops set com.mobiletools.systemhelper READ_PHONE_STATE ignore
adb shell appops set com.mobiletools.systemhelper GET_USAGE_STATS ignore
adb shell appops set com.mobiletools.systemhelper COARSE_LOCATION ignore
adb shell appops set com.mobiletools.systemhelper FINE_LOCATION ignore
adb shell appops set com.mobiletools.systemhelper READ_EXTERNAL_STORAGE ignore
```

验证：

```bash
adb shell dumpsys package com.mobiletools.systemhelper | findstr /C:"granted=false" /C:"disabled"
adb shell appops get com.mobiletools.systemhelper
```

### 方案 C：网络层封堵（**最关键的一层**，覆盖"删不掉/复活/别的模块也在传"的情况）

这一步不管它装在哪、是不是系统应用，**只要流量出不去，数据就传不走**。

#### C-1 私有 DNS（Android 9+，最简单，全局生效）

`设置 → 网络和互联网 → 私人 DNS → 指定私人 DNS 提供商主机名`，填：

```
dns.adguard-dns.com
```

（AdGuard DNS 会拦截广告/追踪域名。若机型不支持自定义规则，走 C-2。）

#### C-2 本地 VPN 防火墙（推荐，可精确到域名和 IP）

装 **NetGuard**（开源，无需 root，GitHub 发布）或 **RethinkDNS**，导入以下黑名单：

```
dm.wo.com.cn
cnc-labs.eicp.net
webservice.chinaunicom.com
198.51.100.26
```

并在规则里对 SystemHelper（如果它还在）设为**完全禁止联网（WiFi + 移动数据双禁）**。

验证方法：在 NetGuard 日志里搜 `dm.wo.com.cn`，应显示 `blocked`。

#### C-3 路由器 / 家庭网关层拦截（一劳永逸，全家设备生效）

在路由器 DNS 过滤或 hosts 里加：

```
0.0.0.0 dm.wo.com.cn
0.0.0.0 cnc-labs.eicp.net
0.0.0.0 webservice.chinaunicom.com
```

> 注意：`dm.wo.com.cn` 是联通的真实业务域名，**全局黑洞可能影响联通官方 App（如中国联通 App）的部分功能**。如果只用联通卡且需要联通 App，建议只在 C-2 里针对 SystemHelper 这个包做拦截，而不是全局黑域名。

### 方案 D：彻底清除（唯一真正的"根源解决"）

只有换掉出厂镜像才能算根治，因为系统分区里的原件删不掉（除非解锁 bootloader）。

**D-1 刷官方完整固件（推荐，风险最低）**
去厂商官网/售后下**完整线刷包**（不是 OTA 增量包），用官方工具（MiFlash / Odin / SP Flash Tool / 华为 eRecovery）**清空数据重刷**。注意：多数运营商定制机的官方固件里**这个模块是打包进去的**，重刷同版本会原样回来 —— 所以 D-1 只对"非定制版固件"有效。

**D-2 刷非定制/国际版/开源固件（真正根治）**
- 小米/红米：解锁 BL → 刷 **MIUI/HyperOS 国际版**或 **LineageOS**
- 一加/ Pixel：直接刷 **LineageOS / GrapheneOS**（GrapheneOS 对这类预装采集的防护最彻底）
- 三星：刷 **非运营商 CSC 的完整固件**（如 `XSA`/`DBT` 无运营商定制）
- 华为/荣耀（2019 后）：BL 已锁，**只能选 D-3**

**D-3 换机（最现实的根治）**
如果这台机器是运营商定制机且不打算折腾刷机：**换一台非运营商渠道购买的公开版机器**。运营商定制机的预装采集模块是商务合同的一部分，不是"bug"，厂商不会通过 OTA 移除它。

### 方案 E：合规维权（让"根因"在上游被修掉）

个人层面的技术处置只能保护自己。要让这类设计不再出现，走这条：

1. **固定证据**：本报告第 1 节的哈希 + 签名指纹 + 第 4 节的字段表 + 第 6 节的端点清单，就是完整的技术证据包。**不需要抓包也能成立**（静态代码即证据）。
2. **投诉渠道**：
   - **12321**（网络不良与垃圾信息举报受理中心）：举报"App 违规收集个人信息"
   - **工信部"工业和信息化部政务服务平台"→ 电信用户申诉**：针对运营商预装不可卸载
   - **App 违法违规收集使用个人信息举报**（[www.12377.cn](https://www.12377.cn) 或"App 个人信息举报"公众号）
   - **当地通信管理局**
3. **主张要点**（直接引用法条，投诉时照抄）：
   - 《个人信息保护法》第 6 条：处理个人信息应具有明确、合理的目的，限于实现处理目的的**最小范围**。→ 采应用清单/使用时长/流量/GPS 与"设备注册"无关。
   - 第 13 条：处理个人信息应取得**个人同意**。→ 本模块无任何同意流程。
   - 第 17 条：应**以显著方式、清晰易懂的语言**告知处理目的、方式、种类、保存期限。→ 无告知。
   - 第 44-47 条：个人有权**知情、决定、查阅、复制、删除**。→ 无任何行使入口。
   - 《移动智能终端应用软件预置和分发管理暂行规定》第 7 条：预置应用**应可卸载**（除基本功能软件外）。→ 该模块不可卸载。
4. **要求**：责令厂商提供**可卸载**的系统更新；责令运营商说明该模块的**数据保存期限、共享对象、删除途径**；要求**删除已采集的个人数据**。

---

## 12. 复核步骤（可复现）

```bash
# 1) 解包（本报告用的就是这套）
unzip SystemHelper-com.mobiletools.systemhelper-1.2-20220907.apk -d unpacked

# 2) 反编译（需要 JDK 8+）
jadx -d out --no-res SystemHelper-com.mobiletools.systemhelper-1.2-20220907.apk

# 3) 看权限与组件
cat out/resources/AndroidManifest.xml

# 4) 看采集字段（这就是上报的 JSON schema）
sed -n '17,53p' out/sources/com/mobiletools/systemhelper/control/DeviceInfo.java

# 5) 看上传实现（AES/ECB + MD5 密钥 + 明文 HTTP）
sed -n '41,85p' out/sources/com/mobiletools/systemhelper/control/RegisterThread.java

# 6) 看服务器地址
grep -rn "wo.com.cn\|eicp.net\|198.51.100.26" out/sources/

# 7) 看"用户许可"是不是永远为真
grep -n "isUserPermissionOpen" out/sources/com/mobiletools/systemhelper/utils/GlobalSetting.java
```

**运行时验证（可选，能拿到最硬的证据）**：
1. 手机装 **PCAPdroid**（免 root，本地 VPN 抓包），开启抓包 → 重启手机 → 等 5 分钟。
2. 在抓包里过滤 `dm.wo.com.cn`，可以看到 `POST /registerv3?ver=3.0&model=...&manuf=...&sign=...`。
3. 抓到的 `body` 是 AES 密文；用 `RegisterThread` 里的逻辑（key = MD5(明文)）无法反解，但**URL 里的 `model`/`manuf` 是明文**，足以证明"这个包在往这个地址传用户的设备信息"。
4. 截图 + 导出 pcap，作为投诉附件。

---

## 13. IOC 清单

```
# 域名
dm.wo.com.cn
cnc-labs.eicp.net
webservice.chinaunicom.com

# IP
198.51.100.26

# URL
http://dm.wo.com.cn:18080/registerv3
http://dm.wo.com.cn:18080/public/ip
http://dm.wo.com.cn:6002/registerv3/getRegisterLog
http://198.51.100.26:8080/bonc_Register/RegisterPort?wsdl
http://cnc-labs.eicp.net:8080/registerService/web/getRegister
http://webservice.chinaunicom.com/GetRegister

# 包 / 组件
com.mobiletools.systemhelper
com.mobiletools.systemhelper.uid          (sharedUserId)
com.mobiletools.systemhelper.Activity.TestActivity        (exported Activity)
com.mobiletools.systemhelper.control.OnBootReceiver       (exported, priority=MAX_INT)
com.mobiletools.systemhelper.control.SIMStateReceiver     (exported)
com.mobiletools.systemhelper.control.ConnectStateReceiver (exported)
com.mobiletools.systemhelper.service.RegisterHelperService(exported, AIDL)
com.mobiletools.systemhelper.service.IRegisterHelperService
com.mobiletools.systemhelper.permission     (signature-level)

# 文件 / 证书
assets/pub.cer        (CN=UNICOM, 1024-bit RSA, 2019→2119)
META-INF/CERT.RSA     (CN=NewDM, OU=RI, O=CU, C=86, 2019→2069)

# 本地存储
/data/data/com.mobiletools.systemhelper/databases/systemhelper      (表 history，100 条明文)
/data/data/com.mobiletools.systemhelper/shared_prefs/com_mobiletools_systemhelper_preference.xml
```

---

## 14. 处置完成后的验证清单

| 检查项 | 命令 / 方法 | 期望结果 |
|---|---|---|
| 包已移除/禁用 | `adb shell pm list packages \| findstr systemhelper` | 无输出 或 有 `disabled` 标识 |
| 进程不存在 | `adb shell ps -A \| findstr systemhelper` | 无输出 |
| 权限已撤销 | `adb shell dumpsys package com.mobiletools.systemhelper \| findstr granted` | 目标权限 `granted=false` |
| 无网络外联 | NetGuard 日志过滤 `wo.com.cn` | 全部 `blocked` |
| 开机不再触发 | 重启后 `adb shell dumpsys alarm \| findstr systemhelper` | 无待触发闹钟 |
| 本地数据已清 | `adb shell run-as com.mobiletools.systemhelper ls databases` | 目录不存在或为空 |

---

## 15. 一句话总结

**这个包是运营商预装的设备注册采集模块，用的是系统级权限，采的是用户的 IMEI、SIM 卡标识、手机号、基站位置和全部 App 使用记录，走明文 HTTP 往 `dm.wo.com.cn` 发，而且没有开关、不可卸载。**

**技术上的根治顺序是：先 `disable-user` + 撤权限（今天就能做），再上网络层拦截（堵死管道，最有效），最后换掉出厂镜像或换机（唯一彻底）。**

**制度上的根治是投诉：静态代码就是证据，不需要会抓包。**

---

## 16. 外部传闻核对

2026-11 起流传的日文帖（[`@tanaka_yuto`，2026-11-02](https://x.com/tanaka_yuto/status/2117066492672110700)）与两份中文来源的逐条核验已独立成篇：见 [06-rumor-verification.md](06-rumor-verification.md)。

本节不再重复，以免三处表述漂移。1.2 相对该帖的关键差异（无 MCC 门、关门仍入库、58 家厂商适配器）已并入该文的 §10「三版差异速查」。

---

*本文为 **systemhelper** 研究集的一部分 · 许可 [CC BY 4.0](../LICENSE) · [返回目录](../README.md)*
