# SystemHelper 上报接口（API）技术报告

> 对象：`com.mobiletools.systemhelper` v1.2-20220907（SHA-256 `416d0fc0405fc19b243e72f2a7963517e5b88991a7dfac494934449969a6015d`）
> 方法：jadx 反编译 + smali 交叉验证 + 本地 mock 往返测试
> 日期：2026-11-07
> 结论级别：高置信（协议参数、序列化顺序、加密链路均已用可运行代码复现）
>
> **关于文中出现的地址**：报告内的 IP 已替换为文档保留地址（`203.0.113.0/24`、`198.51.100.0/24`）；本地路径、主机名与设备标识已移除。域名保留，因为它们是被分析对象本身。

---

## 0. 先说结论：这 6 个 URL 里，**当前版本只有 1 个真正在发数据**

| # | URL | 方法 | 当前版本是否被调用 | 说明 |
|---|---|---|---|---|
| API-01 | `http://dm.wo.com.cn:18080/registerv3` | POST | **是（唯一活跃）** | 设备注册主接口，AES 密文 body |
| API-02 | `http://dm.wo.com.cn:18080/public/ip` | GET | **否（编译期开关关闭）** | `GET_IP_ENABLED = false`，全代码无赋值点 |
| API-03 | `http://dm.wo.com.cn:6002/registerv3/getRegisterLog` | POST | **否（无调用点）** | `LogPostHelper` 类无任何引用 |
| API-04 | `http://198.51.100.26:8080/bonc_Register/RegisterPort?wsdl` | SOAP | **否（无调用点）** | `WebServiceHelper.registerDevInfo()` 方法体是 `return false` |
| API-05 | `http://cnc-labs.eicp.net:8080/registerService/web/getRegister` | POST | **否（无调用点）** | `HttpHelper` 类无任何引用 |
| API-06 | `http://webservice.chinaunicom.com/GetRegister` | — | **否** | 这不是端点，是 SOAP Action / 命名空间字面量 |

**一句话：这是一个协议演进留下的"三层化石"—— v1（SOAP / BONC）→ v2（明文 JSON / 花生壳联调）→ v3（AES+RSA / 联通 DM 平台）。只有 v3 是活的，其余 5 个是死代码。**

判定依据（可复核）：

```bash
grep -rn "LogPostHelper\|new HttpHelper\|new WebServiceHelper" jadx_full/sources/
# → 只命中类定义自身，没有任何 new/调用

grep -rn "GET_IP_ENABLED" jadx_full/sources/
# → GlobalSetting.java:24  = false  （定义）
# → DeviceInfo.java:310、DeviceManager.java:50 （读取）
# → 没有任何赋值语句
```

---

## 1. API-01：`POST /registerv3`（唯一活跃接口）

### 1.1 概览

| 项 | 值 |
|---|---|
| 完整 URL | `http://dm.wo.com.cn:18080/registerv3?ver=3.0&model=<MODEL>&manuf=<MANUF>&sign=<SIGN>` |
| 方法 | `POST` |
| 协议 | **HTTP/1.1 明文**（`usesCleartextTraffic="true"`） |
| Content-Type | `application/encrypted-json`（自定义 MIME） |
| Content-Length | 密文字节数 |
| body | **二进制密文**，无 base64、无 hex、无 multipart |
| 超时 | connect 10000ms / read 15000ms |
| 鉴权 | **无**（`sign` 是公钥加密，不是签名，见 §1.5） |
| 成功判定 | `HTTP 200`，**或 `HTTP 416`** |
| 失败处理 | 报文入本地 SQLite（`history` 表，上限 100 条），下次成功上报时连同 `History` 字段补传 |

源码：`control/RegisterThread.java:41-85`、`utils/HttpEncryptHelper.java:25-53`

### 1.2 Query 参数（4 个，全部必填）

| 参数 | 是否固定 | 取值 | 说明 |
|---|---|---|---|
| `ver` | **固定** | `3.0` | 硬编码字符串，与 body 内 `SpecVersion` 一致 |
| `model` | 动态 | `Build.MODEL`，URLEncode | 设备型号，如 `M2012K11AC` |
| `manuf` | 动态 | `Build.MANUFACTURER`，URLEncode | 厂商，如 `Xiaomi`；`null` 时填 `Unknown` |
| `sign` | 动态 | `URLEncode(Base64(RSA_pub(MD5(body明文))))` | 见 §1.4，128 字节密文 → 172 字符 Base64 → URL 编码 |

