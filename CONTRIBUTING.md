# 贡献指南

欢迎提交复现报告、文档修正和范围明确的代码改动。先阅读 [构建](docs/BUILDING.md)、[协议](docs/PROTOCOL.md) 与 [验证范围](docs/VALIDATION.md)。

## 开发

- 每个改动说明问题、行为变化和验证结果；界面改动附截图，避免包含真实设备地址。
- 保持原 RXlessDemo 的行为边界。MicBridge 会话/路由差异由 `scripts/micbridge-session.patch` 和 `scripts/micbridge-routes.patch` 明确记录；修改后审查差异并更新补丁，不能为通过校验而忽略传输变化。
- 不在构建、CI 或普通单元测试中连接硬件、请求权限、修改音频路由或执行蓝牙重置。
- 实机测试前说明设备、固件、操作顺序。退出前遵循 `12/65 → ACK 00 → close`，不要把只看到音频等同于所有控制能力正常。
- 新命令需有协议/固件依据；为长度、CRC、地址、序号和无效回复增加测试。

```sh
swift test
python3 -m unittest discover -s scripts/diagnostics/tests -v
python3 -m unittest discover -s scripts/tests -p test_public_privacy.py -v
python3 scripts/check-micbridge-transport.py
swift build -c release --product MicBridge
```

## 提交内容

只提交源码、合成测试数据、公开文档和有明确许可的资源。不要提交 `work/`、`dist/`、`.build/`、`.local/`、固件镜像、语音、配对数据、个人证书或原始系统日志。产品图不自动获得源码许可证授权。

提交前将需要公开的文件加入暂存区，再运行 `python3 scripts/check-public-privacy.py`。该检查读取实际暂存的内容，不会输出命中的敏感值；CI 也运行此检查。它不能识别图片内的文字或判断任意测试数据是否来自真实设备，截图仍需人工检查。使用明确的合成设备地址和 GitHub noreply 提交邮箱，保留第三方作者的原始许可与署名。

Bug报告应包含App版本、macOS/芯片、发射器型号及固件、复现步骤、预期和实际结果，以及脱敏后的控制/状态计数。区分“观察到的事实”和“对原因的猜测”。

贡献原创代码时沿用本项目MIT许可；修改Vendor文件时保留对应上游许可证和修改记录。提交PR不意味着替换第三方许可。
