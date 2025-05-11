#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# One click Install Shadowsocks-Python server (for Debian 12)
clear
echo
echo "#############################################################"
echo "# One click Install Shadowsocks-Python server               #"
echo "# Modified for Debian 12 (Python3 compatibility)           #"
echo "# Original: https://teddysun.com/342.html                   #"
echo "#############################################################"
echo

# 检查 python3 是否存在
if ! command -v python3 &> /dev/null; then
    echo -e "[\033[0;31mError\033[0m] python3 未安装，请先安装 python3。"
    exit 1
fi

libsodium_file="libsodium-1.0.18"
libsodium_url="https://github.com/jedisct1/libsodium/releases/download/1.0.18-RELEASE/libsodium-1.0.18.tar.gz"

cur_dir=$(pwd)

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

ciphers=(
aes-256-gcm
aes-192-gcm
aes-128-gcm
aes-256-ctr
aes-192-ctr
aes-128-ctr
aes-256-cfb
aes-192-cfb
aes-128-cfb
camellia-128-cfb
camellia-192-cfb
camellia-256-cfb
chacha20-ietf-poly1305
chacha20-ietf
chacha20
rc4-md5
)

[[ $EUID -ne 0 ]] && echo -e "[${red}Error${plain}] This script must be run as root!" && exit 1

get_char(){
    SAVEDSTTY=$(stty -g)
    stty -echo
    stty cbreak
    dd if=/dev/tty bs=1 count=1 2>/dev/null
    stty -raw
    stty echo
    stty $SAVEDSTTY
}

check_sys(){
    if grep -Eqi "debian|ubuntu" /etc/os-release; then
        return 0
    else
        return 1
    fi
}

pre_install(){
    echo "Please enter password for shadowsocks-python"
    read -p "(Default password: teddysun.com):" shadowsockspwd
    [ -z "${shadowsockspwd}" ] && shadowsockspwd="teddysun.com"
    echo
    echo "---------------------------"
    echo "password = ${shadowsockspwd}"
    echo "---------------------------"
    echo

    while true; do
        dport=$(shuf -i 9000-19999 -n 1)
        echo "Please enter a port for shadowsocks-python [1-65535]"
        read -p "(Default port: ${dport}):" shadowsocksport
        [ -z "$shadowsocksport" ] && shadowsocksport=${dport}
        if [[ "$shadowsocksport" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$shadowsocksport" -le 65535 ]; then
            echo
            echo "---------------------------"
            echo "port = ${shadowsocksport}"
            echo "---------------------------"
            echo
            break
        else
            echo -e "[${red}Error${plain}] Invalid port number."
        fi
    done

    while true; do
        echo -e "Please select stream cipher for shadowsocks-python:"
        for ((i=1;i<=${#ciphers[@]};i++)); do
            echo -e "${green}${i}${plain}) ${ciphers[$i-1]}"
        done
        read -p "Which cipher you'd select(Default: ${ciphers[0]}):" pick
        [ -z "$pick" ] && pick=1
        if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le ${#ciphers[@]} ]; then
            shadowsockscipher=${ciphers[$pick-1]}
            echo
            echo "---------------------------"
            echo "cipher = ${shadowsockscipher}"
            echo "---------------------------"
            echo
            break
        else
            echo -e "[${red}Error${plain}] Invalid selection."
        fi
    done

    echo
    echo "Press any key to start...or Press Ctrl+C to cancel"
    char=$(get_char)

    apt-get update
    apt-get install -y python3 python3-dev python3-setuptools curl wget unzip gcc automake autoconf make libtool libssl-dev
}

download_files(){
    cd ${cur_dir}
    wget --no-check-certificate -O ${libsodium_file}.tar.gz ${libsodium_url}
    wget --no-check-certificate -O shadowsocks-master.zip https://github.com/shadowsocks/shadowsocks/archive/master.zip
    wget --no-check-certificate https://raw.githubusercontent.com/teddysun/shadowsocks_install/master/shadowsocks-debian -O /etc/init.d/shadowsocks
    chmod +x /etc/init.d/shadowsocks
}

config_shadowsocks(){
    cat > /etc/shadowsocks.json<<-EOF
{
    "server":"0.0.0.0",
    "server_port":${shadowsocksport},
    "local_address":"127.0.0.1",
    "local_port":1080,
    "password":"${shadowsockspwd}",
    "timeout":300,
    "method":"${shadowsockscipher}",
    "fast_open":false
}
EOF
}

install(){
    cd ${cur_dir}
    tar zxf ${libsodium_file}.tar.gz
    cd ${libsodium_file}
    ./configure --prefix=/usr && make && make install
    ldconfig

    cd ${cur_dir}
    unzip -q shadowsocks-master.zip
    cd shadowsocks-master
    python3 setup.py install --record /usr/local/shadowsocks_install.log

    update-rc.d -f shadowsocks defaults
    /etc/init.d/shadowsocks start
}

install_cleanup(){
    cd ${cur_dir}
    rm -rf shadowsocks-master.zip shadowsocks-master ${libsodium_file}.tar.gz ${libsodium_file}
}

install_shadowsocks(){
    pre_install
    download_files
    config_shadowsocks
    install
    install_cleanup
    echo
    echo -e "Congratulations, Shadowsocks-python server installed!"
    echo -e "Server Port : ${shadowsocksport}"
    echo -e "Password    : ${shadowsockspwd}"
    echo -e "Cipher      : ${shadowsockscipher}"
    echo
}

action=$1
[ -z $1 ] && action=install
case "$action" in
    install)
        install_shadowsocks
        ;;
    *)
        echo "Usage: bash $0 install"
        ;;
esac
