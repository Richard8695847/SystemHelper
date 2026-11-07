# SystemHelper 4.0.0 分析报告 · 三个版本横向对比 · 初衷判断

> 新增样本：`SystemHelper.apk` → **4.0.0-20260910**
> 对照样本：1.2-20220907、3.0.1-20260313
> 方法：jadx 1.4.7 反编译 + androguard 4.1.4 字节码/字符串分析 + 原生库扫描 + 证书/签名比对
> 日期：2026-11-07
>
> **关于文中出现的地址**：报告内的 IP 已替换为文档保留地址（`203.0.113.0/24`、`198.51.100.0/24`）；本地路径、主机名与设备标识已移除。域名保留，因为它们是被分析对象本身。

---

## 0. 结论先行

**4.0.0 是一次"技术债清理 + 能力再扩张"的混合版本。**

**它修掉了三个版本以来最严重的四个安全缺陷：**

| 缺陷 | 1.2 | 3.0.1 | 4.0.0 |
|---|---|---|---|
| 上报公钥强度 | RSA-**1024** | RSA-1024 | **RSA-2048**（`cudms_main_pub.cer`） |
| 对称加密 | AES-**ECB**，密钥=**MD5** | 同 | **AES-GCM**（认证加密），密钥=**SHA-256** |
| 传输协议 | 明文 HTTP | 明文 HTTP | **HTTPS `:18081` 为主** |
| 组件暴露 | 导出无保护 | 导出无保护 | **加 `signature` 权限保护** |

**但它同时把采集边界又往前推了一大步：**

| 新增 | 含义 |
|---|---|
| `BLUETOOTH` + `BLUETOOTH_CONNECT` | 枚举**已配对蓝牙设备名称 + MAC** |
| `PairedDevice` / `PairedMacAddress` | 上报用户连过的所有蓝牙设备（车机、手表、耳机、另一台手机） |
| `SatelliteSupport` / `SatelliteEnabled` | 是否支持/开启**卫星通信**（天通、北斗短报文） |

**并且引入了一个新的严重缺陷：**

> `HTTPS fail by cert invalid, trigger HTTP fallback!`
>
> **证书校验失败时，自动降级到明文 HTTP `:18080` 重发。** 这意味着任何能实施 SSL 拦截的网络（企业 WiFi、校园网、公共热点、透明代理）都能把这条链路打回明文——**TLS 加了个寂寞**。

---

## 1. 三个版本横向总表

| 维度 | 1.2（2022-09） | 3.0.1（2026-03） | 4.0.0（2026-09） |
|---|---|---|---|
| 包名 | `com.mobiletools.systemhelper` | 同 | 同 |
| versionName | `1.2-20220907` | `3.0.1-20260313` | **`4.0.0-20260910`** |
| versionCode | 3 | 34 | **34（未递增）** |
| 文件大小 | 1,685,429 B | 3,831,041 B | 3,884,625 B |
| 条目数 | 408 | 410 | **535** |
| dex 大小 | 2,662,204 B | 1,283,720 B | 1,290,656 B |
| minSdk / targetSdk | 24 / 33 | 31 / 34 | 31 / 34 |
| **签名主体** | `CN=NewDM, O=CU`（联通自签） | **`CN=MIUI, O=Xiaomi`（小米平台）** | `CN=NewDM, O=CU`（联通自签） |
| 签名方案 | v1 + v2 | v1 + v2 | **仅 v2** |
| **上报公钥** | `pub.cer` RSA-1024 | `pub.cer` RSA-1024（同文件） | **`cudms_main_pub.cer` RSA-2048** |
| 公钥有效期 | 2019-05-24 → 2119 | 同 | **2024-11-04 → 2124-10-11** |
| **对称加密** | AES/**ECB**/PKCS5 | AES/**ECB**/PKCS5 | **AES/GCM/NoPadding** |
| **密钥派生** | **MD5**(明文) 16B | **MD5**(明文) 16B | **SHA-256**(明文) 32B |
| **传输** | HTTP `:18080` | HTTP `:18080` | **HTTPS `:18081`** + HTTP `:18080` 回退 |
| **协议版本** | `ver=3.0` / Spec `3.0` | `ver=5.0` / Spec `5.0` | **`ver=6.0` / Spec `6.0`** |
| ClientVersion 字段 | `RegVersion`=`1.2-…` | `ClientVersion`=`3.0.1` | `ClientVersion`=`4.0.0` |
| 端点数 | 6（含 3 个死代码） | **1** | **2**（HTTPS + HTTP） |
| 权限数 | 12 | 17 | **19**（3.0.1 的 17 项 + `BLUETOOTH` + `BLUETOOTH_CONNECT`） |
| Receiver | 5 | 7 | 7 |
| Service | 3 | 4 | 4 |
| 原生库 | 无 | 百度 ×2（1.96 MB） | 百度 ×2（1.96 MB） |
| 混淆 | 否（104 个可读类） | 是（14 个） | 是（14 个） |
| 应用清单频率 | 7 天 | 24 小时 | 24 小时 |
| 信令采集频率 | 无 | 30 分钟 | 60 分钟 |
| 本地队列 | `history` 100 条 | `dmregister` 10 条 | `dmregister` 10 条 |
| **手机号 MSISDN** | **采集** | 不采集 | **不采集** |
| **蓝牙配对设备** | 无 | 无 | **采集** |
| **卫星通信状态** | 无 | 无 | **采集** |
| **反诈功能** | 无 | 无 | **无** |

