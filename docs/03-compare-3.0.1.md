# SystemHelper 3.0.1 分析报告 · 与 1.2 全面对比 · 反诈问题结论

> 对象：`SystemHelper_3.0.1-20260313(1).apk`
> 对照：`SystemHelper-com.mobiletools.systemhelper-1.2-20220907.apk`
> 方法：jadx 1.4.7 反编译 + androguard 4.1.4 字节码/字符串分析 + 原生库扫描 + 证书比对
> 日期：2026-11-07
> 结论级别：高置信（协议、字段、签名、加密均已逐项比对）
>
> **关于文中出现的地址**：报告内的 IP 已替换为文档保留地址（`203.0.113.0/24`、`198.51.100.0/24`）；本地路径、主机名与设备标识已移除。域名保留，因为它们是被分析对象本身。

---

## 0. 一句话结论

**3.0.1 不是"升级"，是一次"改造升级"：**

1. **签名主体从中国联通换成了小米** —— 1.2 用 `CN=NewDM, O=CU`（联通自签调试证书），3.0.1 用 **`CN=MIUI, O=Xiaomi`（MIUI 平台签名证书）**。这说明 3.0.1 是**由小米签名并打包进 ROM 的系统级组件**，不是联通自己塞进去的第三方 APK。**这是本次分析最重要的发现。**
2. **代码全部混淆** —— 1.2 的 104 个可读类（`DeviceInfo`、`DeviceManager`、58 个厂商适配器）全部消失，被压进 `a0/a1/b/b1/c0/e1/f1/g0/g1/i` 等单字母包。
3. **接入百度定位 SDK** —— 新增 `liblocSDK8b.so`（368 KB）+ `libindoor.so`（1.6 MB），带百度 LBS API Key，做**连续 GPS 定位 + 室内定位 + WiFi 指纹**。
4. **采集重心从"设备注册"转向"网络质量路测"** —— 新增 `SigInfo` 报文，含 TAC/CID/PCI/ARFCN/Bands/CQI/RSRP/RSRQ/SINR/CSI/上下行速率/**掉话原因/数据失败原因/EPS Fallback**/经纬度/海拔/区县/速度/方位角/BSSID/SSID。
5. **删掉了最敏感的"手机号"** —— `MSISDN` 从 6 处引用降到 **0**，`getLine1Number()` 从 4 处降到 **0**。这是明确的合规收敛。
6. **采集频率大幅提高** —— 应用清单从 **7 天 → 24 小时**（7 倍），新增信号采集 **30 分钟**一次。

**关于反诈：没有接入。** 客户端里**零**反诈/公安/96110/举报相关代码、字符串、域名、SDK（详见 §10）。但它采集的数据（实时位置 + 基站 + WiFi BSSID + 应用使用 + 掉话原因）**恰好是反诈画像系统的理想输入** —— 客户端不判定，不代表上游不画像。

---

## 1. 样本档案（含签名变化）

| 项 | 1.2 | 3.0.1 |
|---|---|---|
| 包名 | `com.mobiletools.systemhelper` | 同左（未变） |
| versionName | `1.2-20220907` | `3.0.1-20260313` |
| versionCode | 3 | **34** |
| 文件大小 | 1,685,429 B | **3,831,041 B** |
| 条目数 | 408 | 410 |
| classes.dex | 2,662,204 B | **1,283,720 B**（-52%） |
| 原生库 | 无 | **2 个，共 1,965,464 B** |
| minSdk / targetSdk | 24 / 33 | **31 / 34** |
| MD5 | `8e9df43efd6d898f6db46053e69d37fb` | `9b68bd6b627a0e35b158a86e25ed9dc8` |
| SHA-256 | `416d0fc0405fc19b243e72f2a7963517e5b88991a7dfac494934449969a6015d` | `1de8d965e295db27e189aa179cdb45438d7f759cffbb43ce55f840b614ff6c65` |

### 1.1 签名证书：**换了主体，这是分水岭**

| | 1.2 | 3.0.1 |
|---|---|---|
| Subject / Issuer | `CN=NewDM, OU=RI, O=CU, L=BJ, ST=BJ, C=86` | `EMAILADDRESS=miui@xiaomi.com, CN=MIUI, OU=MIUI, O=Xiaomi, L=Beijing, ST=Beijing, C=CN` |
| 序列号 | `34a8a2c8` | `e552a8ecb9011b7c` |
| 有效期 | 2019-03-21 → 2069-03-08 | **2011-12-06 → 2039-04-23** |
| 公钥 | RSA 2048 | RSA 2048 |
| 签名算法 | SHA256withRSA | **SHA1withRSA**（弱，已被 Android 标记风险） |
| SHA-1 | `0D:0B:1F:90:18:23:91:C7:75:04:B8:43:DD:39:37:B2:3D:74:9A:E6` | `7B:6D:C7:07:9C:34:73:9C:E8:11:59:71:9F:B5:EB:61:D2:A0:32:25` |
| SHA-256 | `87:4B:8C:A2:…:DB:77` | `C9:00:9D:01:EB:F9:F5:D0:30:2B:C7:1B:2F:E9:AA:9A:47:A4:32:BB:A1:73:08:A3:11:1B:75:D7:B2:14:90:25` |
| 性质 | 联通内部自签**调试证书** | **MIUI 平台签名密钥**（系统应用级） |

