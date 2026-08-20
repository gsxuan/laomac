#!/usr/bin/env bash
# 开发运行: 编译并启动 Laomac
set -e
cd "$(dirname "$0")"
# 优化脚本路径: 优先仓库内副本, 兼容旧的上级目录布局
if [ -f macos-optimize.sh ]; then
    export MAC_OPT_SCRIPT="$(pwd)/macos-optimize.sh"
else
    export MAC_OPT_SCRIPT="$(cd .. && pwd)/macos-optimize.sh"
fi

# 开发模式下同步编译 smctool (充电限制等功能需要)
if [ ! -x smctool ] || [ smctool.c -nt smctool ]; then
    cc -O2 -o smctool smctool.c -framework IOKit -framework CoreFoundation
fi

swift run -c release Laomac
