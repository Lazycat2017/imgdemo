#!/bin/bash
# 设置Debian/Ubuntu系统为东八区上海时间，保持英文语言，时间格式24小时制

# 设置时区为Asia/Shanghai
sudo timedatectl set-timezone Asia/Shanghai

# 确保使用英文语言环境
sudo update-locale LANG=en_US.UTF-8 LC_TIME=en_US.UTF-8

# 设置24小时制时间格式（通过LC_TIME）
# 编辑/etc/default/locale，确保LC_TIME使用en_DK.UTF-8（提供24小时制）
grep -q '^LC_TIME=' /etc/default/locale && \
  sudo sed -i 's/^LC_TIME=.*/LC_TIME=en_DK.UTF-8/' /etc/default/locale || \
  echo 'LC_TIME=en_DK.UTF-8' | sudo tee -a /etc/default/locale

# 立即生效
source /etc/default/locale
export LC_TIME=en_DK.UTF-8

# 提示用户重新登录或重启系统以使所有更改生效
echo "时区已设置为Asia/Shanghai，语言保持英文，时间格式已设为24小时制。"
echo "请重新登录或重启系统以使更改完全生效。"
