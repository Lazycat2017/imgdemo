#!/bin/bash

# 进入/data目录
cd /data || { echo "无法进入/data目录"; exit 1; }

# 拉取nockchain仓库
git clone https://git.max.xch.im/maxmind/nockchain || { echo "仓库克隆失败"; exit 1; }

# 进入nockchain目录
cd nockchain || { echo "无法进入nockchain目录"; exit 1; }

# 复制.env.sample为.env
cp .env.sample .env || { echo "复制.env.sample失败"; exit 1; }

# 替换MINING_PUBKEY的值
sed -i 's/^MINING_PUBKEY=.*/MINING_PUBKEY=39GUmwZeKy3GRGJ9qmdigyBuEfyHroXFgCoTRSwUbJvqX7u9n3A42nK864VNhmcXaUaGfYCwKxLsRW1V1qEHPeCcFoWLPEMYdxiBUQVgZGyXRSmTcwuW1tB7qauVrmftRRdL/' .env || { echo "替换MINING_PUBKEY失败"; exit 1; }

# 执行docker-compose up -d
#docker-compose up -d || { echo "启动docker-compose失败"; exit 1; }

echo "nockchain已成功部署"