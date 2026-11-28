<div align="center">
  <img src="docs/icon.png" alt="Reloc Icon" width="96" height="96" />
  <h1>Reloc</h1>
  <p><strong>面向 iPhone 与 iPad 的本机虚拟外设定位模拟工具</strong></p>
  <p>
    基于 Swift 与 Objective-C 构建 · 支持简体中文与英文 · 通过本机虚拟外设实现外设级定位注入
  </p>
  <p>
    <a href="#系统兼容性"><img src="https://img.shields.io/badge/Platform-iOS%20%7C%20iPadOS%2016.0%2B-0A84FF?style=flat-square" height="20" /></a>
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
| **轨迹模拟** | 首页一键切换「定格 / 轨迹」模式；地图选起终点（支持多途经点）自动沿真实道路规划轨迹并自动匹配地形海拔曲线；内置步行 / 跑步 / 骑行 / 驾车 4 档预设与实时自由调速、拟真配速波动与转弯减速、细微路径横向漂移；支持单次定格 / 折返往返 / 闭合循环、暂停/继续与收藏常用路线 |
| **多源地图与纠偏** | 默认使用 **Apple 地图（MapKit 原生）** 并支持中国大陆 GCJ-02 ↔ WGS-84 自动双向纠偏；同时内置免 API Key 的 **全球街道图（Esri） / OpenStreetMap / 全球卫星图** 纯原生 WGS-84 瓦片地图（无高德字样）；可选 ±0.6 m 自然微漂移（含细微海拔波动） |
| **本机直连与刷新** | 直接在本机创建虚拟外设通道，断线自动退避重连；系统缓存顽固时提供 **一键刷新定位服务（画中画悬浮 7 秒倒计时）**；停止时自动释放本机端点并支持真实定位恢复 |
| **长时后台保活** | 纯原生定位后台运行（已移除常驻静默音频保活，无音频冲突与额外功耗）、事件驱动低唤醒循环、单调时钟防校时卡死、瞬态断线与意外退订自动退避自愈 |
| **快捷指令** | 精简 2 项高频原生 Apple 快捷指令动作：**开始虚拟定位**（弹窗选收藏点 → 启动定位 → 拉起 7 秒浮窗并跳转系统定位页清除缓存）与 **关闭虚拟定位**（恢复真实 GPS） |
| **数据与实测** | 收藏夹、最近记录、异常中断一键恢复；内置简体中文与英文双语切换；内置 `CoreLocation` 实测面板（外设来源标志 `isProducedByAccessory` / 模拟标志 `isSimulatedBySoftware`）与协议日志 |

---

## 系统兼容性

| 设备 / 系统 | 支持状态 | 说明 |
| :--- | :---: | :--- |
| **iPhone · iOS 16.0+** | 支持 | 已在 iOS 16.0 及以上未越狱真机实测通过 |
| **iPad · iPadOS 16.0+** | 支持 | 已在 iPadOS 16.0 及以上真机实测通过，支持 Wi-Fi 与蜂窝版 iPad |

> 本机虚拟外设通道仍需有效的 **MFi-v3** 凭据才能通过系统的外设鉴权。

---

## 使用方式

1. 打开 Reloc，在 **「定位」** 页通过地图选点、地址搜索或手动输入 WGS-84 坐标（自动匹配地形海拔，也支持手动修改），点击 **开始定位**。
2. 若开始定位后系统位置尚未切换，点击首页的 **「一键刷新定位服务」**，按画中画浮窗提示关闭系统「定位服务」，等待 7 秒后重新开启。
3. 首页显示 **「外设定位已生效」** 后，即可切换到其他 App 使用。
4. 结束时点击 **「停止并恢复」**；若系统仍保留旧位置缓存，可按提示执行恢复真实位置的刷新流程。

> 协议握手与数据 ACK 仅代表报文已送达外设通道，定位是否真正生效请以首页状态或 **「实测与日志」** 页的 `CoreLocation` 实测坐标及外设来源标志为准。
>
> **远距离轨迹提示**：本地 15 km 以内轨迹在正常开启 Wi-Fi 与蜂窝网络下即可持续平滑移动；如模拟距离真实位置超过 15 km 的跨城/跨国连续轨迹，建议开启飞行模式以避免系统 `CLNmeaScreener` 按附近 Wi-Fi/基站回弹坐标。

---

## 快捷指令

Reloc 精简提供 2 项日常最常用的 iOS 原生 **Apple 快捷指令（App Intents）**：

| 动作名称 | 功能说明 |
| :--- | :--- |
| **开始虚拟定位** | 弹窗选择收藏地点（或固定某点）→ 启动虚拟外设定位 → 自动拉起 7 秒画中画倒计时并跳转系统「定位服务」页，开关一次即可清除定位缓存（同时输出 `prefs:root=Privacy&path=LOCATION`，方便自行衔接快捷指令「打开 URL」） |
| **关闭虚拟定位** | 断开虚拟外设通道 → 拉起 7 秒恢复倒计时浮窗并自动跳转系统「定位服务」页清除残留缓存，快速切回本机真实 GPS（同样输出 `prefs:root=Privacy&path=LOCATION`） |

