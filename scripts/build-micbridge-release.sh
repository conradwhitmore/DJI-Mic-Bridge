#!/bin/bash
# Builds distributable development-test artifacts; never installs or publishes them.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
# Public test artifacts must not inherit a developer's personal certificate.
export MICBRIDGE_SIGNING_IDENTITY=-
export MICBRIDGE_DRIVER_SIGNING_IDENTITY=-
unset MICBRIDGE_INSTALLER_SIGNING_IDENTITY
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/MicBridge/Info.plist)
release_dir="$project_root/dist/releases/$version"
mkdir -p "$release_dir"
for architecture in arm64 x86_64; do
    case "$architecture" in arm64) label=AppleSilicon ;; x86_64) label=Intel ;; esac
    package="$release_dir/MicBridge-$version-$label.pkg"
    MICBRIDGE_APP_ARCH="$architecture" MICBRIDGE_DRIVER_ARCHS="$architecture" \
      MICBRIDGE_INSTALLER_OUTPUT="$package" bash scripts/build-micbridge-installer.sh
    python3 scripts/verify-micbridge-installer.py --package "$package" --arch "$architecture" --signing adhoc
    # The release-wide checksums below use portable relative paths.
    rm -f "${package%.pkg}.sha256"
done
cp dist/MicBridgeAudio-Source.tar.gz "$release_dir/MicBridgeAudio-Source.tar.gz"
cp LICENSE THIRD_PARTY_NOTICES.md "$release_dir/"
cat > "$release_dir/INSTALL.txt" <<NOTES
MicBridge $version — V2 开发测试安装包 / Development test packages

选择与你的 Mac 芯片匹配的一个安装包：
- MicBridge-$version-AppleSilicon.pkg：Apple Silicon / M 系列（arm64）
- MicBridge-$version-Intel.pkg：Intel（x86_64）
系统要求：macOS 13 或更新版本。两套均包含 App 与 MicBridge Audio 驱动。
不需要另装 BlackHole。MicBridgeAudio-Source.tar.gz 为 GPL 驱动的对应修改源码。

安装前从 MicBridge 菜单选择“仅本次退出”；首次安装驱动后重启 Mac。
随后在系统设置中配对 Mic 2 或 Mic Mini 2，打开 MicBridge，允许蓝牙权限。
设置热键时按系统提示允许辅助功能；在接收软件选择 MicBridge Audio 输入。

这是未公证的开发测试包，不适合生产环境。App/驱动仅使用 ad-hoc 签名，
不使用个人 Apple 证书，pkg 安装器未签名。
若 macOS 阻止打开安装包，请到“系统设置 → 隐私与安全性”选择“仍要打开”，
再确认并按安装器提示授权。首次启动 App 如被拦截，按同样方式确认。
不需要关闭 SIP 或全局 Gatekeeper。更新后蓝牙、麦克风或辅助功能权限可能需要重新授权。
本脚本不自动申请 Apple 公证。请勿将这些文件标为已公证发行版。
使用 pkgutil --check-signature <安装包> 可检查安装器签名。
本次 ad-hoc 包已完成编译、架构、签名及包结构检查；尚未完成其他 Mac 的安装及硬件实测。
已知问题：部分 Mic 2 的 RFCOMM MTU 666 会话会缺失设备信息/按键事件，并出现音频丢字。
此版本未包含 MTU 666 兼容绕过方案，需自行评估稳定性。

Select the AppleSilicon or Intel installer for your Mac; macOS 13+ is required.
Each installer includes the app and MicBridge Audio driver. BlackHole is not required.
Quit MicBridge before installing; restart after first driver installation.
The app and driver are ad-hoc signed, with no personal Apple certificate; the pkg
is unsigned and unnotarized. If blocked, use System Settings > Privacy & Security >
Open Anyway for the installer and, if needed, the app. Do not disable SIP or Gatekeeper.
Permissions may need granting again after updates. These packages have passed static
checks, but installation and hardware validation on other Macs remain pending.
Known issue: some Mic 2 MTU 666 sessions lose metadata/key events and drop audio.
Experimental development use only; not suitable for production.
NOTES
(cd "$release_dir" && shasum -a 256 "MicBridge-$version-AppleSilicon.pkg" "MicBridge-$version-Intel.pkg" \
    MicBridgeAudio-Source.tar.gz LICENSE THIRD_PARTY_NOTICES.md INSTALL.txt > SHA256SUMS.txt)
printf '%s\n' "$release_dir"
