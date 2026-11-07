# SystemHelper 4.0.0 · CU-DMS 上报协议分析（脱敏版）

> 样本：`SystemHelper.apk` = `com.mobiletools.systemhelper` **4.0.0-20260910**
> 通道：`https://dm.wo.com.cn:18081/register?ver=6.0&model=&manuf=&sign=`（主）+ `http://dm.wo.com.cn:18080/register`（回退）
> 方法：APK 证书提取 + jadx 反编译调用链复原 + 报文结构二进制级对齐（SHA-256 → AES-GCM → RSA）
> 日期：2026-11-07
> 结论级别：**高**（协议、字段、加密链路全部来自 APK 内代码，可逐行复核）

> **关于文中出现的地址**：报告内的 IP 已替换为文档保留地址（`203.0.113.0/24`、`198.51.100.0/24`）；本地路径、主机名与设备标识已移除。域名保留，因为它们是被分析对象本身。

---

## 0. 摘要（6 条）

| # | 结论 | 依据（代码位置） |
|---|---|---|
| 1 | `sign` **不是签名，是用公钥加密的对称密钥**——持有 APK 的人都能为任意报文生成"合法" `sign` | `g1/j.java:a()` → `Cipher.getInstance("RSA/ECB/PKCS1Padding")` + `Cipher.ENCRYPT_MODE` |
| 2 | AES-256-GCM 的 **IV 由密钥自身派生**（`key[0:8]‖key[24:32]`），同一明文必然同一密文 | `g1/c.java:a()` 的两次 `System.arraycopy` |
| 3 | `TrustManager` **只调 `checkValidity()`，不校验签发者**，任意自签证书可通过 | `g1/f.java:c` |
| 4 | TLS 失败时**自动降级到明文 HTTP `:18080` 重发**，TLS 形同虚设 | `e1/g.java` 的 `"HTTPS fail by cert invalid, trigger HTTP fallback!"` |
| 5 | 客户端把 `200` 或 `416` 一律判成功并清空本地队列，**成功语义极弱**（服务端回空体） | `e1/g.java:a()` 判 `code == 416 \|\| code == 200` |
| 6 | `model` / `manuf` 明文放在 query 上，body 加密后**机型仍然裸奔** | `e1/g.java:g()` 的 URL 拼装 |

---

## 1. 凭证盘点：三张证书，各管一段

### 1.1 联通私签证书 A —— APK 签名证书（`CN=NewDM`）

从 APK Signing Block（v2 scheme，`0x7109871a`）提取：

```
subject : CN=NewDM, OU=RI, O=CU, L=BJ, ST=BJ, C=86
issuer  : CN=NewDM, OU=RI, O=CU, L=BJ, ST=BJ, C=86      ← 自签（私签）
算法    : sha256WithRSAEncryption / RSA-2048
序列号  : 0x34a8a2c8
有效期  : 2019-03-21 → 2069-03-08
SHA-1   : 0D:0B:1F:90:18:23:91:C7:75:04:B8:43:DD:39:37:B2:3D:74:9A:E6
SHA-256 : 87:4B:8C:A2:29:7F:53:A3:73:B1:B9:35:C1:34:CB:0E:B1:FF:73:81:E5:44:91:B8:8C:64:3A:6B:9C:46:DB:77
SKI     : 45:F7:8C:F6:8C:CE:0C:47:4E:98:E0:96:64:1E:24:FA:C8:56:86:FB
```

**它对本接口的作用：零。**

- 私钥不在 APK 里（只有公钥证书），无法用它签新包；
- 服务端 TLS 握手不索要客户端证书（`openssl s_client` 看不到 `CertificateRequest`）；
- 请求里没有任何"APK 签名"相关字段。

它唯一的价值是**同签名应用互信**（`com.mobiletools.systemhelper.permission`，`protectionLevel=signature`）。也就是说：想用 AIDL 拉起 `RegisterHelperService` 或读 `TestActivity`，需要这把私钥——**外面拿不到**。

