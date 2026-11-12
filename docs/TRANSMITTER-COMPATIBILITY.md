# 其他发射器的兼容性研究

研究日期：2026-11-11。目标：不使用接收器，让其他 DJI 发射器直接向 Mac 提供音频、状态和按键事件，并能可靠退出连接。

**当前结论：Mini、Mini 2、Mic 3 有可复用的控制协议基础，但尚不能确认兼容 MicBridge 的 SPP 音频与退出流程。** 本轮没有取得这三个型号的发射器固件明文；下面的二进制结论来自 Mimo 2.12.1 的静态分析，不能称为发射器固件反汇编结果。现有 App 继续只启用 Mic 2 适配器。

## 分型号判断

| 型号 | Mimo 内部型号 | 已建立的证据 | 当前缺口 |
| --- | --- | --- | --- |
| DJI Mic Mini | DM300 | 独立 TX 控制类；状态、电量、降噪等绑定；另有开源 USB 接收器协议实现 | TX 的 SDP/RFCOMM 服务、SPP 音频格式、启动/退出流程 |
| DJI Mic Mini 2 | DM202 | 独立 TX 控制类；与 DM300 共用状态处理函数；开源项目报告支持 Mini 2 的 USB 控制 | 同上；不能因为共用 Mini 接收器而推定 TX 蓝牙协议相同 |
| DJI Mic 3 | DM303 | 独立 TX 控制类；比 Mini 系列多出录音、时间码、增益、存储等状态绑定 | 同上；还需区分型号特有的控制、状态版本和连接路径 |

型号映射已从 APK 的 `resources.arsc` 独立读取：`dm300_product_name`、`dm202_product_name`、`dm303_product_name` 分别对应上述产品名，不靠数字顺序猜型号。DM202 是 Mic Mini 2，DM303 才是 Mic 3。

## 二进制证据

输入为 Mimo 2.12.1 Android ARM64 APK（版本代码 10001997）：

- APK SHA-256：`877cce18fb21cbdb6e025965e7eab4b06d823675428f61b14f641b719454c2a2`
- `libdjisdk_jni.so` SHA-256：`0447d87a172b196b63d2f0f7d5fa6e83d422728e51c39471a3f0ea1ad81a8551`
- 地址均为该 ELF 的虚拟地址。分析时仅在副本修复 ELF 元数据以便读取符号；没有执行目标库、安装 APK 或发送设备命令。

### 1. 三款 TX 共用一条状态协议路径

| 类 | `ObserverPushPack` 地址 | 状态绑定数 |
| --- | --- | --- |
| `DM300TXAudioAbs` | `0x1fbe530` | 11 |
| `DM202TXAudioAbs` | `0x2085028` | 11 |
| `DM303TXAudioAbs` | `0x20299f8` | 43 |

三者分别在 `0x1fbe554`、`0x208504c`、`0x2029a1c` 调用同一 `audio_wireless_mic_status_push` observer helper。helper 经 `0x1fbff3c` 进入注册函数；`0x1fbf730` 与 `0x1fbf744` 组成注册键 `0x405b0003`，`0x1fbf74c` 调用 `RegisterObserver`，建立 `5B/03` 的命令关联。

Mini 与 Mini 2 都绑定 `IsWlMicMuteOn`、`IsWlMicDeNoiseOn`、`MicSampleLevel`、`TXBatteryIsBeingCharged`、`TXChargeRemaining` 等状态。Mic 3 还绑定 `TxMicRecord`、`TXMicDeviceTimeCode`、`TxMic32bit`、`WlMicRemainRecordableDuration` 等。

三个 TX 的 `GetAbsSenderHostID` 都返回 SDK 内部值 `0x011a`。**这不是可直接写入 DUML 单字节地址的值**；仍需核对 SDK 地址编码与实际传输端点。

这证明可以考虑共用状态解析基础，但不证明它们会通过 Mac 可访问的 SPP 通道发送这些包。`MicSampleLevel` 也只代表电平信息，不等于可解码的音频样本。

### 2. 电量不能照搬 Mic 2 的百分比解析

`TXChargeRemaining` 的回调绑定经 GOT `0x275c340` 指向 `KeyTXChargeRemainingPush`（`0x1fd86f0`）。该函数：

- 默认输出 `0xff`；
- 只在传入状态结构首字节为 `1` 时取值；
- 在 `0x1fd8768` 读取结构偏移 `+3` 的 16 位值；
- 在 `0x1fd876c` 执行 `UBFX #10, #3`，得到 **0–7 的档位**。

这里的偏移针对回调接收的状态结构，尚未建立为所有传输格式的原始包偏移。不能直接把此偏移用于 SPP，更不能乘一个系数伪装成准确百分比。其他状态版本也可能通过别的回调提供电量。

