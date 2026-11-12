# 构建

## 环境

- macOS，Xcode（包含 XCTest、macOS SDK）及 Swift 5.10 或更新版本。
- Python 3.9+、Git；核心依赖已放在 Vendor，不需要额外下载 Swift 包。
- `xcode-select -p` 应指向所用 Xcode 的 Developer 目录。
- App 默认构建当前主机架构；`MICBRIDGE_APP_ARCH=arm64` 或 `x86_64` 可指定架构。驱动默认构建两种架构；发行脚本分别生成两套单架构安装包。

## 离线检查

```sh
swift test
python3 -m unittest discover -s scripts/diagnostics/tests -v
python3 -m unittest discover -s scripts/tests -p test_public_privacy.py -v
python3 scripts/check-micbridge-transport.py
swift build -c release --product MicBridge
swift build -c release --product RXlessDemo
```

测试使用合成数据和模拟系统操作，不连接蓝牙、不录音、不重置系统。CI 运行相同的核心检查；真实按键、音质和恢复验证需要单独的硬件测试。

## App 签名

App 默认使用 **ad-hoc 签名**，不读取本机签名配置或自动选择钥匙串证书。直接运行：

```sh
bash scripts/build-micbridge.sh
```

仅当你主动选择个人开发签名时，才显式设置 `MICBRIDGE_SIGNING_IDENTITY` 为自己的证书 SHA-1。签名证书会公开开发者身份，个人签名构建不要作为匿名公开包分发。脚本不导出私钥。公开发行脚本始终强制 ad-hoc，不继承该变量。

```sh
security find-identity -v -p codesigning
export MICBRIDGE_SIGNING_IDENTITY="YOUR_CERTIFICATE_SHA1"
bash scripts/build-micbridge.sh
```

产物：`dist/MicBridge.app`。如需隔离输出，可设置 `MICBRIDGE_APP_OUTPUT` 为新的 App 路径。缺少产品渲染图时使用现有系统麦克风符号，构建不需要下载图片。

## 驱动与一体化安装包

```sh
bash scripts/build-micbridge-installer.sh
python3 scripts/verify-micbridge-installer.py
```

脚本只生成文件，不调用安装器。产物：

- `dist/MicBridge-Installer.pkg`：App + MicBridge Audio HAL 驱动。
- `dist/MicBridgeAudio-Source.tar.gz`：GPL 驱动的相应修改源码及构建脚本；App 内也包含该源码包。
- `dist/MicBridge-Installer.sha256`：校验摘要。

安装到 `/Applications/MicBridge.app` 和 `/Library/Audio/Plug-Ins/HAL/MicBridgeAudio.driver`，首次驱动安装要求管理员授权及重启。已有 BlackHole 保留。普通 App 更新无需重装不变的驱动。

单独重建驱动：`bash scripts/build-micbridge-audio-driver.sh`，默认本地 ad-hoc 签名；通过 `MICBRIDGE_DRIVER_SIGNING_IDENTITY` 指定其他身份。组合安装包使用 App 选定的签名身份。可用 `MICBRIDGE_DRIVER_ARCHS` 控制驱动架构。

开发签名和 ad-hoc 签名均不等于 Apple 公证。需要通过正常 Gatekeeper 校验的正式发行版应使用 Developer ID Application / Installer 签名及 Apple 公证；`MICBRIDGE_INSTALLER_SIGNING_IDENTITY` 仅控制 pkg 签名，不自动公证。

## Apple Silicon 与 Intel 开发测试包

```sh
bash scripts/build-micbridge-release.sh
```

公开测试包脚本固定使用 ad-hoc App/驱动签名及未签名 pkg，忽略环境中的个人签名身份，不访问个人证书。驱动源码归档使用统一的 root/wheel 所有者元数据。直接从仓库检出的源码构建，保留设备渲染图。也可使用 GitHub Actions 云端构建，无需配置个人证书或签名密钥，见 [发行说明](RELEASING.md)。

当前版本号从 `Resources/MicBridge/Info.plist` 读取。输出到 `dist/releases/<版本号>/`：

- `MicBridge-<版本号>-AppleSilicon.pkg`：arm64 App + arm64驱动。
- `MicBridge-<版本号>-Intel.pkg`：x86_64 App + x86_64驱动。
- 驱动对应源码、许可、安装说明与 `SHA256SUMS.txt`。

脚本分别校验实际包内的App/驱动架构、版本、签名、系统依赖和GPL源码，不安装、不发布。可单独检查：

发布前会从可分发的可执行文件中移除调试映射，并检查实际安装包及内嵌归档中的个人路径、邮箱、设备地址和常见凭据。驱动源码归档保留重建所需源码和第三方署名，文件所有者统一为 root/wheel。自动检查不替代源码及截图的人工复核。

```sh
python3 scripts/verify-micbridge-installer.py --package /path/to/package.pkg --arch arm64 --signing adhoc
```

产物是未公证的开发测试包，安装器未签名。若 macOS 拦截安装包，进入“系统设置 → 隐私与安全性”点击“仍要打开”，再完成安装授权；首次打开 App 如被拦截，也按同样方式确认。不要关闭 SIP 或全局 Gatekeeper。更新后蓝牙、麦克风或辅助功能权限可能需要重新授权。两种架构均需在目标机器验证安装、驱动加载、蓝牙、收音、按键和退出行为，静态检查不能代替实机验证。首次驱动安装需管理员权限并重启。

已知 MTU 666 会话可能缺失固件/按键状态并导致音频丢字，0.4.2 未包含对此的兼容绕过。本软件仅供开发测试，不适合生产使用。

## 独立研究 Demo

```sh
bash scripts/build-demo.sh
```

生成 `dist/DJI Mic RXless Demo.app`，使用 ad-hoc 签名。Demo 与 MicBridge 不应同时连接同一发射器。Demo 保持严格音频序号检查，与 MicBridge 的跳号容忍行为不同。

## 更新正在运行的 App

更新App时选择“仅本次退出”，等App恢复普通按键并关闭通道后再替换bundle，无需发送 `12/65`。只有准备恢复普通蓝牙麦克风时才使用“断开设备”或对应退出选项。不要覆盖运行中的可执行文件。若退出被阻塞，先按 [恢复说明](RECOVERY.md) 处理设备，不强杀后自动重连。