### 1.2 联通私签证书 B —— 报文加密证书（`assets/cudms_main_pub.cer`）★ 真正用的就是它

```
subject : C=CN, ST=BJ, L=BJ, O=UNICOM, OU=UNICOM, CN=UNICOM
issuer  : C=CN, ST=BJ, L=BJ, O=UNICOM, OU=UNICOM, CN=UNICOM   ← 自签（私签）
算法    : sha256WithRSAEncryption / RSA-2048
序列号  : 0x32353034
有效期  : 2024-11-04 → 2124-10-11
SHA-256 : 4E:71:93:4C:88:93:18:68:4B:63:CA:F2:6C:5F:EF:AF:5F:8D:E6:AC:D0:94:EF:76:1A:AD:74:99:BF:EE:E5:22
文件名  : cudms_main_pub.cer = CU-DMS（中国联通设备管理系统）主公钥
```

它是 `g1.c.b()` 里 `assets.open("cudms_main_pub.cer")` 打开的、用于把 AES 密钥加密进 `sign` 参数的那把公钥。**公钥随 APK 全球分发**，因此"能生成合法 sign"不是能力问题，是设计如此。

### 1.3 服务端证书 —— 公网 CA（不是私签）

```
subject : C=CN, ST=北京市, L=北京市, O=中国联合网络通信有限公司研究院, CN=dm.wo.com.cn
issuer  : C=CN, O=China Financial Certification Authority, CN=CFCA OV RSA OCA G2
链      : CFCA OV RSA OCA G2 → CFCA Global RSA ROOT G2 → CFCA EV ROOT
有效期  : 2026-10-13 → 2027-04-28
TLS     : TLSv1.3 / TLS_AES_256_GCM_SHA384
```

> 说明：客户端那套"只 `checkValidity()`、不校验签发者"的 `TrustManager` **并不是为了迁就这张证书**——CFCA 是公共 CA，标准校验本来也能过。它只是纯粹写错了（见 §4.3）。

---

## 2. 协议链：从 JSON 到线上请求

### 2.1 调用链

```
RegisterThread.run()
  └ e1.g.a(b)                          ← 组包 + 发送
      ├ json   = b.b()                 ← 49 字段 JSON（e1.b，插入序）
      ├ key    = g1.c.c(json)          ← SHA-256(json) = 32B
      ├ body   = g1.c.a(json, key)     ← AES/GCM/NoPadding，IV=key[0:8]||key[24:32]
      ├ sign   = g1.c.b(ctx, key)      ← RSA/ECB/PKCS1(cudms_main_pub.cer, key) → hex
      └ g1.f.g(url, body, key)
            POST {base}?ver=6.0&model={URLEncode(Model)}&manuf={URLEncode(Manuf)}&sign={hex}
            Content-Type: application/encrypted-json
            Content-Length: {len(body)}
```

### 2.2 关键实现（与 APK 字节码一一对应）

```python
key  = sha256(json_bytes)                          # 32B
iv   = key[0:8] + key[24:32]                       # 固定 IV —— 见 §4.2
body = AESGCM(key).encrypt(iv, json_bytes, None)   # 密文 || 16B tag
sign = pubkey.encrypt(key, PKCS1v15()).hex()       # 512 hex 字符
url  = f"/register?ver=6.0&model={q(Model)}&manuf={q(Manuf)}&sign={sign}"
```

### 2.3 报文尺寸关系（由代码推导，可离线复算）

| 量 | 关系 |
|---|---|
| 明文 | 49 字段 JSON，随 `AppInfo` 条数线性增长 |
| 密文 | 明文 + 16 B GCM tag |
| `sign` | 恒 512 hex 字符（RSA-2048 + PKCS#1 v1.5 定长） |
| `sign` 是否稳定 | 否——PKCS#1 v1.5 带随机填充，同一 `key` 每次不同 |
| `body` 是否稳定 | **是**——同一 JSON 两次构造字节完全一致（IV 派生自明文） |