---

## 2. 4.0.0 的变化详解

### 2.1 安全加固（真实的进步）

#### ① RSA 1024 → 2048

```
1.2 / 3.0.1 : assets/pub.cer          596 B   RSA-1024   CN=UNICOM   2019→2119
4.0.0       : assets/cudms_main_pub.cer  857 B   RSA-2048   CN=UNICOM   2024→2124
```

文件名 `cudms_main_pub.cer` 直接点明了系统身份：**CU-DMS = China Unicom Device Management System（中国联通设备管理系统）**。这是这套东西的真名——之前藏在通用名 `pub.cer` 后面，现在不藏了。

#### ② AES-ECB → AES-GCM

```java
// g1/c.java —— 4.0.0
byte[] bArr2 = new byte[16];
System.arraycopy(bArr, 0,  bArr2, 0, 8);    // IV[0..7]  = key[0..7]
System.arraycopy(bArr, 24, bArr2, 8, 8);    // IV[8..15] = key[24..31]
GCMParameterSpec spec = new GCMParameterSpec(128, bArr2);   // 128-bit tag
SecretKeySpec key = new SecretKeySpec(bArr, "AES");
Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
cipher.init(Cipher.ENCRYPT_MODE, key, spec);
return cipher.doFinal(str.getBytes("utf-8"));
```

对比 3.0.1 的 `AES/ECB/PKCS5Padding` —— **ECB 的块重放与统计分析攻击被彻底封堵**，GCM 还提供完整性认证。

**但 IV 的构造有问题**：IV 直接取密钥的第 0–7 与第 24–31 字节。密钥 = SHA-256(明文)，而明文 = 整个 JSON。**同一份 JSON 会得到同一把密钥、同一个 IV、同一份密文** —— 这跟 ECB 的"确定性加密"缺陷在效果上是一样的，只是不再是块级可分析。GCM 模式下重复 IV 还会导致**认证密钥泄露（forbidden attack）**。所以这一步是"从很差改到没那么差"，不是"改对了"。

#### ③ 密钥派生 MD5 → SHA-256

```java
public static byte[] c(String str) {
    return MessageDigest.getInstance("SHA-256").digest(str.getBytes("UTF-8"));
}
```

MD5 换 SHA-256，同时把 AES 从 128 位升到 256 位。方向正确。**但"密钥=明文哈希"这个根本设计没变** —— 仍然是自指闭环：密钥从明文派生，明文就在密文里。服务端能解，靠的是 RSA 私钥解 `sign` 拿到摘要。

#### ④ 组件暴露加固

三个版本第一次出现 `android:permission` 保护：

```xml
<activity android:name="...TestActivity"
          android:permission="com.mobiletools.systemhelper.permission"
          android:exported="true"/>
<receiver android:name="...OnBootReceiver"
          android:permission="com.mobiletools.systemhelper.permission"
          android:exported="true"/>
<service  android:name="...RegisterHelperService"
          android:permission="com.mobiletools.systemhelper.permission"
          android:exported="true"/>
```