**这意味着什么：**

- 1.2 是"联通做了个包，塞给厂商预装"—— 用的是自己 2019 年随手签的调试证书。
- 3.0.1 是"**小米用自己的平台密钥签发，并放进系统镜像**"—— 平台签名是 ROM 里最高等级的信任锚，持有它意味着可以申请 `signature` 级权限、可以进 `priv-app`、可以与系统应用共享 UID。
- 这解释了两件事：① 为什么 `READ_PRIVILEGED_PHONE_STATE`（仅系统/特权应用可得）能真正拿到 IMEI；② **为什么同款设备不分品牌都中招** —— 它不是装上去的，是**出厂就在系统分区里**。

> 平台签名证书 2011 年签发、有效期到 2039 年，是小米从 MIUI 早期沿用至今的同一把密钥。它出现在一个"联通设备注册"组件上，说明这条采集链路已经进入小米 ROM 的正式预装流程。

### 1.2 上报公钥：**完全没换**

```
1.2    pub.cer  md5=6f075caf6a089c091eabb73545787ca2  len=596
3.0.1  pub.cer  md5=6f075caf6a089c091eabb73545787ca2  len=596
```

同一张 `CN=UNICOM` 的 **1024 位 RSA** 证书（2019-05-24 → 2119-04-30）。**加密体系一行没改。**

---

## 2. 结构变化：从"半开源"到"全混淆 + 双原生库"

### 2.1 代码规模

| | 1.2 | 3.0.1 |
|---|---|---|
| `com.mobiletools.systemhelper` 下可读类 | **104 个** | **14 个** |
| 可读的核心类 | `DeviceInfo`(575行)、`DeviceManager`(733行)、`RegisterThread`、58 个 `DeviceInfoReader*` | 只剩 Receiver/Service 骨架，业务逻辑全在 `e1/*`、`f1/*`、`g1/*` |
| 唯一类型引用数 | 1,390 | 1,109 |
| 包名 | 语义化 | `a0 a1 b b1 c c0 c1 d d0 d1 e1 f0 f1 g g0 g1 h h0 i i0 j j0 m0 n n0 o q0 r0 s0 t0 u u0 w w0 x0 y z0` |

**意图很明确：让静态分析变贵。** 1.2 里可以直接读到 `DeviceInfo.getJsonString()` 的每个字段；3.0.1 里连 JSON 键名都要靠字节码里的 `const-string` 才能还原。

### 2.2 新增原生库

| 文件 | 大小 | 归属 | 作用 |
|---|---|---|---|
| `lib/arm64-v8a/liblocSDK8b.so` | 368,568 B | 百度定位 SDK 8.x | GPS/基站/WiFi 混合定位 |
| `lib/arm64-v8a/libindoor.so` | 1,596,896 B | 百度室内定位 | 室内坐标推算（商场/写字楼级精度） |

Manifest 里配套声明：

```xml
<meta-data android:name="com.baidu.lbsapi.API_KEY"
           android:value="IGY6EFGRsixbYqk7GeZdAOD2Od3Rj7iF"/>
<service android:name="com.baidu.location.f" android:enabled="true"
         android:process=":remote"/>
```

并且 `android:extractNativeLibs="false"` —— 直接从 APK 内加载 `.so`，减少落地痕迹。

### 2.3 第三方 SDK 清单（全量扫描）

| SDK | 3.0.1 | 1.2 | 说明 |
|---|---|---|---|
| 百度定位 `com/baidu` | **3 处** | 0 | 新增 |
| OkHttp | 9 处 | 9 处 | 未变 |
| 腾讯 / 阿里 / 友盟 / Bugly / 极光 / 个推 / 字节 / 快手 / 国密 / BouncyCastle | **0** | 0 | 均不存在 |

**结论：3.0.1 的第三方成分只有「百度定位 + OkHttp」，没有广告 SDK、没有推送 SDK、没有任何风控/反诈 SDK。**

### 2.4 1.2 的技术债被清理

以下 1.2 遗留全部消失（字符串计数 1.2 → 3.0.1）：

| 遗留物 | 1.2 | 3.0.1 | 说明 |
|---|---|---|---|
| `registerv3` | 2 | **0** | 接口版本换代 |
| `getRegisterLog` | 1 | **0** | 日志上报接口删除 |
| `eicp.net`（花生壳） | 1 | **0** | **开发联调域名已清除** |
| `chinaunicom` | 2 | **0** | SOAP 命名空间删除 |
| `bonc` | 1 | **0** | BONC 集成商接口删除 |
| `smsforward` / `derekjiang` | 1 | **0** | 那条未被调用的短信 App 筛选死代码已删 |

**这是 3.0.1 唯一明确"变好"的地方：把 1.2 里 4 个死端点和花生壳调试域名全部剪掉了。**

---

## 3. 权限与组件对比

### 3.1 权限：12 → 17，新增 5 项