Mic 2 当前的 `05/06` 查询返回百分比，属于另一条已经实测的路径；本轮没有证明这条查询能用于其他型号。

### 3. 按键监听需要分别设计

Mic 2 目前根据 `02/FF` 中的状态变化判断连接键、降噪键、录音键事件。新型号在上述 SDK 路径使用 `5B/03`，状态结构也不同。

可以进一步研究降噪、静音、录音状态变化作为事件来源，但状态变化可能来自 App 或接收器操作，不能自动当作物理按键原始事件。没有看到相同的三键事件布局，也没有证据支持复制 Mic 2 的字节偏移。

## 开源项目交叉参考

[DJI Mic Control 的协议文档](https://github.com/ShadowBitBasher/DJI-Mic-Control/blob/9ba76880807a71d4eaba74c785dbee186a98f43b/PROTOCOL.md)记录了 Mini／Mini 2 接收器的 USB 控制路径，固定参考提交 `9ba76880807a71d4eaba74c785dbee186a98f43b`。它涉及 `5B/01` 设置和 `5B/03` 状态，且区分新旧固件布局，与本轮 SDK 分析的状态命令关联相符。

该项目的音频入口是接收器，不能证明 TX 直连 SPP 收音可用。其文档的个别 DUML 字段名称也不能照抄：例如帧偏移 4、5 在 MicBridge 的 DUML 解释中属于源/目的地址，并非命令集字段。复用时应以原始帧、CRC 和实际解析代码核对。

## 固件获取进展

- 官方 [Mini](https://www.dji.com/mic-mini/downloads)、[Mini 2](https://www.dji.com/mic-mini-2/downloads)、[Mic 3](https://www.dji.com/mic-3/downloads) 下载资料及[升级说明](https://repair.dji.com/help/content?customId=01700006836&documentType=&lang=en&paperDocType=ARTICLE&re=US&spaceId=17)指向 Mimo 更新流程。本轮没有找到可直接取得上述三个 TX 固件的下载链接。
- 检查了现有 Mimo APK 中 `.bin/.fw/.sig/.cfg/.ini` 候选，未发现这些 TX 的固件包；命中的 `.bin` 主要是图像处理模型与应用元数据。
- `libDJIUpgradeCore.so` 含 `GetServerCfgRequest`、`GetCfgVersionInfosRequest`、`GetCfgModuleDownloadUrlRequest`，以及 `loadconfig/geturl`、`getfile/getallfile`、`getfile/download` 等线索。完整请求参数、认证要求及响应尚未闭合，不能把字符串当作可用固件 URL。
- 本轮查看的 DankDroneDownloader 型号选择器未列出这些麦克风。第三方版本跟踪页有 Mic 3/DM303 的版本记录，但详情只给出版本和更新说明，没有固件下载；不是已取得固件的证据，也不作为最新版本的权威来源。

Mimo 的版本管理/控制库不是 TX 固件本身。尚未验证新型号的处理器、固件容器、加密方式；不能预设它们也使用 Mic 2 的 C-SKY 和 34 字节块解码方式。

## 后续适配顺序

1. 优先追 Mini／Mini 2：已有共享状态路径和独立开源控制证据。获取真实 TX 固件或最小通信样本，先确认 SDP 服务、RFCOMM 通道及是否存在音频流。
2. 对实际音频流检查封装、codec、帧长、采样率、序号与初始化条件；不能仅因同为 OsmoAudio 就套用 Mic 2 的 125 字节 LC3plus 帧。
3. 独立确认退出机制。当前只有 Mic 2 经过 `12/65 → 匹配 ACK 00 → 关闭 SPP → 恢复 HFP` 的实机验证，其他型号没有对应证据。
4. 状态协议按型号和版本解析；分别声明电量档位、百分比、按键事件等能力。确认后再增加适配器，不放宽现有 Mic 2 识别规则来试错。

没有其他硬件仍可继续推进升级接口、固件容器和 SDK 调用链研究；产品支持最终至少需要每款型号的一份连接/音频/状态样本及退出恢复记录。研究阶段不要求用户先购买硬件，可由后续测试者提供脱敏样本。

## 本轮校验与改动范围

本地离线核对通过：17 条关键 ARM64 指令、3 个产品资源映射、电量回调重定位；提取三个型号各 11／11／43 项状态绑定用于复核。这些是静态证据校验，不是硬件测试。

原始 APK、库、反汇编和校验脚本保存在被 Git 忽略的本地研究目录，不随开源源码分发。本轮只补充研究文档，未修改 App、Demo、驱动、蓝牙连接和音频路由。