`com.mobiletools.systemhelper.permission` 的 `protectionLevel=0x2`（**signature**），所以只有同签名应用能拉起/调用。**这条把 1.2/3.0.1 里"任意应用可拉起 TestActivity 看整包 JSON、可调 AIDL 改上报服务器地址"的洞堵上了。**

> 仍有残留：`SIMStateReceiver` 与 `ConnectStateReceiver` 还是 `exported="true"` 且无权限保护（因为它们要接系统广播）。恶意应用可以伪造 `SIM_STATE_CHANGED` / `CONNECTIVITY_CHANGE` 广播，**触发一次额外采集**。危害有限（只是加频），但没修干净。

#### ⑤ 清理死依赖与死端点

- 1.2 的 4 个死端点（`/public/ip`、`/getRegisterLog`、BONC SOAP、花生壳 `cnc-labs.eicp.net`）—— 3.0.1 已删，4.0.0 继续干净
- 4.0.0 新增的 `org/apache/commons/codec`（语音算法 Metaphone/Soundex 等）**是死依赖**：全项目零引用（`grep` 无命中），只是打包时被带进来的

### 2.2 新增的能力（扩张）

#### ① 蓝牙已配对设备采集 —— 本次最值得注意的新增

```java
// f1/a.java:53-81
Set<BluetoothDevice> bondedDevices = defaultAdapter.getBondedDevices();
if (bondedDevices.size() > 0) {
    StringBuilder sb  = new StringBuilder();   // 设备名
    StringBuilder sb2 = new StringBuilder();   // MAC 地址
    for (BluetoothDevice d : bondedDevices) {
        String name = d.getName();
        String address = d.getAddress();
        if (name    != null && !name.isEmpty())    { if (sb.length()  > 0) sb.append(", ");  sb.append(name); }
        if (address != null && !address.isEmpty()) { if (sb2.length() > 0) sb2.append(", "); sb2.append(address); }
    }
    str2 = sb.toString();
    str  = sb2.toString();
}
```

上报字段：`PairedDevice`（名称串）、`PairedMacAddress`（MAC 串）。

**这为什么重要：**

- 蓝牙 MAC 是**硬件级唯一标识**，比 IMEI 更难伪造、更难重置。
- 已配对设备列表能反推出用户的**设备生态**：车机（判断有没有车、什么车）、智能手表（判断健康监测）、耳机、另一台手机（判断双机/工作机分离）。
- 蓝牙 MAC 还能与**其他采集源做跨库关联**——同一个耳机 MAC 出现在两台手机的配对列表里，就能判定"这两个人长期在一起"。

**这是从"设备画像"跨到"关系画像"的一步。**

#### ② 卫星通信状态

```
SatelliteSupport   —— 是否支持卫星通信
SatelliteEnabled   —— 卫星通信是否开启
```

对应 2024 年后旗舰机（天通卫星、北斗短报文）的能力位。单独看不敏感，但它是一个**高价值机型/高价值用户标记**：能买得起支持卫星通信机型的人，消费能力画像直接高一档。

#### ③ 新增权限

```xml
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<uses-permission android:name="android.permission.BLUETOOTH"/>
```

`BLUETOOTH_CONNECT` 在 Android 12+ 是**运行时权限**，会弹窗。也就是说 4.0.0 第一次需要用户主动点"允许"才能拿到蓝牙数据 —— 这是它唯一一次必须向用户请求权限。

#### ④ 关于 versionCode 未递增

`3.0.1` 和 `4.0.0` 的 `versionCode` **都是 34**。

这不正常。正常发版必须递增 versionCode，否则无法覆盖安装/无法被应用市场识别为升级。合理解释只有两种：

1. 这是**内部构建/测试包**，不是正式发版（`-20260910` 是日期后缀，符合内部构建命名）
2. 构建流程有缺陷，靠 versionName 区分

结合 `4.0.0-20260910` 是 2026 年 9 月的日期、而现在是 2026 年 11 月 —— 这个包很新，可能刚出厂不久。

### 2.3 传输层：TLS 与它的"后门"

