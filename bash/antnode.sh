#!/bin/bash

set -e  # 如果发生错误，脚本将立即退出

# 更新系统
apt update -y

# 配置 BBR
cat <<EOF | tee /etc/sysctl.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
sysctl -p

# 安装必要的软件包
apt install -y btop vnstat duf vim screen build-essential jq git libssl-dev unzip curl sudo wget ca-certificates

# 安装 Docker
curl -fsSL https://get.docker.com | sh
systemctl start docker
systemctl enable docker

# 安装 Docker Compose
LATEST_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
curl -L "https://github.com/docker/compose/releases/download/${LATEST_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# 创建 /data 目录
mkdir -p /data
cd /data

# 克隆仓库
git clone https://github.com/lushdog/antnode-docker.git
cd antnode-docker

# 修改 .env 文件
sed -i 's/REWARD_ADDRESS=0x8a7cC0B9A7d17546073b6Dba0e3BFA49b5b0F84E/REWARD_ADDRESS=0x73b548474b878d8451dbb4d0fe7b4f2c3b890bdc/g' .env
sed -i 's/NODE_COUNT=50/NODE_COUNT=1000/g' .env

# 复制 5 份目录
for i in {1..5}; do
  cp -r /data/antnode-docker /data/antnode-docker$i
done

# 删除原始目录
rm -rf /data/antnode-docker

# 修改 docker-compose.yml 里的 name
for i in {1..5}; do
  sed -i "s/name: antnode/name: antnode$i/g" /data/antnode-docker$i/docker-compose.yml
done

# 安装 nezha agent（在 /tmp 下执行）
cd /tmp
curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh -o agent.sh
chmod +x agent.sh
env NZ_SERVER=tz.ka.dog:8008 NZ_TLS=false NZ_CLIENT_SECRET=2rmHr9RMlXNQEVvXgT9axnDihvdZMlBe ./agent.sh

# 进入 /data/antnode-docker1 目录并执行 docker-compose pull
cd /data/antnode-docker1
docker-compose pull

echo "所有操作完成！"