| 权限 | 1.2 | 3.0.1 | 用途/风险 |
|---|---|---|---|
| `INTERNET` | ✅ | ✅ | — |
| `RECEIVE_BOOT_COMPLETED` | ✅ | ✅ | 开机自启 |
| `ACCESS_FINE_LOCATION` | ✅ | ✅ | 精确定位 |
| `ACCESS_COARSE_LOCATION` | ✅ | ✅ | 粗略定位 |
| `ACCESS_BACKGROUND_LOCATION` | ✅ | ✅ | **后台定位** |
| `READ_PHONE_STATE` | ✅ | ✅ | IMEI/IMSI |
| `READ_PRIVILEGED_PHONE_STATE` | ✅ | ✅ | **特权 IMEI（仅系统应用）** |
| `PACKAGE_USAGE_STATS` | ✅ | ✅ | **应用使用统计** |
| `QUERY_ALL_PACKAGES` | ✅ | ✅ | **枚举全部应用** |
| `READ_EXTERNAL_STORAGE` | ✅ | ✅ | — |
| `ACCESS_NETWORK_STATE` | ✅ | ✅ | — |
| `SCHEDULE_EXACT_ALARM` | ✅ | ✅ | 精确闹钟保活 |
| **`ACCESS_WIFI_STATE`** | ❌ | **✅ 新增** | 读 WiFi 连接信息 → **BSSID/SSID 定位** |
| **`CHANGE_WIFI_STATE`** | ❌ | **✅ 新增** | 可触发 WiFi 扫描 → **WiFi 指纹采集** |
| **`READ_PRECISE_PHONE_STATE`** | ❌ | **✅ 新增** | 精确电话状态 |
| **`ACCESS_LOCATION_EXTRA_COMMANDS`** | ❌ | **✅ 新增** | 额外定位指令（GNSS 原始数据） |
| **`FOREGROUND_SERVICE`** | ❌ | **✅ 新增** | 前台服务保活（定位常驻） |

> 新增的 5 项**全部服务于"更精准的定位"**：WiFi 状态 + 额外定位指令 + 前台服务 = 可以长时间后台跑百度定位。

### 3.2 组件：Receiver 5 → 7，Service 3 → 4

| 类型 | 1.2 | 3.0.1 新增 |
|---|---|---|
| Activity | `TestActivity`（exported） | 同左，**仍 exported**，权限请求扩展到 5 项 |
| Receiver | OnBoot / ScheduleRegister / AppInfoRegister / SIMState / ConnectState | **+ `SignalInfoRegisterReceiver`**（定时触发信号上报）<br>**+ `GetSignalInfoReceiver`**（触发百度定位 + 信号采集） |
| Service | RegisterHelperService / RegisterIntentService / RegisterJobService | **+ `com.baidu.location.f`（`:remote` 独立进程）** |

`TestActivity` 仍然是"导出且无权限保护"，任何应用可拉起它，它会弹权限框并把整包 JSON 显示在屏幕上 —— 这个调试后门**两个版本都没修**。

### 3.3 AIDL 远程控制面：**保留，且能力扩大**

`RegisterHelperService` 仍导出，仍由 `protectionLevel=0x2`（signature）保护，接口未变但 `setScheduleInterval` 现在**一处改动、七处生效**：

```java
public void a(int i2) {                       // setScheduleInterval
    l.D(ctx, i2);                 // scheduleInterval
    l.x(ctx, (i2*8)/5);           // appInfoInterval
    long j2 = (i2*4)/5;
    l.A(ctx, j2); l.z(ctx, j2); l.B(ctx, j2);   // 三个 4/5 的间隔
    l.F(ctx, (i2*6)/5);           // 6/5
    l.G(ctx, (i2*3)/5);           // 3/5
}
```

再加上 `c(String)` = `setServerAddress` 仍在 —— **同签名的任何预装应用（现在是"任何小米平台签名的系统应用"）都能改上报地址、改采集频率、清本地痕迹。** 签名从联通调试证书换成小米平台密钥后，**这个后门的可利用面反而变大了**（平台签名应用数量远多于联通内部签名应用）。

---

## 4. 3.0.1 采集了什么（新 JSON Schema）

从 `e1/b.b()` 的字节码里还原出完整字段顺序（`JSONObject.put` 调用序列）：

### 4.1 设备与双卡

```
Manuf, Model, HWVersion, SWVersion, OS, OSVersion,
IMEI1, ICCID1, IMSI1, MNC1, NetworkType1, TAC1, CID1, PCI1,
       VolteEnabled1, 5GEnabled1, VoNREnable1,
IMEI2, ICCID2, IMSI2, MNC2, NetworkType2, TAC2, CID2, PCI2,
       VolteEnabled2, 5GEnabled2, VoNREnable2,
DataSlot, BSSID, LinkSpeed, RSSI, Frequency, Esim, InactiveEsimMNC,
AccType, IPv6, SubType, DeviceType, RegType, SpecVersion="5.0",
ClientVersion="3.0.1", Time,
[SigInfo], [AppInfo]
```

