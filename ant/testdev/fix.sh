#!/bin/bash

# 脚本功能：替换 /data/antnode-docker1/ 到 /data/antnode-docker4/ 目录下 .env 文件中的 NODE_COUNT 值
# 用法：./fix.sh [新值]
# 例如：./fix.sh 700  (自动检测当前值并替换为700)

# 设置目标目录数组
TARGET_DIRS=("/data/antnode-docker1" "/data/antnode-docker2" "/data/antnode-docker3" "/data/antnode-docker4")

# 检查参数
if [ $# -eq 0 ]; then
    # 如果有新数值在这里修改700
    # 如果有新数值在这里修改700
    # 如果有新数值在这里修改700
    NEW_VALUE="700"
    # 如果有新数值在这里修改700
    # 如果有新数值在这里修改700
    # 如果有新数值在这里修改700
    echo "使用默认新值：将自动检测当前 NODE_COUNT 值并改为 $NEW_VALUE"
elif [ $# -eq 1 ]; then
    # 如果有一个参数，使用用户指定的新值
    NEW_VALUE="$1"
    echo "使用指定新值：将自动检测当前 NODE_COUNT 值并改为 $NEW_VALUE"
else
    echo "用法：$0 [新值]"
    echo "例如：$0 700  (自动检测当前值并替换为700)"
    echo "或者直接运行 $0 使用默认新值 (700)"
    exit 1
fi

# 验证新值是否为数字
if ! [[ "$NEW_VALUE" =~ ^[0-9]+$ ]]; then
    echo "错误：新值必须是数字！"
    echo "新值：$NEW_VALUE"
    exit 1
fi

echo "开始执行 NODE_COUNT 值替换脚本..."
echo "将处理以下目录："
for dir in "${TARGET_DIRS[@]}"; do
    echo "  - $dir"
done
echo ""

# 统计变量
TOTAL_DIRS=${#TARGET_DIRS[@]}
SUCCESS_COUNT=0
FAILED_COUNT=0

# 遍历所有目标目录
for TARGET_DIR in "${TARGET_DIRS[@]}"; do
    ENV_FILE="$TARGET_DIR/.env"
    echo "=========================================="
    echo "正在处理目录：$TARGET_DIR"
    
    # 检查目标目录是否存在
    if [ ! -d "$TARGET_DIR" ]; then
        echo "❌ 错误：目录 $TARGET_DIR 不存在！"
        ((FAILED_COUNT++))
        continue
    fi
    
    # 检查 .env 文件是否存在
    if [ ! -f "$ENV_FILE" ]; then
        echo "❌ 错误：文件 $ENV_FILE 不存在！"
        ((FAILED_COUNT++))
        continue
    fi
    
    # 备份原文件
    BACKUP_FILE="$ENV_FILE.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$ENV_FILE" "$BACKUP_FILE"
    echo "已创建备份文件：$BACKUP_FILE"
    
    # 检查文件中是否存在 NODE_COUNT 配置
    if ! grep -q "NODE_COUNT=" "$ENV_FILE"; then
        echo "⚠️  警告：在 $ENV_FILE 中未找到 NODE_COUNT 配置"
        ((FAILED_COUNT++))
        continue
    fi
    
    # 获取当前的 NODE_COUNT 值
    CURRENT_VALUE=$(grep "NODE_COUNT=" "$ENV_FILE" | cut -d'=' -f2 | tr -d ' ')
    
    if [ -z "$CURRENT_VALUE" ]; then
        echo "❌ 错误：无法读取当前 NODE_COUNT 值"
        ((FAILED_COUNT++))
        continue
    fi
    
    echo "检测到当前 NODE_COUNT=$CURRENT_VALUE"
    
    # 检查当前值是否已经是目标值
    if [ "$CURRENT_VALUE" = "$NEW_VALUE" ]; then
        echo "ℹ️  当前值已经是 $NEW_VALUE，无需修改"
        ((SUCCESS_COUNT++))
        continue
    fi
    
    # 执行替换
    sed -i "s/NODE_COUNT=$CURRENT_VALUE/NODE_COUNT=$NEW_VALUE/g" "$ENV_FILE"
    
    # 验证替换结果
    if grep -q "NODE_COUNT=$NEW_VALUE" "$ENV_FILE"; then
        echo "✅ 替换成功！NODE_COUNT 已从 $CURRENT_VALUE 更改为 $NEW_VALUE"
        echo "当前 NODE_COUNT 设置："
        grep "NODE_COUNT" "$ENV_FILE"
        ((SUCCESS_COUNT++))
    else
        echo "❌ 替换失败！正在恢复备份文件..."
        cp "$BACKUP_FILE" "$ENV_FILE"
        echo "已恢复原文件"
        ((FAILED_COUNT++))
    fi
    echo ""
done

echo "=========================================="
echo "脚本执行完成！"
echo "总计处理目录：$TOTAL_DIRS"
echo "成功处理：$SUCCESS_COUNT"
echo "失败处理：$FAILED_COUNT"

if [ $FAILED_COUNT -gt 0 ]; then
    echo "⚠️  有 $FAILED_COUNT 个目录处理失败，请检查上述错误信息"
    exit 1
else
    echo "🎉 所有目录都处理成功！"
fi