适用于 macOS 13 及更新版本的开发测试预览版，与 DJI 无隶属或背书关系。

- **Apple Silicon / M 系列**：选择 `AppleSilicon.pkg`。
- **Intel**：选择 `Intel.pkg`。
- 两套均包含 MicBridge App、MicBridge Audio 驱动及原设备渲染图，无需另装 BlackHole。

App 和驱动使用 **ad-hoc 签名**，不使用个人 Apple 证书；pkg 未签名、未经 Apple 公证。仅当 macOS 拦截打开时，进入“系统设置 → 隐私与安全性”选择“仍要打开”。没有拦截提示则直接继续，无需关闭 SIP 或 Gatekeeper。

更新前在 MicBridge 选择“仅本次退出”，然后安装新包；按安装器提示重启 Mac。安装、使用及卸载步骤见 [README](https://github.com/conradwhitmore/DJI-Mic-Bridge#安装)。

### 已知问题与验证范围

部分连接会协商到 RFCOMM MTU 666，表现为已有 SPP 电平，但固件、电量或按键事件缺失，录音也可能丢字或不连续。目前没有可靠修复；首次连接无法获取固件信息时，可以尝试重新连接蓝牙并重启 Mic 2，但不能保证恢复。欢迎有 Bluetooth Classic/RFCOMM、macOS 蓝牙或嵌入式协议经验的开发者通过 [Issues](https://github.com/conradwhitmore/DJI-Mic-Bridge/issues) 协助调查，提交前请脱敏日志。

GitHub Actions 执行离线测试，并检查两种架构的安装包、签名、驱动源码及设备图片。云端校验不代表真实蓝牙设备或音质验收。**本项目仍处于实验阶段，不适合生产或关键录音场景。**

随附 `MicBridgeAudio-Source.tar.gz` 为 GPL 驱动对应修改源码与构建脚本。将附件下载到同一目录后，可执行 `shasum -a 256 -c SHA256SUMS.txt` 校验。

---

Development preview for macOS 13+. Choose the AppleSilicon or Intel installer; both include the app, audio driver, and device artwork. The app and driver are ad-hoc signed without personal Apple certificates. The pkg is unsigned and unnotarized. Only if blocked, use System Settings → Privacy & Security → Open Anyway.

Some RFCOMM MTU 666 sessions have audio levels but missing metadata/key events and audio dropouts. There is no reliable fix yet. Bluetooth reconnection and a Mic 2 restart may help but are not guaranteed. Contributions with sanitized diagnostics are welcome. Cloud checks do not replace hardware/audio testing. Experimental use only, not for production. Modified GPL driver source and checksums are included.