| 字段 | 含义 | 敏感度 | vs 1.2 |
|---|---|---|---|
| `IMEI1/2` | 双卡 IMEI | **极高** | 不变 |
| `ICCID1/2` | SIM 卡序列号 | **极高** | 不变 |
| `IMSI1/2` | 用户标识 | **极高** | 不变 |
| `MNC1/2` | 运营商编码 | 中 | 不变 |
| `NetworkType1/2` | 网络制式（LTE/NR/NSA/SA…） | 中 | **替代** 1.2 的 `NCLS` |
| `TAC1/2` | 跟踪区码 | **高** | **新增**（替代 `LAC`） |
| `CID1/2` | 小区 ID | **高** | **新增**（替代 `CellID`） |
| `PCI1/2` | 物理小区 ID | 高 | **新增** |
| `VolteEnabled1/2` | VoLTE 状态 | 低 | 不变 |
| `5GEnabled1/2` | 5G 开关 | 低 | 不变 |
| `VoNREnable1/2` | VoNR（5G 通话）状态 | 低 | **新增** |
| `DataSlot` | 主数据卡槽 | 低 | 不变 |
| **`BSSID`** | **当前 WiFi 路由器的 MAC 地址** | **极高（可反查精确地址）** | **新增** |
| `LinkSpeed` | WiFi 协商速率 | 中 | **新增** |
| `RSSI` | WiFi 信号强度 | 中 | **新增** |
| `Frequency` | WiFi 频点 | 中 | **新增** |
| `Esim` | eSIM 状态 | 中 | **新增** |
| `InactiveEsimMNC` | 未激活 eSIM 的运营商 | 中 | **新增** |
| `AccType` | 接入类型 | 低 | 不变 |
| `IPv6` | 本机 IPv6 | 中 | 保留（`IPv4` 删除） |
| `SubType` | 厂商私有字段 | 低 | 不变 |
| `DeviceType` | 设备类型 | 低 | 不变 |
| `RegType` | 上报触发类型 | — | **新增取值 `R`** |
| `SpecVersion` | 协议版本 | — | **3.0 → 5.0** |
| `ClientVersion` | 客户端版本 | — | **新增，值 `3.0.1`** |
| `Time` | 时间戳 | — | 不变 |

### 4.2 被删掉的字段（重要）

| 字段 | 1.2 | 3.0.1 | 评价 |
|---|---|---|---|
| **`MSISDN1/2`（本机手机号）** | 有 | **无** | **合规收敛**。这是最敏感的字段，删掉是实质性改进 |
| `NCLS1/2` | 有 | 无 | 被 `NetworkType` 替代 |
| `CellID1/2` + `LAC1/2` | 有 | 无 | 被 `CID`/`TAC` 替代（同一信息，改名） |
| `IPv4` | 有 | 无 | 只留 IPv6 |
| `RegVersion` | 有 | 无 | 被 `ClientVersion` 替代 |
| **`History`（100 条补传队列）** | 有 | **无** | **取消批量历史补传**，改为 10 条本地队列逐条重试 |

> 代码级验证：
> ```
> MSISDN            1.2: 6 处  →  3.0.1: 0 处
> getLine1Number    1.2: 4 处  →  3.0.1: 0 处
> ```

---

## 5. `SigInfo`：新增的"路测级"报文字段（3.0.1 的核心新增）

`g1/n.java` 的 `a()` 构建这个对象，字段远超"设备注册"所需：

| 分类 | 字段 | 说明 |
|---|---|---|
| 标识 | `Time` `IMEI` `ICCID` `ClientVersion` `MNC` `IMSI` | 与主报文重复，便于独立入库 |
| 小区 | `TAC` `CID` `PCI` `NetworkType` | 精确到物理小区 |
| 射频 | `ARFCN` `Bands` `Bandwidth` | **频点、频段、带宽** |
| 信道质量 | `CQITableIndex` `CQIIndex` `RSRP` `RSRQ` `SINR` | 全套 LTE/NR 质量指标 |
| 波束 | `CSIRSRP` `CSIRSRQ` `CSISINR` | **5G 波束级 CSI 反馈** |
| 吞吐 | `Uspeed` `Dspeed` | 实时上下行速率 |
| **故障原因** | `CallDisconnectCause` `DataFailCause` `EPSFallback` | **掉话原因 / 数据连接失败原因 / 5G→4G 回落** |
| **位置** | `LONGITUDE` `LATITUDE` `ALTITUDE` `District` | **经纬度 + 海拔 + 区县** |
| 运动 | `SPEED` `BEARING` | 速度、方位角 |
| **WiFi** | `BSSID` `SSID` | **路由器 MAC + 名称** |

**这是运营商网络优化的"路测（drive test）"数据模型。** 正常做法是用专业路测设备+测试车采集；现在变成了**每一台普通用户的手机，每 30 分钟自动采一次，连经纬度和掉话原因一起上报**。

配套代码（`GetSignalInfoReceiver`）：用百度 `LocationClient` 以 `bd09ll` 坐标系、`Hight_Accuracy` 模式启动定位，拿到 `longitude/latitude/altitude/district` 后填入 `SigInfo`，并落库。

---

## 6. 触发频率：全面提速

