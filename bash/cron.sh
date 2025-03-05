#!/bin/bash

# 定义定时任务内容
CRON_JOB="0 3 * * * find /data/antnode-docker*/autonom_data/ -type f -name "antnode.log.*T*" -delete"

# 备份现有 crontab（以防修改出错）
crontab -l > /tmp/current_cron.bak 2>/dev/null

# 检查是否已存在该任务，避免重复添加
if crontab -l 2>/dev/null | grep -Fq "$CRON_JOB"; then
    echo "Crontab 任务已存在，无需重复添加。"
else
    # 将新任务追加到当前的 crontab 任务列表
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    echo "Crontab 任务已成功添加！"
fi

# 显示当前 crontab 任务列表
echo "当前 crontab 任务如下："
crontab -l