⚠️ **URL 里 `model` 和 `manuf` 是明文的**。这意味着：即使 body 是密文，**同一局域网抓一个包就能知道"什么型号的手机在向联通注册"**。

### 1.3 Body：加密管线（三步，全部可复现）

```
① plaintext = JSON string（紧凑、无空格、键按插入序）
② key       = MD5(plaintext)         → 16 字节 → AES-128
③ sign      = RSA_pub(MD5(plaintext))→ 128 字节
④ body      = AES/ECB/PKCS5Padding(plaintext, key)
```

对应源码：

| 步骤 | 代码 |
|---|---|
| ② `Cryptography.md5()` | `MessageDigest.getInstance("MD5").digest(str.getBytes("UTF-8"))` |
| ③ `Cryptography.RSADigest()` | `new RSAHelper().encrypt(loadKey(assets/pub.cer), md5)` |
| ③ `RSAHelper.encrypt()` | `Cipher.getInstance("RSA/ECB/PKCS1Padding")` |
| ④ `Cryptography.AESEncrypt()` | `Cipher.getInstance("AES/ECB/PKCS5Padding")`，`SecretKeySpec(md5, "AES")` |

**关键点：AES 的密钥就是明文的 MD5，而明文就在 body 里。** 这是一个闭环的自指加密 —— 服务端收到 body 后无法自行解密，必须先用 RSA 私钥解开 `sign` 拿到 MD5 才能解 body。所以：

- 对**有私钥的服务端**：能解（但这套方案等价于"用私钥分发对称密钥"，属于自研土办法）
- 对**抓包者**：拿不到 key，确实解不开 body
- 对**任何解包 APK 的人**：可以**构造**任意合法报文（因为只需要公钥），见 §1.5

### 1.4 `sign` 的算法细节（要精确到字节）

```java
byte[] md5  = MD5(jsonString);                                 // 16 字节
byte[] blob = RSA/ECB/PKCS1Padding_encrypt(pub.cer, md5);      // 128 字节（1024-bit）
String b64  = Base64.encodeToString(blob, 0);                  // DEFAULT：带 padding、不换行
String sign = URLEncoder.encode(b64, "utf-8");                 // "+" → "%2B"，"=" → "%3D"
```

实测：`sign` 解码后恒为 **128 字节**，模数 **1024 bit**，指数 65537。

### 1.5 致命设计缺陷：`sign` 提供零鉴权

| 正常签名方案 | 本方案 |
|---|---|
| 客户端用**私钥**签名，服务端用**公钥**验签 | 客户端用**公钥**加密，服务端用私钥解密 |
| 只有持有私钥者能生成合法签名 | **任何解包 APK 的人都能生成合法 `sign`**（公钥就在 `assets/pub.cer`） |

后果：**任何人可以伪造任意设备的注册报文**，向 `registerv3` 提交任意 IMEI/IMSI/机型，服务端无法区分"真实终端"和"脚本"。这不是"防篡改"，只是"防旁观者直接读懂"。

### 1.6 响应处理：为什么 `416` 算成功

```java
boolean ok = httpEncryptHelper.sendPOSTRequest(url, aes, md5);
if (!ok && httpEncryptHelper.getResponseCode() == 416) {
    ok = true;   // ← 416 视为成功
}
if (ok) { db.clearHistory(); } else { db.insertRecord(json); }
```

`416 Range Not Satisfiable` 在标准 HTTP 里与业务无关。这里的语义只能是**服务端自定义的"重复注册 / 已存在"标记**：同一 IMEI+ICCID 重复上报时返回 416，客户端据此认为"这条已经入库了"，于是清空本地队列。

这条逻辑的价值在于：**它暴露了服务端的去重键** —— 服务端是以"设备 + SIM"为唯一键做幂等判断的。

### 1.7 完整请求示例（本地 mock 实测）

