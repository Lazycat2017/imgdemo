cd /data

# 克隆仓库
git clone https://github.com/lushdog/antnode-docker.git
mv antnode-docker antnode-docker6
cd antnode-docker6

sed -i 's/REWARD_ADDRESS=0x8a7cC0B9A7d17546073b6Dba0e3BFA49b5b0F84E/REWARD_ADDRESS=0x73b548474b878d8451dbb4d0fe7b4f2c3b890bdc/g' .env
sed -i 's/NODE_COUNT=50/NODE_COUNT=1000/g' .env
sed -i "s/name: antnode/name: antnode6/g" /data/antnode-docker6/docker-compose.yml

screen -dmS run bash -c '
    # 进入 antnode-docker6 目录
    cd /data/antnode-docker6 || { echo "目录 /data/antnode-docker6 不存在，退出"; exit 1; }
    
    # 启动 docker-compose
    docker-compose up -d
'