#!/bin/bash
set -euo pipefail
umask 077
reset_project="$(cd "$(dirname "$0")/.." && pwd)"
reset_helper="$reset_project/work/diagnostics/BluetoothResetHelper"
mkdir -p "$reset_project/work/diagnostics"
printf '%s\n' '将清除这台 Mac 的所有本地蓝牙配对、缓存及对应的音频控制记录。' '请保持 DJI Mic 2、Pocket 3 关闭，并退出录音软件。' '蓝牙键盘/鼠标会断开；请使用有线输入或当前远程连接。' '不备份蓝牙记录；不删除其他钥匙串密码、不改 Wi-Fi、不打开 SPP。'
/usr/bin/xcrun clang -fobjc-arc -fblocks -Wall -Wextra -Wno-deprecated-declarations \
  "$reset_project/scripts/diagnostics/BluetoothResetHelper.m" \
  -framework Foundation -framework IOBluetooth -framework Security -o "$reset_helper"
if /usr/bin/sudo /usr/bin/python3 -I "$reset_project/scripts/diagnostics/reset-bluetooth-all.py" --apply --all-pairings --helper "$reset_helper"; then
  reset_status=0
  printf '\n%s\n' '本地清理验证通过。请保存其他工作并重启 Mac，保持 Mic 2 关闭。' '重启后先运行同目录的 Verify Bluetooth Reset.command；通过后再重新配对、验收录音。'
else
  reset_status=$?
  printf '\n%s\n' '清理未全部通过，可能已部分生效。不要立即配对；请保留上方错误和结果文件。'
fi
printf '\n%s' '按回车关闭窗口…'
read -r reset_reply
exit "$reset_status"