---

## 3. 报文结构

### 3.1 端点总表

| 端点 | 方法 | 版本门 | 鉴权 | 响应 | 备注 |
|---|---|---|---|---|---|
| `https://dm.wo.com.cn:18081/register` | POST | `ver=5.0\|6.0` | **无**（sign 不验） | 空体 `200` | 主通道 |
| `http://dm.wo.com.cn:18080/register` | POST | 同上 | 无 | 空体 `200` | 明文回退 |
| `https://dm.wo.com.cn/register`（443） | * | — | — | WAF 拒绝 | 只放行 18081/18080 |
| `:6002/registerv3/getRegisterLog`、`:18080/registerv3` | — | — | — | — | 1.2/3.0.1 遗留，4.0.0 已不用 |

### 3.2 请求参数

| 参数 | 位置 | 必填 | 取值 | 校验强度 |
|---|---|---|---|---|
| `ver` | query | ✅ | `5.0` / `6.0` | **强**（白名单） |
| `model` | query | ✅（形状） | `Build.MODEL`，URLEncode | 弱（任意值） |
| `manuf` | query | ✅（形状） | `Build.MANUFACTURER`，URLEncode | 弱（任意值） |
| `sign` | query | ✅（形状） | `hex(RSA_PKCS1(cudms_main_pub, SHA256(json)))` | **无** |
| body | body | — | AES-256-GCM 密文（明文‖16B tag） | **无** |
| `Content-Type` | header | — | `application/encrypted-json` | **无** |

### 3.3 body 字段字典（49 键，顺序即插入序，`e1.b.b()`）

| # | 字段 | 类型 | 含义 | 敏感度 |
|---|---|---|---|---|
| 1 | `Manuf` | string | 厂商 | 低 |
| 2 | `Model` | string | 机型 | 中（机型画像） |
| 3 | `HWVersion` | string | 硬件版本 | 低 |
| 4 | `SWVersion` | string | 系统版本 | 低 |
| 5 | `OS` | string | 系统名 | 低 |
| 6 | `OSVersion` | string | 系统版本号 | 低 |
| 7 | `IMEI1` | string | 卡 1 IMEI | **高**（设备唯一标识） |
| 8 | `ICCID1` | string | 卡 1 ICCID | **高**（SIM 卡号） |
| 9 | `IMSI1` | string | 卡 1 IMSI | **高**（用户标识） |
| 10 | `MNC1` | string | 卡 1 运营商码 | 中 |
| 11 | `NetworkType1` | string | 卡 1 网络制式（NR/LTE） | 中 |
| 12 | `TAC1` | string | 跟踪区码 | **高**（定位） |
| 13 | `CID1` | string | 小区 ID | **高**（定位） |
| 14 | `PCI1` | string | 物理小区号 | 中 |
| 15 | `VolteEnabled1` | string | VoLTE 开关 | 低 |
| 16 | `5GEnabled1` | string | 5G 开关 | 低 |
| 17 | `VoNREnable1` | string | VoNR 开关 | 低 |
| 18–28 | `IMEI2`…`VoNREnable2` | string | 卡 2 同构字段 | **高**（双卡画像） |
| 29 | `DataSlot` | string | 主数据卡槽 | 低 |
| 30 | `BSSID` | string | WiFi 热点 MAC | **高**（可定位/追踪） |
| 31 | `LinkSpeed` | string | 链路速率 | 低 |
| 32 | `RSSI` | string | 信号强度 | 低 |
| 33 | `Frequency` | string | 频点 | 中 |
| 34 | `Esim` | string | eSIM 标志 | 低 |
| 35 | `InactiveEsimMNC` | string | 未激活 eSIM 运营商 | 中 |
| 36 | `PairedDevice` | string | **已配对蓝牙设备名串** | **高**（关系画像） |
| 37 | `PairedMacAddress` | string | **已配对蓝牙 MAC 串** | **极高**（硬件级唯一标识） |
| 38 | `SatelliteSupport` | string | 是否支持卫星通信 | 中（消费力） |
| 39 | `SatelliteEnabled` | string | 卫星通信是否开启 | 中 |
| 40 | `AccType` | string | 接入类型（wifi/cellular） | 低 |
| 41 | `IPv6` | string | IPv6 支持 | 低 |
| 42 | `SubType` | string | 厂商私有 | 低 |
| 43 | `DeviceType` | string | 设备类型（phone/pad） | 低 |
| 44 | `RegType` | string | 注册类型 | 低 |
| 45 | `SpecVersion` | string | `6.0` | 低 |
| 46 | `ClientVersion` | string | `4.0.0` | 低 |
| 47 | `Time` | string | `yyyy-MM-dd HH:mm:ss` | 中（时序） |
| 48 | `SigInfo` | object\|array | 信令快照（见 3.4） | **极高**（精确位置） |
| 49 | `AppInfo` | array | 应用清单+流量（见 3.5） | **极高**（行为画像） |

