# 构建与发布

直接从仓库检出的代码构建，保留 `Resources/MicBridge/Devices` 中的设备渲染图。公开仓库仅维护当前 `main`，不携带本地归档分支或旧标签。发布只推送指定分支和经过检查的版本标签，不使用 `git push --all` 或 `git push --mirror`。

## GitHub Actions

工作流：`.github/workflows/release.yml`（**Build and release**）。构建运行在 GitHub 托管的 macOS runner，不需要上传 Apple 证书或配置签名 Secrets；发布使用仓库内置的 `GITHUB_TOKEN`。

- **唯一发布入口**：推送 `v<版本号>` 标签后，构建该标签指向的代码；版本必须与 `Resources/MicBridge/Info.plist` 的 `CFBundleShortVersionString` 一致。所有检查通过后，自动发布为 GitHub **Pre-release**，两份 pkg 放在 Release 附件中，不受 Actions 构建产物 14 天保留期限制。发布工作流不提供手动触发入口；普通 `main` 提交只运行 CI 检查。
- **失败重试**：重跑失败的工作流可继续未发布的草稿。已发布的 Release 不会自动覆盖；后续更新使用新版本标签。不要移动已经发布的标签。

发布新版本时，更新 App 版本号、构建号、相关文档及 `packaging/micbridge/release-notes.md`，提交并推送 `main`，再推送对应标签。例如，App 版本更新为 `0.5.2` 后：

```sh
git tag v0.5.2
git push origin refs/tags/v0.5.2
```

云端会运行 Swift 测试、Python 离线测试和传输边界检查，再分别编译 arm64 与 x86_64 App/驱动，检查实际 pkg 的版本、架构、签名、系统依赖、设备图片、驱动对应源码及 SHA-256。发布任务只在构建成功后获得 Release 写入权限。

## 本地调试构建

仅用于开发验证，正式对外分发仍由版本标签触发云端流程。从仓库根目录运行：

```sh
bash scripts/build-micbridge-release.sh
```

输出为 `dist/releases/<版本号>/`，包含 Apple Silicon 与 Intel 安装包、GPL 驱动对应源码、许可证、安装说明及 `SHA256SUMS.txt`。脚本只构建和校验，不安装、不上传。不要混入其他版本的旧产物。

## 签名与验证范围

App 和驱动固定使用 **ad-hoc 签名**，pkg 安装器未签名且未经公证。无需个人 Apple 证书；ad-hoc 签名用于完整性校验，不提供 Apple 认可的开发者身份。仅当 macOS 拦截打开时，需要在“隐私与安全性”中确认。需要公证的正式发行版应另行配置 Developer ID 签名及 Apple 公证。

云端不能验证 Mic 2 / Mini 2 的真实蓝牙连接、按键、驱动音频或音质。发布说明应保留已知 MTU 666 问题和开发测试范围，不能把构建成功表述为实机验收。

分发时保留 MIT、Apache-2.0、GPL-3.0 相关文件及驱动对应修改源码。设备图片和商标的权利归属见 `THIRD_PARTY_NOTICES.md`，不适用原创代码的 MIT 授权。不要将录音、固件、配对信息、本机日志、签名材料或内部交接记录提交到仓库。
