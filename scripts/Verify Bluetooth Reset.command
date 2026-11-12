#!/bin/bash
set -euo pipefail
umask 077
verify_project="$(cd "$(dirname "$0")/.." && pwd)"
verify_helper="$verify_project/work/diagnostics/BluetoothResetHelper"
mkdir -p "$verify_project/work/diagnostics"
printf '%s\n' '这是重启后的只读验证，不会再次清理或连接设备。' '请先保持 Mic 2 关闭、Mac 蓝牙关闭，暂不配对。'
/usr/bin/xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Wno-deprecated-declarations \
  "$verify_project/scripts/diagnostics/BluetoothResetHelper.m" \
  -framework Foundation -framework IOBluetooth -framework Security -o "$verify_helper"
if /usr/bin/sudo /usr/bin/python3 -I "$verify_project/scripts/diagnostics/reset-bluetooth-all.py" --verify --helper "$verify_helper"; then
  verify_status=0
  printf '\n%s\n' '重启后本地清理状态验证通过。现在可开启蓝牙，让 Mic 2 进入蓝灯快闪配对模式，再从附近设备手动连接。' '输出保持 Mac mini 扬声器，只选择 DJI 输入进行普通收音测试；不要运行 SPP Demo。'
else
  verify_status=$?
  printf '\n%s\n' '验证未通过。请保留错误，先不要配对或运行 SPP 实验。'
fi
printf '\n%s' '按回车关闭窗口…'
read -r verify_reply
exit "$verify_status"