### 3.4 `SigInfo` 子字段（`g1/n.a()`，字段全非空才下发，否则下发 `[]`）

`Time, IMEI, ICCID, ClientVersion, MNC, IMSI, TAC, CID, PCI, NetworkType, ARFCN, Bands, Bandwidth, CQITableIndex, CQIIndex, RSRP, RSRQ, SINR, CSIRSRP, CSIRSRQ, CSISINR, Uspeed, Dspeed, CallDisconnectCause, DataFailCause, EPSFallback, LONGITUDE, LATITUDE, ALTITUDE, District, SPEED, BEARING, BSSID, SSID, Radius`

> **经纬度、海拔、区县、速度、方位角**全在这里。这是"上报注册信息"包里最不该出现的一组字段。

### 3.5 `AppInfo` 数组元素

`PackageName, AppName, ForegroundMinutes("120min"), LaunchCount, MobileUp("10KB"), MobileDown("12MB")`

> 数字被拼进字符串带单位（`"120min"`/`"12MB"`），说明消费端是**报表/画像**而非计费，且必须做字符串解析。

### 3.6 状态码语义

| 码 | 来源 | 含义 | 客户端处理 |
|---|---|---|---|
| `200` | RegisterServlet | 已接收（**不代表已入库**） | 判成功，清队列 |
| `400` | Jetty + RegisterServlet | `ver` 不在白名单 / 参数缺失 | 判失败，入队重试 |
| `403` | 前置 WAF | `UrlACL` 拒绝（路径/参数形状不符） | 判失败 |
| `416` | 历史语义 | 旧版视为成功 | 判**成功** |
| `429` | 网关 | 限流 | 判失败，入队（上限 10 条，溢出即丢） |
| `5xx` | — | — | — |

---

## 4. 客户端缺陷（全部为代码事实）

### 4.1 `sign` 是"公钥加密"，不是签名 —— 零认证

```java
// g1/j.java
Cipher cipher = Cipher.getInstance("RSA/ECB/PKCS1Padding");
cipher.init(1, key);   // 1 = ENCRYPT_MODE
```

用**公开**的 `cudms_main_pub.cer` 加密 SHA-256 摘要。**任何人**都能为任意 JSON 生成"合法" `sign`。

它只提供"密钥不明文传输"这一点点价值，而密钥本就由明文推出——**自指闭环**：`key = SHA256(json)`，`sign = RSA_pub(key)`。任何拿到 APK 的人都能完整重算三者。

正确的做法应该是反过来的：客户端持**私钥**签 `SHA256(body‖ver‖model‖manuf‖timestamp‖nonce)`，服务端持公钥验签。当前实现把"可验证性"写成了"可生成性"。

### 4.2 AES-GCM 固定 IV（同一明文 → 同一密文）

```java
System.arraycopy(bArr, 0,  bArr2, 0, 8);    // IV[0..7]  = key[0..7]
System.arraycopy(bArr, 24, bArr2, 8, 8);    // IV[8..15] = key[24..31]
GCMParameterSpec spec = new GCMParameterSpec(128, bArr2);
```

