<div align="center">
  <img src="docs/icon.png" alt="Reloc Icon" width="96" height="96" />
  <h1>Reloc</h1>
  <p><strong>面向 iPhone 与 iPad 的本机虚拟外设定位模拟工具</strong></p>
  <p>
    基于 Swift 与 Objective-C 构建 · 支持简体中文与英文 · 通过本机虚拟外设实现外设级定位注入
  </p>
  <p>
    <a href="#系统兼容性"><img src="https://img.shields.io/badge/Platform-iOS%20%7C%20iPadOS%2017.0%2B-0A84FF?style=flat-square" height="20" /></a>
    <a href="#从源码构建"><img src="https://img.shields.io/badge/Stack-Swift%20%7C%20ObjC-F05138?style=flat-square" height="20" /></a>
    <a href="#免责声明与许可证"><img src="https://img.shields.io/badge/License-AGPL--3.0-red?style=flat-square" height="20" /></a>
  </p>
</div>

---

## 简介

**Reloc** 是一款运行在 iPhone 与 iPad 本机的外设级定位模拟应用。应用直接通过系统 `CoreAccessories` 在本机创建虚拟外设连接与 iAP2 端点，完成 iAP2 链路同步、MFi-v3 鉴权及 NMEA-0183（`$GPGGA` / `$GPRMC`）报文流式下发，使系统以标准外设 GPS 身份接收实时坐标。

**无需实体外设、无需电脑、无需设备配对文件、无需代理回环、VPN 或依赖 Wi-Fi**，蜂窝网络下同样可单机完成定位注入。

---

## 核心功能

| 模块 | 能力说明 |
| :--- | :--- |
| **定格定位** | 地图点击选点、视野内实时搜索联想与地址搜索、手动输入 WGS-84 坐标与海拔、自动查询真实地形海拔、多级反地理编码兜底、运行中浏览并热更新目标位置 |
| **多源地图与纠偏** | 默认使用 **Apple 地图（MapKit 原生）** 并支持中国大陆 GCJ-02 ↔ WGS-84 自动双向纠偏；同时内置免 API Key 的 **全球街道图（Esri） / OpenStreetMap / 全球卫星图** 纯原生 WGS-84 瓦片地图（无高德字样）；可选 ±0.6 m 自然微漂移（含细微海拔波动） |
| **本机直连与刷新** | 直接在本机创建虚拟外设通道，断线自动退避重连；系统缓存顽固时提供 **一键刷新定位服务（画中画悬浮 7 秒倒计时）**；停止时自动释放本机端点并支持真实定位恢复 |
| **后台保活** | 后台定位与音频保活双保险、断线自动重连，切换到其他 App 后持续生效 |
| **数据与实测** | 收藏夹、最近记录、异常中断一键恢复；内置简体中文与英文双语切换；内置 `CoreLocation` 实测面板（外设来源标志 `isProducedByAccessory` / 模拟标志 `isSimulatedBySoftware`）与协议日志 |

---

## 系统兼容性

| 设备 / 系统 | 支持状态 | 说明 |
| :--- | :---: | :--- |
| **iPhone · iOS 17.0+** | 支持 | 最低构建目标为 iOS 17.0；已在未越狱真机上验证通过，其他系统版本仍需实测 |
| **iPad · iPadOS 17.0+** | 支持 | 已开放 iPad 支持并在真机测试通过，支持 Wi-Fi 与蜂窝版 iPad |

> 本机虚拟外设通道仍需有效的 **MFi-v3** 凭据才能通过系统的外设鉴权。

---

## 使用方式

1. 打开 Reloc，在 **「定位」** 页通过地图选点、地址搜索或手动输入 WGS-84 坐标（自动匹配地形海拔，也支持手动修改），点击 **开始定位**。
2. 若开始定位后系统位置尚未切换，点击首页的 **「一键刷新定位服务」**，按画中画浮窗提示关闭系统「定位服务」，等待 7 秒后重新开启。
3. 首页显示 **「外设定位已生效」** 后，即可切换到其他 App 使用。
4. 结束时点击 **「停止并恢复」**；若系统仍保留旧位置缓存，可按提示执行恢复真实位置的刷新流程。

> 协议握手与数据 ACK 仅代表报文已送达外设通道，定位是否真正生效请以首页状态或 **「实测与日志」** 页的 `CoreLocation` 实测坐标及外设来源标志为准。

---

## 从源码构建

### 环境要求

- macOS 与 Xcode
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）

项目采用纯 Swift + Objective-C 实现，无需 Rust 或额外桥接库。

### 1. 准备 MFi-v3 凭据

自行准备有效的 MFi-v3 凭据并放入以下本地路径（已配置 `.gitignore`，请勿提交到仓库）：

- `Reloc/Resources/MFi/certificate.p7b`
- `Reloc/Resources/MFi/identity.pk8`

### 2. 生成工程并构建

```bash
xcodegen generate

xcodebuild build \
  -project Reloc.xcodeproj \
  -scheme Reloc \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

### 3. 打包未签名 IPA（可选）

```bash
rm -rf build/Payload && mkdir -p build/Payload
ditto build/DerivedData/Build/Products/Release-iphoneos/Reloc.app build/Payload/Reloc.app
(cd build && zip -qr Reloc.ipa Payload)
```

在 Xcode 中配置自己的签名直接安装，或对打包后的 `build/Reloc.ipa` 自行签名安装。应用 Bundle ID 为 `dev.reloc.ios`，显示名称为 `Reloc`。

---

## 常见问题

<details>
<summary><strong>1. 开始定位或停止定位后，系统位置没有立刻切换 / 恢复？</strong></summary>

定位数据进入 `locationd` 后仍可能受到系统筛选与缓存策略影响：

- **开始定位后未切换**：点击首页的 **「一键刷新定位服务」**，按画中画浮窗提示关闭系统「定位服务」7 秒后再重新开启，即可促使系统立即切换到外设定位源。
- **停止定位后仍停留在旧位置**：Reloc 停止时会释放本机外设端点并恢复本机定位；若室内弱信号下系统仍缓存上次位置，使用停止后的刷新流程即可恢复真实定位。
</details>

<details>
<summary><strong>2. 为什么协议日志显示握手 / ACK 成功，但地图位置没有变化？</strong></summary>

iAP2 握手与 NMEA ACK 仅表示数据已成功发送至本机虚拟外设通道，不代表 `locationd` 已采纳该坐标作为当前定位源。请结合首页状态和 **「实测与日志」** 页的 `CoreLocation` 实测数据与 `isProducedByAccessory` 标志判断，必要时执行一次定位服务刷新。
</details>

<details>
<summary><strong>3. 为什么默认 Apple 地图在中国大陆会显示「高德地图」？</strong></summary>

受中国大陆测绘合规要求影响，iOS 原生 `MapKit` 在中国大陆环境下会自动使用高德地图底图与角标。如需无高德字样的纯国际 WGS-84 地图，可在地图右侧图层按钮或 **「设置」** 页切换为 **全球街道图 / OpenStreetMap / 全球卫星图**（全部免 API Key）。
</details>

---

## 免责声明与许可证

> **免责声明**：本项目仅用于外设定位通信协议研究、应用开发调试与自动化测试。使用者须严格遵守所在地区法律法规及目标服务的使用条款，因滥用本软件产生的一切后果由使用者自行承担。

本项目依据 **GNU Affero General Public License v3.0 (`AGPL-3.0-only`)** 开源发布，完整条款请参阅 [LICENSE](./LICENSE)。任何基于本项目的修改版本在分发或通过网络提供交互服务时，均须在相同 AGPL-3.0 协议下公开完整对应源代码。