```http
POST /registerv3?ver=3.0&model=M2012K11AC&manuf=Xiaomi&sign=C1UuVlvQfNrjjzlv%2BEdNUA7hNvSRNB8NYt25zwbaVETU37LhO6VL%2FaruYga%2F4%2BZ1szz%2FtiX%2FfTi%2BhZVYmMA8JAOWMxKAI4ztsney2QH2M%2F%2FrxBaDOduv8yTMQNqNCqDLa%2Fq4qbtyddsWBPrb7fWtTT%2F9QyvnW4fB0f6nPEstW3E%3D HTTP/1.1
Host: 127.0.0.1:8080
User-Agent: Dalvik/2.1.0 (Linux; U; Android 12; M2012K11AC Build/SKQ1.211006.001)
Content-Type: application/encrypted-json
Content-Length: 816

<816 字节 AES 密文>
```

对应响应：

```http
HTTP/1.1 200 OK
Content-Length: 0
```

---

## 2. API-01 的 body 字段字典（这就是"能提交什么"）

以下为 `DeviceInfo.getJsonString()`（`DeviceInfo.java:151-329`）的完整序列化结果。**字段顺序即代码插入顺序**，服务端若做严格解析会依赖它。

### 2.1 设备与系统

| 键 | 类型 | 取值来源 | 备注 |
|---|---|---|---|
| `Manuf` | string | `Build.MANUFACTURER`，空则 `"Unknown"` | — |
| `Model` | string | `Build.MODEL`，空则 `"Unknown"` | 同时出现在 query |
| `HWVersion` | string | `ro.hardware.version` / `ro.product.hardware` | 反射 SystemProperties 读 |
| `SWVersion` | string | `Build.DISPLAY` 或 `ro.build.display.id` | — |
| `OS` | string | 固定 `"Android"` | — |
| `OSVersion` | string | `Build.VERSION.RELEASE` | — |
| `DeviceType` | string | 见下表，默认 `"000"` | 决定服务端归类 |
| `SubType` | object/string | 厂商私有字段，默认 `""` | — |

`DeviceType` 取值域（`GlobalSetting`）：

| 值 | 含义 |
|---|---|
| `000` | 手机（默认） |
| `000002` / `000003` / `000004` / `000005` | 2G / 3G / 4G / 5G 手机 |
| `001007001` | iPad 4G |
| `007001029` | 车机云镜 |

### 2.2 卡 1 / 卡 2（成对出现，缺失填 `""`）

| 键（卡1 / 卡2） | 类型 | 约束 | 说明 |
|---|---|---|---|
| `IMEI1` / `IMEI2` | string | **必须 15 位纯数字**，否则 `checkIMEI()` 拒绝整包 | `Unknown` 可通过（null 视为跳过） |
| `ICCID1` / `ICCID2` | string | 20 位数字串，可空 | SIM 卡序列号 |
| `IMSI1` / `IMSI2` | string | 15 位，460 开头 | 用户标识 |
| `MSISDN1` / `MSISDN2` | string | 手机号，可空 | **本机号码** |
| `MNC1` / `MNC2` | string | 5 位，如 `46001` | 46001/46006/46009 = 联通 |
| `NCLS1` / `NCLS2` | string | `GSM`/`WCDMA`/`CDMA`/`TD-SCDMA`/`LTE`/`NR`/`NSA`/`SA`/`UNKNOWN` | 网络制式 |
| `CellID1` / `CellID2` | string | 数字，或 CDMA 下 `经度:纬度` | 小区号 |
| `LAC1` / `LAC2` | string | 数字（LTE 下实为 TAC） | 位置区码 |
| `VolteEnabled1` / `2` | string | `"1"` / `"0"` / `"-1"`（未知） | IMS 设置状态 |
| `5GEnabled1` / `2` | string | `"1"` / `"0"` | `preferred_network_mode` 是否 ≥23 |

### 2.3 连接与状态

| 键 | 类型 | 取值 | 说明 |
|---|---|---|---|
| `DataSlot` | string | `"0"`/`"1"`/`"2"` | 主数据卡槽；非法值强制改 `"0"` |
| `AccType` | string | 默认 `"Unknown"` | 接入类型 |
| `IPv4` / `IPv6` | string | 公网 IPv4 + 本机 IPv6 | **仅当 `GET_IP_ENABLED=true`**，默认不含此二键 |
| `SignalInfo` | string(JSON) | `{ssrsrp, ssrsrq, sssinr}` | **仅当 `SIGNAL_ENABLE=true`**，默认不含 |
| `RegType` | string | `F`/`B`/`T`/`S`/`A` | 见 §2.5 |
| `SpecVersion` | string | 固定 `"3.0"` | 代码写死 |
| `RegVersion` | string | `versionName`，如 `"1.2-20220907"`；无则 `"1.0"` | — |
| `Time` | string | `yyyy-MM-dd HH:mm:ss` | 本机时区，可被篡改 |

