#!/bin/bash

# 下载并覆盖文件
wget https://dl.zao.re/nock/h9-miner-nock-linux-amd64 -O /data/nock/h9-miner-nock-linux-amd64

# 添加执行权限
chmod +x /data/nock/h9-miner-nock-linux-amd64

# 杀掉现有进程 (使用更强制的方法)
pkill -9 -f h9-miner-nock-linux-amd64
# 等待进程完全退出
sleep 2
