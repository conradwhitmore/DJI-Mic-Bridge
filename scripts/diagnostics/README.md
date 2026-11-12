# 独立诊断工具

本目录为协议研究和离线分析保留，不属于日常App运行路径。Python工具使用标准库（3.9+），部分采集/播放工具依赖macOS原生helper；先查看各工具的`--help`。

- `analyze_mic2_spp.py`、`inspect_mic2_stream_rate.py`：本地抓包封装、CRC及序号分析。
- `probe_mic2_lc3_offline.py`、`decode_mic2_lc3_candidate.py`：已有采集的离线解码，需显式提供本地liblc3动态库。
- `make_mic2_bandwidth_stimulus.py`、`inspect_pcm_bandwidth.py`：生成或分析音频测试材料。
- `capture_mic2_spp.py`、`watch_mic2_buttons.py`：独立硬件实验，不能与MicBridge同时占用同一通道。
- `reset-*`、`BluetoothResetHelper.m`及上级Reset命令：历史系统重置工具，可能影响蓝牙配对/缓存，不是App安装、启动或故障恢复的默认步骤。

离线测试会模拟系统命令及变更，不启动实际设备操作：

```sh
python3 -m unittest discover -s scripts/diagnostics/tests -v
bash scripts/diagnostics/test-recording-segments.sh
```

协议以[当前协议记录](../../docs/PROTOCOL.md)为准，恢复以[恢复说明](../../docs/RECOVERY.md)为准。原始语音、固件、设备地址及现场日志留在本机忽略目录，不随公开源码提供。使用示例中的合成地址不能替代自己设备的实际参数。