### 2.4 `AppInfo` 数组（最敏感的部分）

每个元素（`AppInfo.getJsonObject()`）：

```json
{
  "appLabel": "微信",
  "pkgName": "com.tencent.mm",
  "runTime": "120min",
  "tx1": "10KB", "rx1": "2048KB",
  "tx2": "0KB",  "rx2": "0KB",
  "totalData1": "2058KB",
  "totalData2": "0KB",
  "totalDataWiFi": "12MB"
}
```

⚠️ **注意单位是拼在字符串里的**（`"120min"`、`"10KB"`、`"12MB"`），服务端必须做字符串解析 —— 这是典型的"前端图省事"写法，也说明这个字段是给**报表/画像系统**看的，不是给计费系统用的。

数据来源：
- `UsageStatsManager.queryAndAggregateUsageStats(now - 7d, now)` → `runTime`（前台毫秒 / 60000）
- `NetworkStatsManager` + `NetworkStats.Bucket` → `tx1/rx1/tx2/rx2/totalDataWiFi`（按 uid + 卡槽 + WiFi 分别统计）
- `PackageManager.getInstalledApplications(0)` → `pkgName` / `appLabel`

### 2.5 `RegType`：上报触发原因（服务端据此判断数据新鲜度）

| 值 | 触发时机 | 代码位置 |
|---|---|---|
| `F` | 首次开机（`firstPowerOn` 偏好为空时） | `OnBootReceiver:59-68` |
| `B` | 后续开机 | `OnBootReceiver:69-75` |
| `T` | SIM 状态变化 / 换卡（`SIM_STATE_CHANGED`） | `SIMStateReceiver:55-65` |
| `S` | 定时闹钟，默认 **24 小时** | `ScheduleRegisterReceiver:28-38` |
| `A` | 应用清单闹钟，默认 **7 天** | `AppInfoRegisterReceiver:28-38` |

### 2.6 `History` 数组（补传机制）

上报失败时 body 原文入 SQLite `history` 表（最多 100 条）；下次成功上报时，**整个队列作为 `History` 数组塞进同一个 JSON** 一起发。这意味着：

- 单次报文最大体积 ≈ 100 × 单条 JSON（实测单条约 800~1200 字节，含 AppInfo 时可达数 KB）
- 服务端可以一次性收到**过去若干天的完整轨迹补录**

---

## 3. API-02：`GET /public/ip`（休眠）

| 项 | 值 |
|---|---|
| URL | `http://dm.wo.com.cn:18080/public/ip` |
| 方法 | `GET`，无参数、无 body、无自定义 header |
| 超时 | connect 3000ms / read 3000ms |
| 请求 | 裸 `HttpURLConnection`，带 Android 默认 UA |
| 响应 | `200` → 读 body（支持 `Content-Encoding: gzip`），`trim()` 后**当纯文本 IP 使用** |
| 非 200 | 记日志、返回 null |
| 当前状态 | **不被调用**：`GlobalSetting.GET_IP_ENABLED = false`，全代码无赋值点 |

源码：`utils/GetIPAddressHttpHelper.java`、`control/GetIPAddressThread.java:45`、`DeviceManager.java:50`

**能提交什么**：什么都不用提交，就是"问一句我的出口 IP 是多少"。它的存在价值是当终端在 NAT 后面时，让服务端知道设备的公网出口（用于定位/网络质量分析）。

顺带一提：`getIPv6Address()` 不走网络，直接枚举本机网卡取第一个非回环、非链路本地的 IPv6 地址 —— 如果开了 `GET_IP_ENABLED`，**内网 IPv6 也会被上报**。

---

## 4. API-03：`POST /registerv3/getRegisterLog`（死代码）

