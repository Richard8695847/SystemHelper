# 样本溯源

> **本仓库不托管 APK。** 这里给的是**指纹**与**获取方法**——足够让任何人在自己设备上确认"我手上这份是不是同一份"，而不需要从第三方仓库下载来路不明的二进制。

## 一、三个版本的指纹

| 版本 | 文件名（原始） | 大小 | SHA-256 | MD5 |
|---|---|---|---|---|
| 1.2-20220907 | `SystemHelper-com.mobiletools.systemhelper-1.2-20220907.apk` | 1,685,429 B | `416d0fc0405fc19b243e72f2a7963517e5b88991a7dfac494934449969a6015d` | `8e9df43efd6d898f6db46053e69d37fb` |
| 3.0.1-20260313 | `SystemHelper_3.0.1-20260313(1).apk` | 3,831,041 B | `1de8d965e295db27e189aa179cdb45438d7f759cffbb43ce55f840b614ff6c65` | `9b68bd6b627a0e35b158a86e25ed9dc8` |
| 4.0.0-20260910 | `SystemHelper.apk` | 3,884,625 B | `42fbfebedd8711b2ca22d3d969324f7ed7c757d838e143bf6cf4d2e8e1ed8556` | `11ee024eb1a9fe68a9c403a23c882fd0` |

同一份清单也放在 [`SHA256SUMS.txt`](SHA256SUMS.txt)，可直接 `sha256sum -c`。

## 二、签名身份（用于判断"这是哪个渠道的构建"）

| 版本 | 签名主体 | 证书有效期 | 说明 |
|---|---|---|---|
| 1.2 | `CN=NewDM, OU=RI, O=CU, L=BJ, ST=BJ, C=86` | 2019-03-21 → 2069-03-08 | 联通自签调试证书，50 年有效期 |
| 3.0.1 | `CN=MIUI, O=Xiaomi` | — | 小米平台密钥；同 `versionName` 存在按 OEM 批次重打的多个构建 |
| 4.0.0 | `CN=NewDM, OU=RI, O=CU, L=BJ, ST=BJ, C=86` | — | 与 1.2 同一签名主体；报文公钥换成 `cudms_main_pub.cer`（RSA-2048） |

签名 SHA-1（1.2 / 4.0）：`0D:0B:1F:90:18:23:91:C7:75:04:B8:43:DD:39:37:B2:3D:74:9A:E6`
签名 SHA-1（3.0.1，MIUI）：`7B:6D:C7:07:9C:34:73:9C:E8:11:59:71:9F:B5:EB:61:D2:A0:32:25`

## 三、从你自己的设备取（推荐路径）

```bash
# 1) 先确认包在不在、什么版本
adb shell dumpsys package com.mobiletools.systemhelper | grep -E "versionName|versionCode"

# 2) 拿到 APK 的真实路径
adb shell pm path com.mobiletools.systemhelper
#   典型输出：package:/system/priv-app/SystemHelper/SystemHelper.apk
#            package:/product/priv-app/SystemHelper/SystemHelper.apk
#            package:/data/app/.../base.apk   （升级安装过的情况）

# 3) 拉出来（/system、/product 下的文件通常需要 root 或先从固件包提取）
adb pull /system/priv-app/SystemHelper/SystemHelper.apk

# 4) 校验
sha256sum SystemHelper.apk
```

没有 root 时，也可以从对应机型的官方固件包（`super.img` / `product.img` / `system.img`）里解出该路径下的文件，得到的是同一份二进制。

## 四、校验通过之后能确认什么

- **是同一份构建**：SHA-256 一致即为逐字节相同，报告里的 `文件:行号` 可以直接对上。
- **不是同一份**：`versionName` 相同也可能是不同 OEM 批次的重打包（例如外部观察到 vivo 机型上的 `3.0.1-20251230`）。这类样本行为可能有差异，值得单独记录并提 Issue。

## 五、为什么不做"一键安装"

这个包是 `priv-app` 组件，靠**平台签名**获得 `READ_PRIVILEGED_PHONE_STATE`、`PACKAGE_USAGE_STATS`、`QUERY_ALL_PACKAGES`。侧载一份普通签名的副本：

- 权限拿不到 → 读不到 IMEI/IMSI，服务起不来；
- 系统不把它当特权组件 → 开机广播、JobScheduler 保活的行为全部不同。

**装上也复现不了任何东西。** 要验证结论，请用静态分析（jadx 打开同一份 APK），要观察行为，请用自己的设备 + 抓包。

## 六、与 Release 的关系

Release 里放的是**分析集**（报告、IOC、证书、站点离线副本）与 `SHA256SUMS.txt`，用于版本归档与 CDN 分发。二进制本体不在其中。

若你从别处获得了 APK，请先用上面的 SHA-256 校验，再决定是否使用——未经校验的第三方样本包不值得信任，对研究结论更是污染源。