```java
// e1/g.java 字节码
"?ver="  "6.0"  "&model="  "&manuf="  "&sign="
"HTTPS request exception--->"
"HTTPS fail by cert invalid, trigger HTTP fallback!"
"?ver=6.0&model="  "&manuf="  "&sign="
"HTTP fallback request exception--->"
```

```java
// g1/d.java:43,46
public static String f2656l = "https://dm.wo.com.cn:18081/register";   // 主
public static String f2657m = "http://dm.wo.com.cn:18080/register";    // 回退
```

**逻辑：先走 HTTPS `:18081`，若证书校验失败 → 自动改用明文 HTTP `:18080` 重发。**

这是**教科书级的降级漏洞（downgrade attack）**：

| 场景 | 结果 |
|---|---|
| 家庭 WiFi / 4G/5G 直连 | HTTPS 正常，加密传输 ✅ |
| 企业 WiFi 做 SSL 解密 | 证书不匹配 → **降级明文** ❌ |
| 校园网 / 酒店 / 机场热点 | 可能劫持证书 → **降级明文** ❌ |
| 攻击者 ARP 欺骗 + 假证书 | 主动触发降级 → **拿到完整明文** ❌ |

而"证书校验失败就降级"这个设计，等于**把"防中间人"变成了"欢迎中间人"**。正确的做法是证书校验失败就拒绝发送，而不是退回明文。**这条缺陷抵消了 4.0.0 加密升级的一大半价值。**

---

## 3. 三层能力演进：它到底在做什么

把三个版本的字段按"业务目的"重新归类，演进路径非常清晰：

### 第一层：设备身份（1.2 就有，三版未变）

```
IMEI1/2 · ICCID1/2 · IMSI1/2 · MNC1/2 · Manuf · Model · HWVersion · SWVersion · OS · OSVersion
```

**目的：** 唯一识别"这台设备 + 这张卡"。
**业务正当性：** ✅ 终端注册、入库、窜货管理确实需要这些。

### 第二层：网络质量（3.0.1 大幅强化）

```
NetworkType · TAC · CID · PCI · RSRP · RSRQ · SINR · CSI* · ARFCN · Bands · Bandwidth · CQI
CallDisconnectCause · DataFailCause · EPSFallback · Uspeed · Dspeed
```

**目的：** 运营商网络优化（覆盖评估、掉话定位、5G 驻留率）。
**业务正当性：** ✅ 这是运营商真实业务，原本靠路测车和专业设备采集。

### 第三层：人的画像（1.2 埋种子，3.0.1 成型，4.0.0 完成）

```
【行为】AppInfo: 包名 · 应用名 · 前台分钟 · 启动次数 · 分卡/WiFi 上下行流量
【位置】LONGITUDE · LATITUDE · ALTITUDE · District · SPEED · BEARING
        BSSID · SSID · LinkSpeed · RSSI · Frequency
【关系】PairedDevice · PairedMacAddress（蓝牙配对生态）
【消费力】SatelliteSupport / SatelliteEnabled · DeviceType · Model
```

**目的：** 给"人"建模。
**业务正当性：** ⚠️ **与终端注册无关，与网络优化也无关。**

**这一层是三个版本里唯一持续扩张、从未收敛的部分。**

> 对照：真正收敛的是 `MSISDN`（手机号）——3.0.1 起彻底删除。这说明开发方清楚"手机号"是红线（《个人信息保护法》第 28 条敏感个人信息），但**没有同样对待位置、应用清单、蓝牙配对**。这不是"不懂合规"，是**选择性合规**：删掉最容易被抓的，保留最有商业价值的。

---

## 4. 反诈问题：三个版本统一结论 —— **没有**

对 4.0.0 的 dex 与两个原生库重复了 3.0.1 的四层扫描：

| 层面 | 检查内容 | 结果 |
|---|---|---|
| 字符串 | `反诈/诈骗/公安/报警/举报/涉案/预警/拦截/黑名单/白名单/风控/画像` | **0** |
| 英文标识 | `fanzha/anti-fraud/antifraud/96110/police/jubao/fraud/gov.cn/mps.gov` | **0** |
| 原生库 | `libindoor.so` + `liblocSDK8b.so` 同项扫描（ASCII/UTF-8/UTF-16LE） | **0** |
| 网络 | 全 dex URL | 仅 `dm.wo.com.cn:18081/18080` + 百度地图 21 个 |
| 能力 | 来电监听 / 短信读取 / 拦截挂断 / 风险评分 / 预警弹窗 / 举报通道 | **全部没有** |
| 第三方 SDK | 全量包名扫描 | 仅 **百度定位 + OkHttp**（`commons-codec` 为死依赖） |