| 项 | 值 |
|---|---|
| URL | `http://dm.wo.com.cn:6002/registerv3/getRegisterLog`（注意端口 **6002**） |
| 方法 | `POST` |
| Content-Type | **未设置**（`HttpURLConnection` 默认 `application/x-www-form-urlencoded`） |
| body | `jsonData=<原始 JSON 字符串>`，**未做 URL 编码**，直接字符串拼接 |
| 成功判定 | `200` |
| 调用点 | **无**（`LogPostHelper` 类零引用） |

源码：`utils/LogPostHelper.java:11-40`

**能提交什么**：设计上是把客户端运行日志（`MyLog` 输出）以 `jsonData=` 形式推给服务端做排障。

**为什么说是"化石"**：body 拼接方式（`"jsonData=" + str`）在 JSON 含 `&`、`+`、`%` 时会直接破坏报文 —— 这是 v2 时代的写法，已被 v3 的 `application/encrypted-json` 取代。

---

## 5. API-04：`SOAP /bonc_Register/RegisterPort`（死代码 + 空实现）

| 项 | 值 |
|---|---|
| Endpoint | `http://198.51.100.26:8080/bonc_Register/RegisterPort` |
| WSDL | 同 URL + `?wsdl` |
| 命名空间 | `http://webservice.chinaunicom.com/` |
| 方法名 | `GetRegister` |
| SOAPAction | `http://webservice.chinaunicom.com/GetRegister` |
| 实现 | **`registerDevInfo(String)` 方法体只有 `return false;`** |
| 调用点 | 无 |

源码：`utils/WebServiceHelper.java:4-13`

```java
public boolean registerDevInfo(String str) throws Exception {
    MyLog.d(TAG, "jsonParam:" + str);
    return false;                    // ← 从未真正发过 SOAP 请求
}
```

`198.51.100.26` 是北京联通地址段；`bonc_` 前缀指向 **BONC（东方国信）** —— 联通 IT 系统的老牌集成商。这条是 v1 协议：**SOAP over HTTP + 明文 JSON 参数**。

**能提交什么**（如果这条链路复活）：一个 `GetRegister` SOAP 请求，参数为设备信息 JSON 字符串。但当前二进制里它是空壳，提交不了任何东西。

---

## 6. API-05：`POST /registerService/web/getRegister`（死代码）

| 项 | 值 |
|---|---|
| URL | `http://cnc-labs.eicp.net:8080/registerService/web/getRegister` |
| 方法 | `POST` |
| body | `jsonData=<JSON>`，未编码 |
| 成功判定 | `200` |
| 调用点 | **无**（`HttpHelper` 类零引用） |
| 特殊之处 | URL 以**字节数组**形式硬编码，规避字符串扫描 |

源码：`utils/HttpHelper.java:9`

```java
private static final byte[] HTTP_SERVER_URL = {104, 116, 116, 112, 58, /* ... */};
// 解码后 = http://cnc-labs.eicp.net:8080/registerService/web/getRegister
```

**这条最值得注意**：`cnc-labs.eicp.net` 是**花生壳（Oray）动态域名**。"cnc" 是 China Netcom（原中国网通）的缩写，"labs" 是实验室。这是**开发/联调服务器**，被混进了正式包。

**能提交什么**：v2 协议的明文 JSON（`jsonData=` 形式）。因为域名解析权在第三方动态 DNS 服务商手里，**这条链路一旦被复活，指向哪里就由域名持有人决定** —— 这是供应链风险，不是功能。

---

## 7. API-06：`http://webservice.chinaunicom.com/GetRegister`

**这不是一个可访问的端点**，它是 API-04 的 `SOAPAction` 与命名空间字面量：

```java
NAMESPACE = "http://webservice.chinaunicom.com/"
SOAP_ACTION = "http://webservice.chinaunicom.com/GetRegister"
```

`webservice.chinaunicom.com` 这个主机名在代码里**从未被解析或连接**。把它当成"接口"是误读。

---

## 8. 协议演进推断

三个世代并存于同一个 APK，说明这个模块是**跨多年迭代累积**的：