| 采集项 | 1.2 | 3.0.1 | 变化 |
|---|---|---|---|
| 设备注册（`S` 定时） | 24 小时 | 24 小时 | 不变 |
| **应用清单（`A`）** | **7 天** | **24 小时** | **频率 ×7** |
| 信号信息（`R`） | 无 | **12 小时** | 新增 |
| **信号采集触发** | 无 | **30 分钟** | 新增 |
| 开机延迟 | 4 分钟 | 4 分钟 | 不变 |
| 换卡 / SIM 就绪延迟 | 6 分钟 | **3 分钟** | 更快触发 |
| 首次闹钟随机偏移 | 无 | **0–24 小时随机** | **新增反关联分析** |

`g1/d.java` 里的随机化：

```java
public static long f2660m = new Random().nextInt(86400000);  // AppInfo 首触发
public static long f2661n = new Random().nextInt(86400000);  // Schedule 首触发
public static long f2662o = new Random().nextInt(86400000);
```

**目的：让不同设备的首次上报时间离散化，避免在服务端形成"整点齐发"的特征，也避免被流量分析按固定周期识别。** 这是典型的对抗性设计，1.2 没有。

间隔常量（`g1/d.java`）：

```java
f2666s = 86400000L;   // 86400000  = 24h  scheduleInterval
f2667t = 86400000L;   // 86400000  = 24h  appInfoInterval（1.2 是 604800000 = 7 天）
f2668u = 43200000L;   // 43200000  = 12h  signalInfoInterval
f2669v = 1800000L;    // 1800000   = 30min GetsignalInfoInterval
f2670w = 3600000L;    // 3600000   = 1h
```

---

## 7. 传输与加密：**一行没改**

### 7.1 端点

| | 1.2 | 3.0.1 |
|---|---|---|
| 主接口 | `http://dm.wo.com.cn:18080/registerv3?ver=3.0` | `http://dm.wo.com.cn:18080/register?ver=5.0` |
| 其他 | `/public/ip`、`:6002/getRegisterLog`、`198.51.100.26` SOAP、`cnc-labs.eicp.net` | **全部删除** |

**端点收敛到 1 个，且仍是明文 HTTP**（`usesCleartextTraffic="true"` 保留）。

### 7.2 加密链路（`g1/c.java` 与 1.2 `Cryptography.java` 逐行等价）

```java
byte[] md5   = MD5(jsonString);                              // 16 字节，密钥
String sign  = URLEncode(Base64(RSA_pub(pub.cer, md5)));     // 128 字节
byte[] body  = AES/ECB/PKCS5Padding(jsonString, key=md5);
POST "…?ver=5.0&model=…&manuf=…&sign=…"  body=body
```

| 检查项 | 1.2 | 3.0.1 |
|---|---|---|
| AES 模式 | `AES/ECB/PKCS5Padding` | 同 |
| 密钥来源 | `MD5(明文)` | 同 |
| RSA 填充 | `RSA/ECB/PKCS1Padding` | 同 |
| 公钥 | `pub.cer`（1024-bit） | **同一文件，MD5 一致** |
| Content-Type | `application/encrypted-json` | 同 |
| 成功判定 | 200 或 **416** | 同 |

**结论：安全设计缺陷原样继承。** `sign` 仍然是用**公钥**加密 MD5（不是私钥签名），所以**任何解包 APK 的人都能伪造合法报文**，服务端零客户端认证。1024 位 RSA、ECB 模式、密钥=明文 MD5，四个问题一个没修。

### 7.3 上报前置条件（比 1.2 更严）

`e1/g.java:60-91` 的决策链：

```java
if (!isUserPermissionOpen) return false;        // ① 许可开关
if (bVar == null) return false;
if (!l.s(bVar)) return false;                   // ② MNC 必须在中国
if (网络已连接) {
    if (WiFi已连 && MNC在中国)  → 直接上报      // ③ WiFi 下不校验运营商
    else if (!漫游 && 联通网络) → 直接上报
} 
→ 上报失败：写入 SQLite（最多 10 条），下次重试
```

① **"用户许可"仍是个假开关**，但比 1.2「硬编码 `true`」稍微"讲究"了一点：

```java
public static boolean a(Context context) {          // g1/l.java:59
    boolean booted = Settings.Global.getInt(cr, "device_provisioned", 0) == 1;
    if (booted) return Settings.Secure.getInt(cr, "operator_service_improve_plan", 0) == 1;
    return false;
}
```

它读的是 **`Settings.Secure.operator_service_improve_plan`**（"运营商服务改进计划"）—— 这个值由**运营商/厂商在出厂时写入**，用户在设置界面里**看不到、也改不了**。名义上"已获用户同意"，实际上是"运营商默认帮我同意"。

> 结论：1.2 是"假装有许可"（常量 true），3.0.1 是"用系统开关假装有许可"。**两者都没有真实告知与同意。**

---

## 8. 本地存储

| | 1.2 | 3.0.1 |
|---|---|---|
| 数据库 | `databases/systemhelper` | 同 |
| 表 | `history` | **`dmregister`** |
| 上限 | **100 条** | **10 条** |
| 出队方式 | 全部读出塞进 `History` 字段一次性补传 | 每次取最旧一条，**读完即删** |
| 内容 | 完整上报 JSON 明文 | 同 |

源码（`g1/e.java:54-103`）：`b()` 插入前把行数裁到 10；`c()` 读最后一条并立即 `delete`。