**三版一致：客户端不具备任何反诈功能。**

**但必须说清楚"没有"的边界：**

- ✅ 客户端**没有**反诈判定、拦截、预警、举报
- ✅ 客户端**没有**连接任何反诈/公安平台
- ❌ **不能**由此推断"它的数据没被反诈系统使用" —— 数据一旦到 `dm.wo.com.cn`，服务端怎么用，APK 里看不到

而这个数据包**恰好是反诈画像的理想输入**：

| 采集项 | 反诈用法 |
|---|---|
| 连续经纬度 + 区县 + 速度 + 方位 | 判断是否滞留诈骗高发区、是否异常移动 |
| 基站 TAC/CID/PCI + WiFi BSSID/SSID | 定位到楼栋/楼层，识别"窝点" |
| 应用清单 + 启动次数 + 分卡流量 | 识别涉诈 App、识别"被远程控制" |
| 双卡 IMEI/IMSI/ICCID | 一机多卡、卡农识别 |
| 蓝牙配对设备 | 团伙关联（同一设备出现在多人列表中） |
| 掉话原因 / 数据失败原因 | 异常通信行为 |

**结论：反诈不是这个客户端的功能，但它是这个数据集的"天然下游用途"之一。**

---

## 5. 设计意图分析

> **本章的证据分层**：5.2–5.4 的每一条都出自代码、清单或证书，属 **事实层**；5.5 是 **推断层**，三种强度的表述分别标注了依据边界。两层请分开读。

### 5.1 能证明的 / 不能证明的

| 能证明（代码里有） | 不能证明（在服务端） |
|---|---|
| 采集哪些字段、多高频 | 数据存多久 |
| 数据发到哪台服务器 | 卖给谁、给谁看 |
| 用什么加密 | 是否并入风控 / 反诈 / 征信模型 |
| 有没有同意机制 | 是否有司法调取通道 |
| 有没有关闭开关 | 决策者是谁 |

下面的判断只建立在"客户端设计"这一层——而设计本身就是意图的证据。

### 5.2 第一层：它的业务内核是真实的

不能一棍子打死。"终端注册"和"网络优化"是运营商真实存在的业务：

- 工信部对入网终端有 IMEI 核验要求 → 需要 IMEI + ICCID + 制式
- 运营商要评估覆盖、定位掉话 → 需要 RSRP/RSRQ/SINR/CID/TAC
- 5G/VoLTE 开通率考核 → 需要 `5GEnabled` / `VolteEnabled`
- 定制机补贴核销、窜货管理 → 需要机型 + 销售地

`cudms_main_pub.cer` 这个名字（CU-DMS，联通设备管理系统）也印证了这层身份。**这部分是正当的，本报告不否认。**

### 5.3 第二层：但"注册"解释不了它采的东西

这是关键。**注册只需要 5 个字段：IMEI、ICCID、MNC、机型、制式。**

它实际采了 **40+ 个字段**，其中至少 20 个与注册无关：

| 字段 | 注册需要吗 | 网络优化需要吗 | 那它为什么在这 |
|---|---|---|---|
| 应用清单 + 前台时长 + **启动次数** | ❌ | ❌ | 用户行为画像 |
| 分卡 / 分 WiFi 流量 | ❌ | ❌ | 用户行为画像 |
| 连续经纬度（一天数十次） | ❌ | ⚠️ 采样即可，无需连续 | 轨迹追踪 |
| **WiFi BSSID / SSID** | ❌ | ❌ | 室内定位到门牌 |
| **蓝牙配对设备 + MAC** | ❌ | ❌ | 社交关系图谱 |
| **卫星通信能力位** | ❌ | ❌ | 消费力分层 |
| 掉话原因 / 数据失败原因 | ❌ | ✅ | 网络优化（这条正当） |