同一 JSON 两次构造 → `body` 完全一致（可直接用任意 AES-GCM 实现离线复算验证，无需联网）。

GCM 下 IV 重用会导致 **forbidden attack**：收集到同一 `(key, IV)` 的两份密文即可恢复 GHASH 认证子密钥 `H`，进而伪造任意密文的 tag。这里 IV 由明文决定（同明文才同 IV），但批量重复上报（如只改 `Time` 以外的空设备）完全可能撞车。

### 4.3 `TrustManager` 空校验 —— 任意自签证书可通过

```java
public void checkServerTrusted(X509Certificate[] chain, String authType) {
    if (chain == null || chain.length == 0) throw new CertificateException("服务端证书链为空");
    for (X509Certificate c : chain) c.checkValidity();   // ← 只看有效期，不看签发者
}
```

等价逻辑（`CERT_NONE` + 系统默认 `HostnameVerifier`）在本地回环上可直接复现：标准校验证书会抛 `SSLCertVerificationError`，而这段逻辑放行。

即：**自签证书 + SAN=dm.wo.com.cn** 即可完成中间人，客户端毫无察觉。

### 4.4 证书异常 → 自动降级明文 HTTP

```java
if (e instanceof SSLException) { ... }
// e1.g.a()：catch → if (f.e()) { "HTTPS fail by cert invalid, trigger HTTP fallback!" → POST http://…:18080 }
```

配合 §4.3：中间人一旦让 TLS 失败（或直接篡改），流量**原样明文重发**到 18080，body 与 `sign` 一起裸奔。

### 4.5 query 泄露机型

`model`、`manuf` 明文放在 URL 里，body 再怎么加密，**抓包即知"哪款手机在向联通注册"**。

---

## 5. 服务端行为（可观测部分）

| 观察 | 含义 |
|---|---|
| 成功响应恒为 `200` + `Content-Length: 0` | 无 `requestId`、无业务码、无幂等键；客户端只能靠状态码猜结果 |
| 入参校验只在 `ver` | `ver=5.0/6.0` 通过；其余版本被拒。与 3.0.1→`5.0`、4.0.0→`6.0` 的版本对应 |
| 前置 WAF 只做 URL 形状 ACL | 参数名与顺序敏感，参数值不看；不是内容级防护 |
| 错误页带实现信息 | 自定义 400 页泄露 Servlet 类名与 Jetty 版本号，可被指纹匹配 |
| 响应头带 `Content-Security-Policy: upgrade-insecure-requests` | 页面用 Filter 链被复用到了 API 响应上，配置未分流 |
| `GET/HEAD/OPTIONS` 不放行 | 方法矩阵不完整，健康检查/预检无法进行 |

> 这些是**协议与配置层面**的可观测事实。本报告不记录、不提供任何针对该端点的请求过程、频率、体积或结果数据。

---

## 6. 影响面（设计层）

1. **写入端没有身份**：`sign` 可被任何持有 APK 的人重算，服务端拿到的密文在解密前无法区分"客户端产生"与"第三方构造"。
2. **收件与验件解耦**：网关只做形状匹配和版本白名单就返回 `200`，真正的解密/解析发生在异步消费端，且失败无回执。发送方永远不知道数据是否入账——**这既是客户端"假成功"的根源，也让异常数据可以静默进入队列**。
3. **明文回退把 TLS 收益清零**：企业 WiFi、校园网、公共热点、透明代理只要能让证书校验失败，整条链路退回明文。
4. **字段清单本身就是隐私风险**：`IMEI/IMSI/ICCID` + `BSSID/SSID` + `经纬度/区县/速度/方位角` + `PairedMacAddress` + `AppInfo`（应用清单与前台时长）——单条报文即可完成"人—机—卡—位置—关系—行为"的六维关联。

---

## 7. 加固建议

### 服务端（按优先级）