**评价：从"攒够 100 条批量补传"改成"10 条滚动重试"，减小了本地残留，也取消了历史轨迹批量外发的通道。这是隐私上的实际改进。**

`shared_prefs/com_mobiletools_systemhelper_preference.xml` 保留，键包括：

```
scheduleInterval / appInfoInterval / signalInfoInterval / GetsignalInfoInterval
serverAddress / preference_enable_log / firstPowerOn
```

---

## 9. 版本对比总表

| 维度 | 1.2 | 3.0.1 | 判定 |
|---|---|---|---|
| **签名主体** | 联通自签 `CN=NewDM, O=CU` | **小米平台 `CN=MIUI, O=Xiaomi`** | **性质变化：从"预装第三方"变成"ROM 系统组件"** |
| **代码可读性** | 104 个语义化类 | 14 个类 + 全混淆 | 对抗分析 |
| **原生库** | 无 | 百度定位 ×2（1.96 MB） | 能力增强 |
| **权限** | 12 | 17（+WiFi/前台服务/精确定位指令） | 权限扩张 |
| **组件** | 5 Receiver / 3 Service | 7 Receiver / 4 Service | 能力扩张 |
| **端点** | 6 个（含 3 个死代码、1 个花生壳） | **1 个** | 收敛（改进） |
| **协议版本** | ver=3.0 / Spec 3.0 | ver=5.0 / Spec 5.0 / Client 3.0.1 | 换代 |
| **手机号 MSISDN** | 采集 | **不采集** | **改进（合规）** |
| **应用清单** | 包名/标签/前台分钟/分卡流量 | + **启动次数 `launchCount`** + `Time` | 增强 |
| **应用清单频率** | 7 天 | **24 小时** | **×7 提速** |
| **定位** | 基站 + 一次性 GPS | **百度连续定位 + 室内定位 + WiFi 指纹 + 海拔/区县/速度/方位** | **质变** |
| **RF 路测数据** | 无 | **SigInfo 全套（28 项）** | **新增** |
| **WiFi BSSID/SSID** | 无 | **有** | **新增（可反查门牌号）** |
| **eSIM** | 无 | `Esim` / `InactiveEsimMNC` | 新增 |
| **历史补传** | 100 条一次性 | 10 条滚动重试 | 改进 |
| **闹钟随机化** | 无 | **0–24h 随机偏移** | 对抗分析 |
| **加密** | AES-ECB + RSA1024 公钥"签名" | **完全相同** | **未修** |
| **传输** | 明文 HTTP | **明文 HTTP** | **未修** |
| **用户同意** | 硬编码 `true` | 读系统 `operator_service_improve_plan` | 换汤不换药 |
| **AIDL 后门** | `setServerAddress`/`setScheduleInterval` | 保留且影响 7 个间隔 | 未修，可利用面更大 |
| **调试 Activity** | 导出 | 仍导出 | 未修 |

---

## 10. 有没有接入"反诈系统"？—— 结论：**没有**

这是本次分析里最需要给出确定答案的问题。我从四个层面查证：

### 10.1 字符串层：零命中

对 `classes.dex` 做完整中文与英文关键词扫描：

| 关键词 | 命中 |
|---|---|
| `反诈` / `诈骗` / `公安` / `报警` / `举报` / `涉案` / `预警` / `拦截` / `黑名单` / `白名单` / `风控` / `画像` | **0** |
| `fanzha` / `anti-fraud` / `antifraud` / `96110` / `police` / `jubao` / `fraud` / `gov.cn` / `mps.gov` | **0** |

全 dex 只有 **26 条中文字符串**，3 条含关键词，且全是百度 SDK 的定位提示：

```
定位失败 / 定位成功 / 标签
```

其中"标签"来自百度 SDK 的报错文案：`AndroidManifest.xml的application中没有meta-data标签` —— 与"给设备打标签"毫无关系。

### 10.2 原生库层：零命中

对 `libindoor.so`（1.6 MB）与 `liblocSDK8b.so`（368 KB）扫描（ASCII + UTF-8 + UTF-16LE）：

| 关键词 | libindoor.so | liblocSDK8b.so |
|---|---|---|
| 反诈/公安/诈骗/报警 | 0 | 0 |
| fanzha/police/96110/jubao/fraud | 0 | 0 |
| 百度特征 | 150 / 279 | 18 |

### 10.3 网络层：只有 1 个端点

```
http://dm.wo.com.cn:18080/register     ← 唯一应用端点
```

其余 21 个 URL 全部是百度地图/定位服务。**没有任何指向公安、反诈中心、工信部、运营商风控平台的域名或 IP。**

### 10.4 能力层：没有"判定"与"处置"能力

真正的反诈客户端需要这些能力，3.0.1 **一项都没有**：

| 反诈客户端必备 | 3.0.1 是否具备 |
|---|---|
| 读取来电号码并比对黑名单 | ❌ 无 `READ_CALL_LOG`、无 `PHONE_STATE` 来电监听逻辑 |
| 拦截/挂断来电 | ❌ 无 `ANSWER_PHONE_CALLS`、无 `endCall` |
| 读取/过滤短信 | ❌ 无 `RECEIVE_SMS`、无 `READ_SMS`（1.2 里那条死代码也删了） |
| 扫描已装应用判定涉诈 App | ❌ 只上报包名，**不做任何判定** |
| 本地风险评分 | ❌ 无 |
| 弹窗预警 | ❌ 无任何 UI（唯一 Activity 是调试页） |
| 上报到公安/反诈平台 | ❌ 只上报到运营商 DM |
| 白名单/亲情号码 | ❌ 无 |