**一个"设备注册"模块，没有任何技术理由需要知道用户装了微信还是某个借贷 App、每天用多久、连过哪副耳机、常去哪栋楼。**

### 5.4 第三层：设计选择指向"不被看见"

技术选型不会说谎。这套东西的每一个工程决策，都指向"让它不被发现、不被关闭、不被审计"：

| 设计选择 | 如果是"正常业务"，应该怎么做 | 实际怎么做 | 指向 |
|---|---|---|---|
| 无界面 | 有设置页、有开关 | **零 UI**，唯一 Activity 是调试页 | 让用户无从知晓 |
| 无同意 | 首次启动弹隐私政策 | 读系统 `operator_service_improve_plan`（用户看不见也改不了） | 以默认值代替同意 |
| 无退出 | 提供关闭入口 | **完全没有** | 让用户无从拒绝 |
| 开机自启 | 用户打开才运行 | 开机延迟 4 分钟自动跑 | 让行为不易被察觉 |
| 定时上报 | 事件触发 | 24h/60min 定时 + **0–24h 随机抖动** | 规避周期分析 |
| 代码混淆 | 正常混淆即可 | 1.2 完全可读 → 3.0.1/4.0.0 **全量混淆到单字母** | 抬高审计成本 |
| 本地留存 | 可查 | 从 100 条缩到 10 条，**读完即删** | 减少取证痕迹 |
| 签名等级 | 普通签名 | 3.0.1 用**小米平台密钥** | 让系统层面难以移除 |
| 远程可控 | 固定配置 | **AIDL 可远程改服务器地址、改采集频率** | 服务端可随时调度 |

**这九条里，没有一条能用"方便用户"或"提高注册成功率"解释。**

尤其"随机抖动"和"读完即删"——**只有需要降低可见性的设计，才需要随机化时间、才会抹掉本地痕迹。**

### 5.5 三种强度的表述（推断层）

**A. 保守表述**（有法条与代码双重支撑，可直接引用）

> 这是一个运营商终端数据采集组件，业务上覆盖设备注册与网络质量监测，但实现中采集范围明显超出业务必要限度，且缺少告知同意与退出机制。

**B. 中间表述**（技术人员口径）

> 它的数据模型不是"设备"，是"人"。注册字段只占四分之一，其余是行为、位置、关系与消费力。这套 schema 服务的是**用户画像**，注册只是它合法存在的壳。

**C. 最强表述**（明确标注为推断，需读者自行判断）

> 它是一套以"设备注册"为名义、预装在系统分区、用户无法关闭也无法卸载的位置与行为采集基础设施。

> **边界声明**：C 属于推断。关于数据去向——位置洞察与客流分析类大数据产品在业内确有商业化先例；应用清单 + 位置 + 消费力的组合在广告投放中价值很高；监管与风控侧是"反诈"叙事最常见的落点。**这三点都只是可能性推断：本报告没有任何证据表明该数据集已被出售、共享或用于上述任一用途。**

### 5.6 三条"降温"事实

1. **没有证据表明它在做实时监听。** 它不读短信、不读通话记录、不录音、不截屏、不读通讯录。采集是**周期性快照**，不是持续监听流。
2. **没有证据表明数据被泄露或贩卖。** 传输虽有缺陷（明文回退），但目标服务器是联通自己的域名，不是第三方。
3. **它有真实的合法内核。** 网络优化那部分数据（RSRP/CID/掉话原因）确实是运营商该采的，只是不该采这么多、不该这么采。

所以准确的定位不是"间谍软件"，而是：

> **合法业务内核 + 显著超出必要范围的采集外延 + 刻意降低可见性的实现方式。** 风险不在它今天做了什么，而在于它被设计成"能做什么，而用户无从得知、无法拒绝、无法审计"。

### 5.7 一句话

> **它的本意更接近"用户数据入口"，而不是"设备注册工具"。注册是壳，画像是核。**
>
> 最值得警惕的不是它采了什么，而是它被设计成：看不见、关不掉、删不掉、审计不了——而这四条，恰恰是《个人信息保护法》第 44–47 条明确赋予用户的知情权、决定权、查阅复制权与删除权。

---

## 6. 处置（4.0.0 版更新）