| 代 | 端点 | 特征 | 年代推断 |
|---|---|---|---|
| v1 | `198.51.100.26:8080` SOAP | BONC 集成、China Unicom 命名空间、明文 | 早期（2010s 初） |
| v2 | `cnc-labs.eicp.net:8080` 明文 JSON | 花生壳联调、`jsonData=` 拼接 | 中期（2015 前后） |
| v2.5 | `dm.wo.com.cn:6002/getRegisterLog` | 同 v2 风格，独立日志端口 | 中期 |
| **v3** | `dm.wo.com.cn:18080/registerv3` | AES-128-ECB + RSA-1024 + 自定义 MIME | **当前在用（2019+）** |

`assets/pub.cer` 签发于 **2019-05-24**，与 v3 上线时间吻合。证书**有效期到 2119 年**，是一个"设了就不管"的典型内部运维痕迹。

---

## 9. "可以提交什么" —— 按接口汇总

| 接口 | 请求体形态 | 可提交内容 | 当前是否有效 |
|---|---|---|---|
| `POST /registerv3` | 二进制 AES 密文（任意 JSON） | 设备/双卡标识、基站、应用清单、使用时长、分卡流量、GPS 派生的 `SignalInfo` | ✅ **有效** |
| `GET /public/ip` | 无 | 无（纯查询） | ❌ 开关关闭 |
| `POST /getRegisterLog` | `jsonData=<str>` | 任意文本（设计为运行日志） | ❌ 无调用点 |
| `POST /bonc_Register/...` | SOAP XML | 依赖 WSDL，方法 `GetRegister` | ❌ 空实现 |
| `POST /registerService/web/getRegister` | `jsonData=<str>` | 任意 JSON | ❌ 无调用点 |

**技术上"能提交" ≠ "应当提交"。** 前一份报告已经确认：这套管道的 `sign` 无鉴权、目标域名归属联通、`cnc-labs` 域名在第三方手里。**向这些地址发送任何构造报文，都是在向真实运营商生产系统写数据**，属于对第三方系统的未授权写入，会造成设备库污染，也可能触发运营商侧的风控与溯源。

所以下面给的是**本地闭环验证方案**，不是线上利用。

---

## 10. 本地闭环验证（不碰任何真实服务器）

已随报告提供三个文件，可直接跑：

| 文件 | 作用 |
|---|---|
| `systemhelper_api.py` | 协议参考实现：构造 / 校验 / 解密 |
| `mock_server.py` | 本地 mock：接收请求、落盘、可选返回 416 |
| `sample_payload.json` | 一份完整的上报样例（含 `AppInfo`） |

### 10.1 构造一个合法报文

```bash
python systemhelper_api.py validate --json sample_payload.json
python systemhelper_api.py build --json sample_payload.json \
       --base http://127.0.0.1:8080/registerv3 --out request.bin
```

输出：

```
URL     : http://127.0.0.1:8080/registerv3?ver=3.0&model=M2012K11AC&manuf=Xiaomi&sign=C1Uu...
Headers : {'Content-Type': 'application/encrypted-json', 'Content-Length': '816'}
Body    : 816 字节 → request.bin
```

### 10.2 起 mock 并投递

```bash
python mock_server.py --port 8080 --plain sample_payload.json
# 另一个终端
curl -X POST "http://127.0.0.1:8080/registerv3?ver=3.0&model=M2012K11AC&manuf=Xiaomi&sign=..." \
     -H "Content-Type: application/encrypted-json" --data-binary @request.bin
```

mock 会在 `logs/` 下落盘完整请求，并在给了 `--plain` 时**解密出 body 明文**（因为已知明文即可推出 key）。

### 10.3 验证"416 也算成功"

```bash
python mock_server.py --code 416
```

客户端逻辑（`RegisterThread:86`）会把 416 当成功并清空本地队列 —— 这解释了为什么运营商的"重复注册"不会在客户端无限重试。

### 10.4 实测结果（本机验证）

| 检查项 | 结果 |
|---|---|
| 明文长度 → 密文长度 | 815 → 816（PKCS5 补齐 1 字节） |
| AES 往返解密 | ✅ 与原文完全一致 |
| `sign` 解码长度 | 128 字节 |
| RSA 模数 | 1024 bit，e=65537 |
| mock 收到 `Content-Type` | `application/encrypted-json` |
| mock 收到 `Content-Length` | 816 |

---

## 11. 抓包对照表（用于识别真实流量）