### 10.5 那这些数据能不能支撑反诈？

**能，而且是理想输入。** 必须诚实指出这一点：

| 3.0.1 采集 | 反诈画像的用途 |
|---|---|
| 实时经纬度 + 海拔 + 区县 + 速度 + 方位角 | 判断是否在诈骗高发区域、是否异常移动 |
| 基站 TAC/CID/PCI + WiFi BSSID/SSID | 精确定位到楼栋/门牌，识别"是否在涉诈窝点" |
| 应用清单 + 前台时长 + **启动次数** + 分卡流量 | 识别是否安装涉诈 App、是否被远程控制 |
| 双卡 IMEI/IMSI/ICCID | 设备-卡-人关联，识别"一机多卡""卡农" |
| **掉话原因 / 数据失败原因 / EPS Fallback** | 识别异常通信行为 |

**但要区分两件事：**

- **"客户端接了反诈"** = 客户端本地有判定逻辑、有拦截动作、有反诈平台通道 → **3.0.1 完全没有**
- **"数据被反诈系统消费"** = 上游把 DM 平台的采集数据接进风控/反诈模型 → **技术上完全可行，且从产品设计看非常可能**，但**这发生在服务端，客户端里看不到任何痕迹**

### 10.6 一句话回答

> **3.0.1 这个客户端里没有反诈系统。它是纯粹的"运营商网络质量 + 终端注册"采集器，采集能力比 1.2 强得多（尤其定位与 RF 数据），但没有任何判定、拦截、预警、举报逻辑，也不连接任何反诈平台。**
>
> **需要警惕的不是"它是不是反诈"，而是"它采的数据够不够做反诈画像" —— 答案是：够，而且很够。数据一旦离开设备，去向就不由用户决定了。**

---

## 11. 危害重估（3.0.1 相比 1.2）

### 变严重的部分

1. **定位精度质变**：1.2 只有基站级（百米~公里）；3.0.1 有 GPS + 室内定位 + WiFi BSSID 指纹 → **可到楼栋/楼层级**。BSSID 还能通过公开 WiFi 地理数据库反查到**具体门牌号**。
2. **采集频率质变**：应用清单 7 天 → 24 小时；新增 30 分钟一次的信令采集 → **一天 48 个位置点**，可还原完整活动轨迹。
3. **RF 数据可推断通话行为**：`CallDisconnectCause` / `DataFailCause` / `EPSFallback` 能反映用户何时通话、通话是否异常中断。
4. **反检测设计**：闹钟随机偏移 + 全代码混淆 + 原生库加载（`extractNativeLibs=false`）→ 更难被发现、更难被静态审计。
5. **签名等级提升 = 更难移除**：平台签名意味着它可以进 `priv-app`、可以与系统应用共享 UID。**用户层 `pm disable-user` 可能被系统保护机制拦下。**

### 变好的部分

1. **不再采集手机号**（MSISDN 归零）—— 这是最有价值的改进。
2. **删除 4 个死端点和花生壳调试域名** —— 供应链风险收敛。
3. **取消 100 条历史批量补传** —— 不再一次性外发历史轨迹。
4. **端点收敛到 1 个** —— 攻击面变小。

**净评价：隐私采集的"广度"略降（去掉手机号），"深度"和"频率"大幅上升（连续定位 + RF + 24h/30min），合规缺陷（明文 HTTP、假同意、AIDL 后门、调试页导出）一项未修。**

---

## 12. 处置（对 3.0.1 的调整）

包名未变（`com.mobiletools.systemhelper`），所以 [`kill_systemhelper.ps1`](../tools/kill_systemhelper.ps1) 仍可直接用。但有三处需要针对 3.0.1 补充：

### 12.1 先确认版本（区分 1.2 / 3.0.1）

```bash
adb shell dumpsys package com.mobiletools.systemhelper | findstr versionName
adb shell pm path com.mobiletools.systemhelper
```

- `versionName=3.0.1-20260313` → 本文档
- `versionName=1.2-20220907` → 前一份报告

### 12.2 新增权限要单独撤

```bash
adb shell pm revoke com.mobiletools.systemhelper android.permission.ACCESS_WIFI_STATE
adb shell pm revoke com.mobiletools.systemhelper android.permission.CHANGE_WIFI_STATE
adb shell pm revoke com.mobiletools.systemhelper android.permission.READ_PRECISE_PHONE_STATE
adb shell appops set com.mobiletools.systemhelper NEARBY_WIFI_DEVICES ignore
adb shell appops set com.mobiletools.systemhelper WIFI_SCAN ignore
```

### 12.3 百度定位服务要一起停

```bash
adb shell am force-stop com.mobiletools.systemhelper:remote
adb shell pm disable-user --user 0 com.mobiletools.systemhelper
```

### 12.4 平台签名的现实约束