### 6.1 三个版本共用一套流程

包名三版一致（`com.mobiletools.systemhelper`），[`kill_systemhelper.ps1`](../tools/kill_systemhelper.ps1) 仍可用。先确认版本：

```bash
adb shell dumpsys package com.mobiletools.systemhelper | findstr versionName
adb shell pm path com.mobiletools.systemhelper
```

| versionName | 对应版本 |
|---|---|
| `1.2-20220907` | 1.2 |
| `3.0.1-20260313` | 3.0.1 |
| `4.0.0-20260910` | 4.0.0 |

### 6.2 ⚠️ 4.0.0 必须同时封两个端口

这是本次最重要的处置变化。**只封 18080 不够**——4.0.0 主用 18081（HTTPS），且证书失败会自动退回 18080。

```
dm.wo.com.cn            # 域名，两个端口都覆盖
dm.wo.com.cn:18081      # HTTPS 主通道
dm.wo.com.cn:18080      # HTTP 回退通道（必须一起封）
```

路由器 hosts / NetGuard 规则里，**按域名封最稳**（`dm.wo.com.cn` 一次覆盖 18080+18081）。

### 6.3 新增权限要一起撤

```bash
# 4.0.0 新增
adb shell pm revoke com.mobiletools.systemhelper android.permission.BLUETOOTH_CONNECT
adb shell appops set com.mobiletools.systemhelper BLUETOOTH_CONNECT ignore

# 3.0.1 起新增（仍在）
adb shell pm revoke com.mobiletools.systemhelper android.permission.ACCESS_WIFI_STATE
adb shell pm revoke com.mobiletools.systemhelper android.permission.CHANGE_WIFI_STATE
adb shell pm revoke com.mobiletools.systemhelper android.permission.READ_PRECISE_PHONE_STATE
```

### 6.4 停用（4.0.0 组件已加签名权限，但仍需停进程）

```bash
adb shell am force-stop com.mobiletools.systemhelper
adb shell am force-stop com.mobiletools.systemhelper:remote    # 百度定位进程
adb shell pm disable-user --user 0 com.mobiletools.systemhelper
```

### 6.5 取证脚本要改表名

表名三版都是 `systemhelper` 库，但：

- 1.2：表 `history`，上限 100
- 3.0.1 / 4.0.0：表 `dmregister`，上限 10

[`dump_evidence.ps1`](../tools/dump_evidence.ps1) 里的 SQL 需按版本改：

```sql
-- 3.0.1 / 4.0.0
select jsonString from dmregister;
-- 1.2
select jsonString from history;
```

### 6.6 4.0.0 的处置难度评估

| 手段 | 1.2 | 3.0.1 | 4.0.0 |
|---|---|---|---|
| 撤销权限 | 有效 | 有效 | 有效（含蓝牙） |
| `disable-user` | 有效 | 部分被拦 | 部分被拦 |
| 卸载当前用户 | 有效 | 有效，恢复出厂复活 | 同 |
| 组件调用 | 任意应用可调 | 任意应用可调 | **已被签名权限封堵**（改进） |
| **网络拦截** | 最有效 | 最有效 | **最有效（且必须双端口）** |

---

## 7. IOC（三版本汇总）

