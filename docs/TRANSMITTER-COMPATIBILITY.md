# 其他发射器的兼容性研究

研究日期：2026-11-11；Mini 2 固件补充：2026-11-14。目标：不使用接收器，让其他 DJI 发射器直接向 Mac 提供音频、状态和按键事件，并能可靠退出连接。

**当前结论：Mini 2 已在独立 Demo 验证 SPP 清晰收音、连接键 capture、电源双击降噪状态代理以及 12/65 ACK 退出。MicBridge 0.5.1 已加入独立适配，双热键、首次 BLE 固件读取缓存及 SPP 电量显示已完成本机联合实测；Mini、Mic 3 仍处于协议研究阶段。** 已还原 Mini 2 02.03.17.00 的 TX/RX 固件，详见 [Mini 2 固件分析](MIC-MINI-2-FIRMWARE.md)和[按键实测结果](MIC-MINI-2-KEY-EVENTS.md#8-demo-012-实机结果)：工厂模式两键报告固定走 UART，但普通 SPP 的状态字节另有连接键事件路径；音频块实际采用 111 字节 LC3 数据加零尾部。App 为 Mini 2 使用单独的普通 SPP 适配器，不发送 Mic 2 的工厂按键或配置指令。

以下未特别标注的 SDK 证据及获取进展记录来自 2026-11-11 的 Mimo 2.12.1 静态分析；其中“未取得固件”是当时状态，Mini 2 已由上述新报告更新，Mini 与 Mic 3 尚无本轮固件分析。

## 分型号判断

| 型号 | Mimo 内部型号 | 已建立的证据 | 当前缺口 |
| --- | --- | --- | --- |
| DJI Mic Mini | DM300 | 独立 TX 控制类；状态、电量、降噪等绑定；另有开源 USB 接收器协议实现 | TX 的 SDP/RFCOMM 服务、SPP 音频格式、启动/退出流程 |
| DJI Mic Mini 2 | DM202 | 已还原固件；BLE 版本/电量、SPP 音频试听、普通 SPP 连接键 4 次短按均通过 | 电源键独立事件、长期稳定性、跨系统验收；SPP 精确电量与固件查询 |
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

MicBridge V2 的 Mic 2 按键监听已改为临时按键模式下的独立 `04/68` 事件，不再根据 `02/FF` 状态变化触发热键。新型号在上述 SDK 路径使用 `5B/03` 状态，不能把状态更新当作物理按键事件。

Mini 2 新固件分析找到 `04/68` 测试模式及两个独立事件，但进入/退出参数、事件格式和路由均与 Mic 2 不同，详见新报告。降噪、静音、录音状态变化可能来自 App 或接收器操作，不应代替物理按键原始事件。没有证据支持复制 Mic 2 的三键布局或字节偏移。

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