> 建议在系统设置中将 Reloc 的定位权限设为 **「始终」**，以保证切换至其他 App 或锁屏后的长时后台稳定性。

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

<details>
<summary><strong>4. 为什么轨迹定位不生效、出发后不动或中途回弹？</strong></summary>

轨迹定位不生效通常由以下两类系统机制引起：

1. **尚未在起点完成外设锁定**：为避免系统还未切换到外设源就空跑路线，Reloc 启动轨迹后会先在起点高频发送 NMEA，直到 `CoreLocation` 实测确认外设来源（`isProducedByAccessory = true` 且与起点误差 `< 25 m`）后才会真正开始沿轨迹推进；若一直提示「等待锁定起点」，请先执行一次定位服务刷新。
2. **iOS 底层 `CLNmeaScreener` 远距离筛查拦截**：`locationd` 在接收外设 NMEA 时，会持续比对手机扫描到的附近 **Wi-Fi（约 15 km 阈值）** 与 **蜂窝基站 / LAC（约 1.4 km ~ 149 km 阈值）**：
   - **本地 15 km 以内轨迹**：正常开启 Wi-Fi 与蜂窝网络即可持续平滑移动；
   - **超过 15 km 的跨城 / 跨国轨迹**：一旦系统扫描到附近 Wi-Fi 或基站与模拟坐标距离过远，后续移动点位会被 `CLNmeaScreener` 拦截并退化为 `@ClxADL` 航位推算冻结或直接回弹到真实位置（此时 Reloc 会自动原地暂停等待重新锁定）。

**解决方法**：模拟距离真实位置 **超过 15 km** 的连续轨迹时，开启 **飞行模式**（关闭 Wi-Fi 与蜂窝基站定位），即可稳定持续沿道路移动。
</details>

<details>
<summary><strong>5. 为什么远距离（跨城 / 跨国）定位刷新后仍然不生效？</strong></summary>

画中画浮窗给出的 **7 秒倒计时** 仅是常规近距离场景下的参考时长，**不要完全死守 7 秒提示**：

- 远距离切换坐标时，iOS `locationd` 对本机真实 GNSS、Wi-Fi 与基站融合缓存的保留周期更长，仅关闭 7 秒后立即重新打开，系统仍可能沿用旧缓存并拒绝新的外设坐标。
- **解决方法**：如果重新开启「定位服务」后位置没有切换成功，请**再次关闭系统「定位服务」，耐心等待更长的时间（例如 15–30 秒，必要时可延长至 45–60 秒）后再重新启用**；若依然受附近网络干扰回弹，可同时暂时关闭 Wi-Fi 或开启飞行模式后再试。
</details>

<details>
<summary><strong>6. 为什么不能无限期长时间在后台运行（挂机一段时间后可能中断）？</strong></summary>

Reloc 的本机虚拟外设通道直接运行在 App 进程内，受非越狱 iOS 系统后台管控机制制约，无法像越狱系统守护进程（daemon）一样永久常驻：

1. **系统内存回收（Jetsam）**：在后台挂机期间，若前台使用相机、大型游戏、视频剪辑等高内存占用应用，iOS 会优先清理后台应用进程；一旦 Reloc 被系统终止，虚拟外设通道即刻断开，系统会逐步切回真实 GPS。
2. **后台定位权限与休眠策略**：若未将定位权限设为 **「始终」**，或设备开启了 **低电量模式**、长时间锁屏进入深度休眠，系统（RunningBoard / CoreLocation）会主动挂起或回收后台定位资格。
3. **后台周期性网络重校验**：长时间挂机时，系统 `locationd` 仍会定期通过 Wi-Fi / 蜂窝基站复核位置，远距离坐标可能因此被重新拦截或回弹。

**延长稳定运行时间的建议**：

- 在系统设置中将 Reloc 的定位权限设为 **「始终」** 并保持 **「精确位置」** 开启；
- 关闭 **低电量模式**，挂机期间尽量减少切换高内存消耗应用；
- 在设置页开启 **「自然微漂移」**，并可将 NMEA 发送间隔适当调大至 **2.0–3.0 秒** 以降低后台 CPU 唤醒频率与功耗；
- 若会话意外被系统回收，重新打开 Reloc 首页后可直接点击 **「恢复」** 一键续接上次定位。
</details>

---

## 免责声明与许可证

> **免责声明**：本项目仅用于外设定位通信协议研究、应用开发调试与自动化测试。使用者须严格遵守所在地区法律法规及目标服务的使用条款，因滥用本软件产生的一切后果由使用者自行承担。

本项目依据 **GNU Affero General Public License v3.0 (`AGPL-3.0-only`)** 开源发布，完整条款请参阅 [LICENSE](./LICENSE)。任何基于本项目的修改版本在分发或通过网络提供交互服务时，均须在相同 AGPL-3.0 协议下公开完整对应源代码。
