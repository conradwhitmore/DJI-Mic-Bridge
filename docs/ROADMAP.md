# 架构与路线图

```text
Mic 2 TX → RFCOMM/SPP → FrameParser → LC3解码 → PCM
                          ├→ DUML → 按键/固件/电量/退出应答
                          └→ 实时缓冲 → MicBridge Audio → 第三方输入
                                     └→ WAV分段保存
```

App负责设备选择、路由保护、会话生命周期和界面；MicLinkCore负责帧、命令、解码与事件；MicBridgeSupport保留可离线测试的状态策略。HAL驱动作为独立进程加载，通过CoreAudio端点与App通信。

当前主线已完成SPP收音、系统麦克风桥接、快捷键映射、电量与ACK确认退出。下一步按证据推进：

1. 定位仅收音而缺少控制/按键状态包的情况，补充长时间连接验证。
2. 记录桥接延迟、缓冲欠载、CPU和多个接收软件的实测矩阵。
3. 完善设备/固件适配边界；参考 [Mini／Mini 2／Mic 3 静态研究](TRANSMITTER-COMPATIBILITY.md)，在取得音频与退出协议依据后扩展新型号。
4. 完成公开源码审阅、许可证及资源整理，再进行签名、公证和发行。

不通过盲发命令、自动重置蓝牙、自动清配对或循环连接来掩盖故障。
