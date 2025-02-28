#!/bin/bash

# 启用错误检查并打印执行步骤
set -e
echo -e "\033[32m正在更新系统包列表...\033[0m"
sudo apt update -qq

echo -e "\n\033[32m正在配置BBR加速...\033[0m"
sudo tee -a /etc/sysctl.conf << EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sudo sysctl -p

echo -e "\n\033[32m正在安装基础软件包...\033[0m"
sudo DEBIAN_FRONTEND=noninteractive apt install -qq -y \
btop vnstat duf vim screen build-essential \
jq git libssl-dev unzip curl sudo wget ca-certificates

echo -e "\n\033[32m正在安装Docker环境...\033[0m"
curl -fsSL https://get.docker.com | sudo sh
sudo mkdir -p /usr/local/libexec/docker-cli-plugins
sudo curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" \
-o /usr/local/libexec/docker-cli-plugins/docker-compose
sudo chmod +x /usr/local/libexec/docker-cli-plugins/docker-compose

echo -e "\n\033[32m正在准备项目目录...\033[0m"
sudo mkdir -p /data
cd /data

echo -e "\n\033[32m正在克隆项目仓库...\033[0m"
sudo git clone --quiet https://github.com/lushdog/antnode-docker.git

echo -e "\n\033[32m正在修改配置文件...\033[0m"
cd antnode-docker
sudo sed -i 's/REWARD_ADDRESS=0x8a7cC0B9A7d17546073b6Dba0e3BFA49b5b0F84E/REWARD_ADDRESS=0x73b548474b878d8451dbb4d0fe7b4f2c3b890bdc/g' .env
sudo sed -i 's/NODE_COUNT=50/NODE_COUNT=1000/g' .env

echo -e "\n\033[32m正在创建节点副本...\033[0m"
for i in {1..5}; do
    sudo cp -a /data/antnode-docker "/data/antnode-docker${i}" && rm -rf /data/antnode-docker
done

echo -e "\n\033[32m正在修改容器名称...\033[0m"
for i in {1..5}; do
    sudo sed -i "s/name: antnode/name: antnode${i}/g" "/data/antnode-docker${i}/docker-compose.yml"
done

echo -e "\n\033[32m所有操作已完成！\033[0m"
echo "已创建以下节点目录："
sudo duf -a /data/antnode-docker* | grep antnode