```
# ===== 网络 =====
dm.wo.com.cn
http://dm.wo.com.cn:18080/register          # 1.2/3.0.1 主；4.0.0 回退
https://dm.wo.com.cn:18081/register         # 4.0.0 主
（历史，已移除）dm.wo.com.cn:6002/registerv3/getRegisterLog
（历史，已移除）198.51.100.26:8080/bonc_Register/RegisterPort
（历史，已移除）cnc-labs.eicp.net:8080/registerService/web/getRegister

# ===== 百度定位（第三方）=====
loc.map.baidu.com / ofloc.map.baidu.com / api.map.baidu.com
itsdata.map.baidu.com / parking.baidu.com / daup.map.baidu.com
com.baidu.lbsapi.API_KEY = IGY6EFGRsixbYqk7GeZdAOD2Od3Rj7iF

# ===== 组件 =====
com.mobiletools.systemhelper
com.mobiletools.systemhelper.uid
com.mobiletools.systemhelper.permission
com.mobiletools.systemhelper.Activity.TestActivity
com.mobiletools.systemhelper.control.{OnBootReceiver,SIMStateReceiver,ConnectStateReceiver,
    ScheduleRegisterReceiver,AppInfoRegisterReceiver,SignalInfoRegisterReceiver,GetSignalInfoReceiver}
com.mobiletools.systemhelper.service.{RegisterHelperService,IRegisterHelperService,
    RegisterIntentService,RegisterJobService}
com.baidu.location.f

# ===== 三版本哈希 =====
1.2    MD5 8e9df43efd6d898f6db46053e69d37fb
       SHA256 416d0fc0405fc19b243e72f2a7963517e5b88991a7dfac494934449969a6015d
3.0.1  MD5 9b68bd6b627a0e35b158a86e25ed9dc8
       SHA256 1de8d965e295db27e189aa179cdb45438d7f759cffbb43ce55f840b614ff6c65
4.0.0  MD5 11ee024eb1a9fe68a9c403a23c882fd0
       SHA256 42fbfebedd8711b2ca22d3d969324f7ed7c757d838e143bf6cf4d2e8e1ed8556

# ===== 签名证书 =====
1.2/4.0.0  CN=NewDM, OU=RI, O=CU, C=86
           SHA1 0D:0B:1F:90:18:23:91:C7:75:04:B8:43:DD:39:37:B2:3D:74:9A:E6
3.0.1      CN=MIUI, O=Xiaomi（小米平台密钥）
           SHA1 7B:6D:C7:07:9C:34:73:9C:E8:11:59:71:9F:B5:EB:61:D2:A0:32:25

# ===== 上报公钥证书 =====
1.2/3.0.1  assets/pub.cer            RSA-1024  MD5 6f075caf6a089c091eabb73545787ca2
4.0.0      assets/cudms_main_pub.cer RSA-2048  MD5 4184ae3c9efdc1eff60178a63b8d3da9

# ===== 本地数据 =====
/data/data/com.mobiletools.systemhelper/databases/systemhelper
    ├─ 1.2          : 表 history，上限 100
    └─ 3.0.1/4.0.0  : 表 dmregister，上限 10
/data/data/com.mobiletools.systemhelper/shared_prefs/com_mobiletools_systemhelper_preference.xml
```

---

## 8. 结论

**三个版本放在一起看，画像非常清楚：**

- **1.2** 是"能跑就行"的草稿：可读代码、明文 HTTP、1024 位 RSA、ECB、手机号、100 条历史、花生壳调试域名还留在包里。
- **3.0.1** 是"藏起来 + 加强采集"：全量混淆、接百度定位、加 RF 路测、换小米平台签名、频率 ×7、加随机抖动。
- **4.0.0** 是"补安全债 + 再扩一环"：RSA-2048、AES-GCM、SHA-256、HTTPS、组件权限加固（**这四项是真进步**）；同时加蓝牙配对设备、加卫星能力位、加 HTTP 降级回退（**这三是新问题**）。

**一条主线贯穿三版且从未改变：采集范围只增不减，"人"的画像越来越完整，而用户始终没有知情权、选择权和删除权。**

**关于"反诈"：三个版本都没有。** 但它的数据集是反诈画像的优质原料——这是能力问题，不是功能问题。

**关于本意：** 注册是壳，网络优化是半个真业务，**用户画像是核**。它被刻意设计成不可见、不可关闭、不可卸载、不可审计——这四条，比它采了什么更能说明它想干什么。

---

*本报告基于静态分析。所有结论均可通过文中的文件路径与行号复核；如需运行时佐证，用 PCAPdroid 抓 `dm.wo.com.cn`（注意 18080 与 18081 两个端口）即可。*

---

## 9. 外部传闻核对

日文帖（[`@tanaka_yuto`，2026-11-02](https://x.com/tanaka_yuto/status/2117066492672110700)）与本版的对应关系已并入 [06-rumor-verification.md](06-rumor-verification.md)；4.0.0 的关键差异（TLS 主通道、13 家厂商适配器、权限数 19）见该文 §10「三版差异速查」。

---

*本文为 **systemhelper** 研究集的一部分 · 许可 [CC BY 4.0](../LICENSE) · [返回目录](../README.md)*