3.0.1 由 **MIUI 平台密钥**签名，通常在 `/system/priv-app/` 或 `/product/priv-app/`。这种情况下：

| 手段 | 是否有效 |
|---|---|
| `pm disable-user --user 0` | 多数机型有效；部分 MIUI 版本会拦（返回 `SecurityException`） |
| `pm uninstall --user 0` | 有效，但**恢复出厂必复活** |
| 撤销运行时权限 | 有效 |
| **网络层拦截（NetGuard / 私有 DNS / 路由器 hosts）** | **最可靠**，因为它拦的是 `dm.wo.com.cn` 这个出口，与签名等级无关 |
| 刷机 | 唯一根治：刷**非定制版 MIUI/HyperOS 国际版**或 LineageOS |

> 对 3.0.1，网络层拦截的优先级应该提到第一位。原因：平台签名让它极难被彻底移除，而 DNS/防火墙拦截对签名等级完全免疫。

### 12.5 取证路径变化

数据库表名从 `history` 改成 `dmregister`，[`dump_evidence.ps1`](../tools/dump_evidence.ps1) 里的 SQL 需要同步改：

```sql
select jsonString from dmregister;
```

---

## 13. IOC（3.0.1 专用）

```
# 网络
http://dm.wo.com.cn:18080/register
dm.wo.com.cn

# 百度定位（第三方，非恶意但参与定位）
loc.map.baidu.com
ofloc.map.baidu.com
api.map.baidu.com
itsdata.map.baidu.com
parking.baidu.com
daup.map.baidu.com

# 包与组件
com.mobiletools.systemhelper
com.mobiletools.systemhelper.uid
com.mobiletools.systemhelper.permission
com.mobiletools.systemhelper.Activity.TestActivity
com.mobiletools.systemhelper.control.OnBootReceiver
com.mobiletools.systemhelper.control.SIMStateReceiver
com.mobiletools.systemhelper.control.ConnectStateReceiver
com.mobiletools.systemhelper.control.ScheduleRegisterReceiver
com.mobiletools.systemhelper.control.AppInfoRegisterReceiver
com.mobiletools.systemhelper.control.SignalInfoRegisterReceiver
com.mobiletools.systemhelper.control.GetSignalInfoReceiver
com.mobiletools.systemhelper.service.RegisterHelperService
com.mobiletools.systemhelper.service.IRegisterHelperService
com.mobiletools.systemhelper.service.RegisterIntentService
com.mobiletools.systemhelper.service.RegisterJobService
com.baidu.location.f

# 百度 LBS Key（可用于关联同批次设备）
IGY6EFGRsixbYqk7GeZdAOD2Od3Rj7iF

# 哈希
9b68bd6b627a0e35b158a86e25ed9dc8                                   # MD5
1de8d965e295db27e189aa179cdb45438d7f759cffbb43ce55f840b614ff6c65   # SHA-256
7B:6D:C7:07:9C:34:73:9C:E8:11:59:71:9F:B5:EB:61:D2:A0:32:25       # 签名 SHA-1（MIUI 平台）

# 本地数据
/data/data/com.mobiletools.systemhelper/databases/systemhelper   (表 dmregister，10 条)
/data/data/com.mobiletools.systemhelper/shared_prefs/com_mobiletools_systemhelper_preference.xml
```

---

## 14. 处置建议（一句话版）

**先跑 `adb shell dumpsys package com.mobiletools.systemhelper | findstr versionName` 确认版本；然后 `pm disable-user --user 0` + 撤 5 个新权限；最后在路由器或 NetGuard 里黑洞 `dm.wo.com.cn`——这一步对平台签名的组件同样有效，是唯一不依赖系统授权的手段。要彻底清除只能刷非定制固件。**

---

## 15. 结论回扣三个问题

**① 分析报告** → 本文档。3.0.1 是运营商终端注册 + 网络质量采集组件，用小米平台密钥签名，内置百度定位 SDK，采集双卡标识、精确位置、WiFi 指纹、应用画像、RF 路测数据。

**② 升级了什么** → 签名换成小米平台密钥（性质从"预装"变"系统组件"）；全代码混淆；接百度定位；新增 `SigInfo` 28 项 RF 数据；新增 WiFi BSSID/SSID 与 eSIM；应用清单频率 ×7；新增 30 分钟信令采集；闹钟随机化。同时删掉了手机号、4 个死端点、100 条历史补传。

**③ 有没有接反诈** → **没有。** 客户端零反诈代码、零反诈关键词、零反诈域名、零拦截能力。但它的数据模型（精确位置 + 基站 + WiFi + 应用 + 掉话原因）**足以支撑上游做反诈画像**——那是服务端的事，在 APK 里看不到，也不受用户控制。

---

## 16. 外部传闻核对

日文帖（[`@tanaka_yuto`，2026-11-02](https://x.com/tanaka_yuto/status/2117066492672110700)）与本版的对应关系已并入 [06-rumor-verification.md](06-rumor-verification.md)；3.0.1 的关键差异（MCC 门、MNC 白名单新增 `46010`、12 家厂商适配器）见该文 §10「三版差异速查」。

---

*本文为 **systemhelper** 研究集的一部分 · 许可 [CC BY 4.0](../LICENSE) · [返回目录](../README.md)*
