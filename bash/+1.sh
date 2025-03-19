#!/bin/bash
cd /data

# 查找当前最大的目录编号
max_num=0
for dir in /data/antnode-docker*; do
  if [ -d "$dir" ]; then
    num=$(echo "$dir" | grep -o '[0-9]*$')
    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -gt "$max_num" ]; then
      max_num=$num
    fi
  fi
done

# 计算新的目录编号
new_num=$((max_num + 1))
echo "当前最大目录编号为 $max_num，将创建 antnode-docker$new_num"

# 克隆仓库
git clone https://github.com/lushdog/antnode-docker.git
mv antnode-docker antnode-docker$new_num
cd antnode-docker$new_num

sed -i 's/REWARD_ADDRESS=0x8a7cC0B9A7d17546073b6Dba0e3BFA49b5b0F84E/REWARD_ADDRESS=0x73b548474b878d8451dbb4d0fe7b4f2c3b890bdc/g' .env
sed -i 's/NODE_COUNT=50/NODE_COUNT=1000/g' .env
sed -i "s/name: antnode/name: antnode$new_num/g" /data/antnode-docker$new_num/docker-compose.yml

screen -dmS run bash -c '
    # 进入新创建的目录
    cd /data/antnode-docker'"$new_num"' || { echo "目录 /data/antnode-docker'"$new_num"' 不存在，退出"; exit 1; }
    
    # 启动 docker-compose
    docker-compose up -d
'