1. **`sign` 必须服务端校验**，且改为**真签名**（客户端私钥签、服务端公钥验），或退一步：改用服务端下发的短期 token + TLS 客户端证书。
2. **入站即校验**：`ver` 白名单 + `sign` 长度/格式 + body 长度上限（业务实际 1 KB 级，建议 ≤ 64 KB）+ `Content-Type` 严格匹配，不合法**同步返回 4xx**，不要"先收后丢"。
3. **`maxRequestSize`** 显式配置（Jetty `maxRequestSize` / nginx `client_max_body_size`）。
4. **响应语义化**：返回 `{"code":0,"requestId":"…"}`，客户端才能区分"已入库/已拒绝"。
5. **幂等 + 时间窗**：`sign` 里带 `timestamp`+`nonce`，服务端做 ±5 min 窗口 + 去重表。
6. **错误页收敛**：自定义 400 页，去掉 `SERVLET` 类名与 Jetty 版本。
7. **只留 HTTPS**：`:18080` 下线或 301 到 `:18081` + HSTS；API 响应去掉 CSP 头。
8. **WAF 规则改语义**：不要依赖"参数顺序"，改为"路径 + 方法 + 白名单 `ver` + body 上限"。

### 客户端

1. `TrustManager` 改为标准校验或**证书/公钥固定**（pin `CFCA OV RSA OCA G2` 或叶子证书 SPKI）。
2. **删除 HTTP 回退**；证书异常直接失败并本地记录。
3. AES-GCM 使用**随机 12B IV**（随 body 前缀传输），不要从密钥派生。
4. 去掉 `sign` 语义混淆：要么真签名，要么明确叫 `key`。
5. `model/manuf` 移入加密 body。

---

## 8. 静态复现材料

| 文件 | 作用 |
|---|---|
| `evidence/cudms_main_pub.cer` | 报文加密公钥（`CN=UNICOM`，自签，从 `assets/` 提取） |
| `evidence/unicom_sign_cert_v2.pem/.der` | APK v2 签名证书（`CN=NewDM`） |
| `evidence/pub.cer` | 1.2 版本内嵌上报公钥（RSA-1024） |
| `evidence/MANIFEST.md` | 上述附件的大小与哈希 |

最小离线验证（不联网、不接触任何服务器）：

```bash
# 1. 校验签名与证书一致性
sha256sum evidence/*.cer evidence/*.der
openssl x509 -in evidence/unicom_sign_cert_v2.pem -noout -subject -dates -fingerprint -sha256
openssl x509 -inform DER -in evidence/cudms_main_pub.cer -noout -subject -dates

# 2. 复算 key / iv 关系（任意 JSON，纯本地）
python -c "import json,hashlib; j=json.dumps({'Manuf':'X','Model':'Y'},separators=(',',':')).encode(); k=hashlib.sha256(j).digest(); print('key',k.hex()); print('iv',(k[:8]+k[24:32]).hex())"
```

---

## 9. 一页速查

```
主通道   : POST https://dm.wo.com.cn:18081/register?ver=6.0&model=&manuf=&sign=
回退通道 : POST http://dm.wo.com.cn:18080/register          ← 证书失败时自动降级
加密     : key=SHA256(json); body=AES-256-GCM(key, iv=key[0:8]||key[24:32]); sign=hex(RSA(cudms_main_pub,key))
可信度   : ver 白名单(5.0/6.0)=强；sign/body/content-type/长度=无校验
幂等     : 无 nonce / 无时间窗 / 无去重键
身份     : 无（公钥随包分发，sign 可被任何人重算）
响应     : 200 空体，无业务码（客户端把 416 也当成功）
泄信息   : model/manuf 在 query 明文；错误页泄露 Servlet 类名 + Jetty 版本
客户端   : TrustManager 空校验 + HTTP 降级 + 固定 GCM IV
```

---

*本文为 **systemhelper** 研究集的一部分 · 许可 [CC BY 4.0](../LICENSE) · [返回目录](../README.md)*