若在 PCAPdroid / tcpdump 中看到以下特征，即可确认是这条管道：

| 特征 | 值 |
|---|---|
| 目标 IP:Port | `dm.wo.com.cn:18080` |
| 请求行 | `POST /registerv3?ver=3.0&model=... HTTP/1.1` |
| User-Agent | `Dalvik/2.1.0 (Linux; U; Android <ver>; <MODEL> Build/<id>)` |
| Content-Type | `application/encrypted-json` |
| Content-Length | 通常 800 ~ 4000（含 `History` 时更大，最大约 100 条累积） |
| 响应码 | `200` 或 **`416`** |
| 请求频率 | 开机一次 + 每 24h 一次 + 换卡即触发 |

---

## 12. 安全与合规问题清单（按严重度）

| # | 问题 | 位置 | 影响 |
|---|---|---|---|
| 1 | `sign` 用公钥加密，等同无客户端认证 | `Cryptography.RSADigest` | 任意人可伪造任意设备注册报文，污染运营商设备库 |
| 2 | 明文 HTTP 传输 | Manifest `usesCleartextTraffic=true` | 同网段可观察设备型号、上报节奏、请求体积 |
| 3 | AES/ECB + 密钥=明文 MD5 | `Cryptography.AESEncrypt` | 无 IV、无盐、无 KDF；相同明文产生相同密文，块级可分析 |
| 4 | RSA-1024 | `assets/pub.cer` | 低于现代最低强度（2048），且证书有效期到 2119 年 |
| 5 | 上报地址可被 AIDL 改写 | `IRegisterHelperService.TRANSACTION_setServerAddress` | 同签名应用可把数据管道改指第三方 |
| 6 | 调试域名入正式包 | `cnc-labs.eicp.net`（花生壳） | 域名解析权在第三方，供应链风险 |
| 7 | 调试 Activity 导出 | `TestActivity exported=true` | 任意应用可拉起并显示设备信息 JSON |
| 8 | 明文存储敏感数据 | `databases/systemhelper`（100 条）、`shared_prefs`（ICCID 明文） | root/取证工具可直接读取历史轨迹 |
| 9 | `416` 被当成功 | `RegisterThread:86` | 逻辑耦合自定义语义，标准客户端无法复用 |
| 10 | 单位混入字符串 | `AppInfo`：`"120min"`、`"12MB"` | 服务端需字符串解析，易出错 |

---

## 13. 附：字段顺序（严格解析时需要）

`DeviceInfo.getJsonString()` 的插入顺序：

```
Manuf, Model, HWVersion, SWVersion, OS, OSVersion,
IMEI1, ICCID1, IMSI1, MSISDN1, MNC1, NCLS1, CellID1, LAC1, VolteEnabled1, 5GEnabled1,
IMEI2, ICCID2, IMSI2, MSISDN2, MNC2, NCLS2, CellID2, LAC2, VolteEnabled2, 5GEnabled2,
DataSlot, AccType,
[IPv4, IPv6]        ← 仅 GET_IP_ENABLED
SubType, DeviceType, RegType, SpecVersion, RegVersion, Time,
AppInfo,
[SignalInfo]        ← 仅 SIGNAL_ENABLE
[History]           ← 仅补传时出现
```

> 注意：`JSONObject` 在 Android 上实际使用的是 `LinkedHashMap`，所以**顺序即插入顺序**，服务端若用严格 schema 校验，顺序必须一致。

---

## 14. 一句话总结

**这 6 个 URL 里，只有 `POST http://dm.wo.com.cn:18080/registerv3` 是活的：它接收一个 AES/ECB 密文的 JSON（设备 + 双卡 + 基站 + 应用清单 + 流量），用 `?ver=3.0&model=&manuf=&sign=` 做路由，`200` 或 `416` 都算成功；其余 5 个是 SOAP 时代与花生壳联调时代留下的死代码，其中 `webservice.chinaunicom.com/GetRegister` 甚至不是一个端点，只是个 SOAPAction 字符串。**

**最该记住的一点：`sign` 是用公钥加密 MD5，不是私钥签名 —— 这套机制提供零客户端身份认证。**

---

*本文为 **systemhelper** 研究集的一部分 · 许可 [CC BY 4.0](../LICENSE) · [返回目录](../README.md)*
