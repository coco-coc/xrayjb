#!/bin/bash

# 全局颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
CYAN="\033[36m"
NC="\033[0m"

# 信息前缀
INFO="${GREEN}[信息]${NC}"
ERROR="${RED}[错误]${NC}"
WARNING="${YELLOW}[警告]${NC}"

# 检测系统类型
detect_os() {
    if [ -f /etc/alpine-release ]; then
        echo "alpine"
    elif grep -q "Ubuntu" /etc/os-release; then
        echo "ubuntu"
    elif grep -q "Debian" /etc/os-release; then
        echo "debian"
    elif grep -q "CentOS" /etc/os-release || grep -q "Red Hat" /etc/os-release || grep -q "AlmaLinux" /etc/os-release; then
        echo "centos"
    else
        echo "unknown"
    fi
}

OS_TYPE=$(detect_os)

# ------------------- Xray 路径定义 -------------------
XRAY_DIR="/root/Xray"
XRAY_BIN="${XRAY_DIR}/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
XRAY_CERT="${XRAY_DIR}/domain.crt"
XRAY_KEY="${XRAY_DIR}/domain.key"
XRAY_PRIV_KEY_FILE="${XRAY_DIR}/private.key"
XRAY_PUB_KEY_FILE="${XRAY_DIR}/public.key"
XRAY_SERVICE_SYSTEMD="/etc/systemd/system/xray.service"
XRAY_SERVICE_OPENRC="/etc/init.d/xray"
XRAY_LOG_DIR="/var/log"
# -----------------------------------------------------

# 颜色输出函数
red() { echo -e "${RED}$1${NC}"; }
green() { echo -e "${GREEN}$1${NC}"; }
yellow() { echo -e "${YELLOW}$1${NC}"; }
blue() { echo -e "${BLUE}$1${NC}"; }
cyan() { echo -e "${CYAN}$1${NC}"; }

# ============================== 按需安装 jq 的函数 ==============================
# 确保 jq 已安装，仅在需要时调用
ensure_jq() {
    if ! command -v jq &> /dev/null; then
        yellow "此功能需要 jq，正在为您安装..."
        case "$OS_TYPE" in
            "alpine")
                apk add --no-cache jq
                ;;
            "ubuntu"|"debian")
                apt update
                apt install -y jq
                ;;
            "centos")
                # 修复CentOS 7源
                if grep -q "CentOS Linux 7" /etc/os-release; then
                    sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
                    sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
                    yum clean all
                fi
                if ! rpm -q epel-release >/dev/null; then
                    yum install -y epel-release
                fi
                yum install -y jq
                ;;
            *)
                red "不支持的系统类型，无法自动安装 jq！"
                exit 1
                ;;
        esac
    fi
    
    if ! command -v jq &> /dev/null; then
        red "jq 安装失败，请手动安装后重试！"
        exit 1
    fi
}

# ============================== Xray 安装部分 ==============================
install_xray() {
    # 清理旧日志
    rm -f ${XRAY_LOG_DIR}/xray*.log

    yellow "检测系统类型：$OS_TYPE"
    yellow "开始安装依赖 (包含 jq)..."
    install_deps
    
    # 选择协议
    yellow "请选择协议："
    select protocol in "vmess" "trojan" "vless" "shadowsocks"; do
        PROTOCOL=$protocol
        break
    done
    
    # 如果是VLESS协议，选择传输类型
    VLESS_TYPE=""
    if [[ "$PROTOCOL" == "vless" ]]; then
        yellow "请选择VLESS传输类型："
        select vless_type in "WebSocket+TLS" "Reality"; do
            VLESS_TYPE=$vless_type
            break
        done
    fi
    
    # Reality模式输入伪装域名
    if [[ "$PROTOCOL" == "vless" && "$VLESS_TYPE" == "Reality" ]]; then
        read -p "请输入伪装域名[默认: www.microsoft.com]: " dest_server
        [[ -z $dest_server ]] && dest_server="www.microsoft.com"
    fi
    
    # 输入域名和路径（Shadowsocks和Reality不需要）
    if [[ "$PROTOCOL" != "shadowsocks" && ! ( "$PROTOCOL" == "vless" && "$VLESS_TYPE" == "Reality" ) ]]; then
        read -p "请输入域名（已解析到本机IP）：" DOMAIN
        read -p "请输入WebSocket路径（默认/）：" WS_PATH
        [[ -z "$WS_PATH" ]] && WS_PATH="/"
    else
        # Shadowsocks和Reality不需要域名和路径
        DOMAIN=""
        WS_PATH=""
    fi
    
    # 配置证书（Shadowsocks和Reality不需要证书）
    if [[ "$PROTOCOL" != "shadowsocks" && ! ( "$PROTOCOL" == "vless" && "$VLESS_TYPE" == "Reality" ) ]]; then
        setup_certificates
    fi
    
    # 生成认证信息
    if [[ "$PROTOCOL" == "trojan" ]]; then
        read -p "请输入Trojan密码（默认随机生成）：" PASSWORD
        [[ -z "$PASSWORD" ]] && PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
        green "Trojan 密码已生成：$PASSWORD"
        TROJAN_PASSWORD="$PASSWORD"  # 保存密码变量
    elif [[ "$PROTOCOL" == "shadowsocks" ]]; then
        read -p "请输入Shadowsocks密码（默认随机生成）：" PASSWORD
        [[ -z "$PASSWORD" ]] && PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
        green "Shadowsocks 密码已生成：$PASSWORD"
        
        yellow "请选择加密方式："
        select method in "aes-256-gcm" "chacha20-poly1305" "aes-128-gcm" "none"; do
            SS_METHOD=$method
            break
        done
        [[ "$SS_METHOD" == "none" ]] && SS_METHOD="plain"
    else
        UUID=$(cat /proc/sys/kernel/random/uuid)
        green "UUID 已生成：$UUID"
    fi
    
    # 生成Reality密钥对和短ID
    if [[ "$PROTOCOL" == "vless" && "$VLESS_TYPE" == "Reality" ]]; then
        # 检查是否安装了xray
        if [[ ! -f "${XRAY_BIN}" ]]; then
            # 使用 GitHub 官方源下载 Xray
            echo "正在从 GitHub 下载最新版 Xray..."
            ARCH=$(uname -m)
            case $ARCH in
                x86_64) ARCH="64" ;;
                aarch64) ARCH="arm64-v8a" ;;
                armv7l) ARCH="arm32-v7a" ;;
                *) red "不支持的系统架构: $ARCH"; exit 1 ;;
            esac
            
            # 直接下载最新版
            DOWNLOAD_URL="https://git.1314k.tk/https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
            LATEST_FILE="Xray-linux-${ARCH}.zip"
            
            echo "下载链接: $DOWNLOAD_URL"
            if ! wget -O "$LATEST_FILE" "$DOWNLOAD_URL"; then
                red "Xray 下载失败，请检查网络连接"
                exit 1
            fi
            
            # 解压到目标目录
            mkdir -p "${XRAY_DIR}"
            unzip -o -d "${XRAY_DIR}" "$LATEST_FILE"
            
            if [[ -f "${XRAY_BIN}" ]]; then
                chmod +x "${XRAY_BIN}"
                green "Xray 安装成功！"
                rm -f "$LATEST_FILE"
            else
                red "解压后未找到 xray 可执行文件"
                exit 1
            fi
        fi
        
        # 生成Reality密钥对
yellow "正在生成Reality密钥对..."
local key_pair=$(${XRAY_BIN} x25519 2>&1)
# 优先按 "Private key: xxx" 提取
private_key=$(echo "${key_pair}" | grep -i 'Private' | awk -F': ' '{print $2}' | tr -d '[:space:]')
public_key=$(echo "${key_pair}" | grep -i 'Public' | awk -F': ' '{print $2}' | tr -d '[:space:]')
# 若提取失败，备用格式 "Private xxx"
if [[ -z "$private_key" || -z "$public_key" ]]; then
    private_key=$(echo "${key_pair}" | awk '/Private/{print $2}' | tr -d '[:space:]')
    public_key=$(echo "${key_pair}" | awk '/Public/{print $2}' | tr -d '[:space:]')
fi
# 最终校验
if [[ -z "$private_key" || -z "$public_key" ]]; then
    red "Reality 密钥生成失败，请检查 xray 版本是否支持 x25519 命令"
    exit 1
fi
green "private_key: $private_key"
green "public_key: $public_key"

# 生成短ID（统一用 openssl，不依赖 xxd）
short_id=$(openssl rand -hex 4)
green "short_id: $short_id"
    fi
    
    # 端口配置
    read -p "请输入监听端口（默认443）：" IN_PORT
    [[ -z "$IN_PORT" ]] && IN_PORT=443
    if [[ "$IN_PORT" != "443" ]] && [[ "$PROTOCOL" != "shadowsocks" ]]; then
        yellow "建议使用443端口以提高兼容性"
    fi
    
    # 检查是否已安装 Xray
    if [[ ! -f "${XRAY_BIN}" ]]; then
        # 使用 GitHub 官方源下载 Xray
        echo "正在从 GitHub 下载最新版 Xray..."
        ARCH=$(uname -m)
        case $ARCH in
            x86_64) ARCH="64" ;;
            aarch64) ARCH="arm64-v8a" ;;
            armv7l) ARCH="arm32-v7a" ;;
            *) red "不支持的系统架构: $ARCH"; exit 1 ;;
        esac
        
        # 直接下载最新版
        DOWNLOAD_URL="https://git.1314k.tk/https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH}.zip"
        LATEST_FILE="Xray-linux-${ARCH}.zip"
        
        echo "下载链接: $DOWNLOAD_URL"
        if ! wget -O "$LATEST_FILE" "$DOWNLOAD_URL"; then
            red "Xray 下载失败，请检查网络连接"
            exit 1
        fi
        
        # 解压到目标目录
        mkdir -p "${XRAY_DIR}"
        unzip -o -d "${XRAY_DIR}" "$LATEST_FILE"
        
        if [[ -f "${XRAY_BIN}" ]]; then
            chmod +x ${XRAY_BIN}
            green "Xray 安装成功！"
            rm -f "$LATEST_FILE"
        else
            red "解压后未找到 xray 可执行文件"
            exit 1
        fi
    fi
    
    # 生成配置文件
    generate_config
    
    # 配置服务
    setup_service
    
    # 生成客户端链接
    generate_links
    
    # 显示日志路径
    yellow "访问日志：/var/log/xray-access.log"
    yellow "错误日志：/var/log/xray-error.log"
    green "Xray 服务配置完成！"
    
    # 添加暂停以便用户查看链接
    read -p "按回车键返回主菜单..."
}

# Xray依赖安装（带检测, 已包含 jq）
install_deps() {
    case "$OS_TYPE" in
        "alpine")
            apk update
            # 定义依赖列表
            DEPS="curl wget unzip nc-openbsd openrc openssl jq"
            for pkg in $DEPS; do
                if ! apk info -e $pkg &>/dev/null; then
                    yellow "安装 $pkg..."
                    apk add --no-cache $pkg
                else
                    green "$pkg 已安装"
                fi
            done
            ;;
        "debian"|"ubuntu")
            apt update
            # 定义依赖列表
            DEPS="curl wget unzip netcat-openbsd openssl jq"
            for pkg in $DEPS; do
                if ! dpkg -s $pkg &>/dev/null; then
                    yellow "安装 $pkg..."
                    apt install -y $pkg
                else
                    green "$pkg 已安装"
                fi
            done
            ;;
        "centos")
            # CentOS 7 镜像源修复
            if grep -q "CentOS Linux 7" /etc/os-release; then
                echo "修复 CentOS 7 镜像源..."
                sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
                sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
                yum clean all
            fi
            
            # 安装EPEL仓库
            if ! rpm -q epel-release >/dev/null; then
                yellow "安装EPEL仓库..."
                yum install -y epel-release
            fi
            
            # 定义依赖列表
            DEPS="curl wget unzip nc openssl jq"
            for pkg in $DEPS; do
                if ! rpm -q $pkg >/dev/null; then
                    yellow "安装 $pkg..."
                    yum install -y $pkg
                else
                    green "$pkg 已安装"
                fi
            done
            ;;
        *)
            red "不支持的系统类型！"
            exit 1
            ;;
    esac
}

# Xray服务管理配置
setup_service() {
    case "$OS_TYPE" in
        "alpine")
            cat << EOF > ${XRAY_SERVICE_OPENRC}
#!/sbin/openrc-run
name="xray"
description="Xray Service"
command="${XRAY_BIN}"
command_args="-config ${XRAY_CONFIG}"
pidfile="/run/xray.pid"
respawn_delay=5
rc_ulimit="-n 30000"
output_log="${XRAY_LOG_DIR}/xray.log"
error_log="${XRAY_LOG_DIR}/xray.error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -f \$output_log -m 0644
    checkpath -f \$error_log -m 0644
}

start() {
    ebegin "Starting xray service"
    # Alpine系统使用不同的start-stop-daemon语法
    start-stop-daemon --start \
        --exec \$command \
        --pidfile \$pidfile \
        --background \
        --make-pidfile \
        -- \\
        \$command_args
    eend \$?
}

stop() {
    ebegin "Stopping xray service"
    start-stop-daemon --stop \
        --exec \$command \
        --pidfile \$pidfile
    eend \$?
}
EOF
            chmod +x ${XRAY_SERVICE_OPENRC}
            mkdir -p /var/log
            touch ${XRAY_LOG_DIR}/xray.log
            rc-update add xray default
            service xray restart
            ;;
        "debian"|"ubuntu"|"centos")
            cat << EOF > "${XRAY_SERVICE_SYSTEMD}"
[Unit]
Description=Xray Service
After=network.target

[Service]
ExecStart=${XRAY_BIN} -config "${XRAY_CONFIG}"
Restart=always
User=root
LimitNOFILE=30000
StandardOutput=file:${XRAY_LOG_DIR}/xray.log
StandardError=file:${XRAY_LOG_DIR}/xray.error.log

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable xray
            systemctl restart xray
            ;;
    esac
}

# Xray证书配置 - 增强版（带循环验证）
setup_certificates() {
    while true; do
        read -p "请选择：1.已上传证书文件，输入证书路径；2.未上传证书，直接输入证书内容.(默认选择1)： " is_path
        [[ -z $is_path ]] && is_path=1
        
        if [[ $is_path == 1 ]]; then
            # 证书文件路径输入模式
            while true; do
                read -p "请输入.crt结尾的证书绝对路径：" cert
                until [[ -f "$cert" ]]; do
                    red "找不到文件！请检查输入路径！"
                    read -p "请输入.crt结尾的证书绝对路径：" cert
                done
                
                read -p "请输入.key结尾的证书绝对路径：" key
                until [[ -f "$key" ]]; do
                    red "找不到文件！请检查输入路径！"
                    read -p "请输入.key结尾的证书绝对路径：" key
                done
                
                # 验证证书和私钥是否匹配
                cert_md5=$(openssl x509 -noout -modulus -in "$cert" 2>/dev/null | openssl md5 | cut -d' ' -f2)
                key_md5=$(openssl rsa -noout -modulus -in "$key" 2>/dev/null | openssl md5 | cut -d' ' -f2)
                
                if [[ "$cert_md5" == "$key_md5" ]]; then
                    CERT_PATH="$cert"
                    KEY_PATH="$key"
                    green "√ 证书验证通过"
                    break 2
                else
                    red "证书与私钥不匹配！请重新输入"
                fi
            done
        else
            # 证书内容输入模式
            mkdir -p "${XRAY_DIR}"
            chmod 700 "${XRAY_DIR}"
            
            while true; do
                # 输入证书内容
                yellow "请输入证书内容（输入空行结束）："
                cert_txt=""
                while IFS= read -r line; do
                    if [[ -z "$line" ]]; then
                        break
                    fi
                    cert_txt+="$line\n"
                done
                echo -e "$cert_txt" | sed '/^$/d' > "${XRAY_CERT}"
                yellow "证书被保存在：${XRAY_CERT}"
                
                # 输入私钥内容
                yellow "请输入对应的key内容（输入空行结束）："
                key_txt=""
                while IFS= read -r line; do
                    if [[ -z "$line" ]]; then
                        break
                    fi
                    key_txt+="$line\n"
                done
                echo -e "$key_txt" | sed '/^$/d' > "${XRAY_KEY}"
                yellow "证书被保存在：${XRAY_KEY}"
                
                # 验证证书和私钥是否匹配
                cert_md5=$(openssl x509 -noout -modulus -in "${XRAY_CERT}" 2>/dev/null | openssl md5 | cut -d' ' -f2)
                key_md5=$(openssl rsa -noout -modulus -in "${XRAY_KEY}" 2>/dev/null | openssl md5 | cut -d' ' -f2)
                
                if [[ "$cert_md5" == "$key_md5" ]]; then
                    CERT_PATH="${XRAY_CERT}"
                    KEY_PATH="${XRAY_KEY}"
                    green "√ 证书验证通过"
                    break 2
                else
                    red "证书与私钥不匹配！请重新输入"
                    read -p "是否重新输入？(y/n, 默认y): " retry
                    [[ -z "$retry" ]] && retry="y"
                    if [[ "$retry" != "y" ]]; then
                        red "证书验证失败，安装中止！"
                        exit 1
                    fi
                fi
            done
        fi
    done
}

# Xray生成协议配置
generate_config() {
    # 添加IPv6监听支持
    LISTEN_IPV6="\"listen\": \"::\","
    
    # 添加IPv4/IPv6双栈支持
    DOMAIN_STRATEGY="\"domainStrategy\": \"UseIP\""

    case "$PROTOCOL" in
        "vmess")
            CLIENT_CONFIG="\"id\": \"$UUID\", \"alterId\": 0, \"security\": \"auto\""
            TLS_SETTINGS="\"tlsSettings\": {
                \"certificates\": [{
                    \"certificateFile\": \"$CERT_PATH\",
                    \"keyFile\": \"$KEY_PATH\"
                }],
                \"serverName\": \"$DOMAIN\"
            }"
            cat << EOF > "${XRAY_CONFIG}"
{
    "log": {
        "loglevel": "warning",
        "access": "/var/log/xray-access.log",
        "error": "/var/log/xray-error.log"
    },
    "inbounds": [{
        $LISTEN_IPV6
        "port": $IN_PORT,
        "protocol": "$PROTOCOL",
        "settings": {
            "clients": [{ $CLIENT_CONFIG }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "ws",
            "security": "tls",
            "wsSettings": {
                "path": "$WS_PATH",
                "headers": { "Host": "$DOMAIN" }
            },
            $TLS_SETTINGS
        }
    }],
    "outbounds": [{
        "protocol": "freedom",
        "settings": {
            $DOMAIN_STRATEGY
        }
    }]
}
EOF
            ;;
        "trojan")
            CLIENT_CONFIG="\"password\": \"$TROJAN_PASSWORD\""
            TLS_SETTINGS="\"tlsSettings\": {
                \"certificates\": [{
                    \"certificateFile\": \"$CERT_PATH\",
                    \"keyFile\": \"$KEY_PATH\"
                }],
                \"serverName\": \"$DOMAIN\"
            }"
            cat << EOF > "${XRAY_CONFIG}"
{
    "log": {
        "loglevel": "warning",
        "access": "/var/log/xray-access.log",
        "error": "/var/log/xray-error.log"
    },
    "inbounds": [{
        $LISTEN_IPV6
        "port": $IN_PORT,
        "protocol": "$PROTOCOL",
        "settings": {
            "clients": [{ $CLIENT_CONFIG }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "ws",
            "security": "tls",
            "wsSettings": {
                "path": "$WS_PATH",
                "headers": { "Host": "$DOMAIN" }
            },
            $TLS_SETTINGS
        }
    }],
    "outbounds": [{
        "protocol": "freedom",
        "settings": {
            $DOMAIN_STRATEGY
        }
    }]
}
EOF
            ;;
        "vless")
            if [[ "$VLESS_TYPE" == "Reality" ]]; then
                CLIENT_CONFIG="\"id\": \"$UUID\", \"flow\": \"xtls-rprx-vision\""
                TLS_SETTINGS="\"security\": \"reality\",
                \"realitySettings\": {
                    \"show\": true,
                    \"dest\": \"$dest_server:443\",
                    \"xver\": 0,
                    \"serverNames\": [
                        \"$dest_server\"
                    ],
                    \"privateKey\": \"$private_key\",
                    \"minClientVer\": \"\",
                    \"maxClientVer\": \"\",
                    \"maxTimeDiff\": 0,
                    \"shortIds\": [
                        \"$short_id\"
                    ]
                }"
                cat << EOF > "${XRAY_CONFIG}"
{
    "log": {
        "loglevel": "warning",
        "access": "/var/log/xray-access.log",
        "error": "/var/log/xray-error.log"
    },
    "inbounds": [{
        $LISTEN_IPV6
        "port": $IN_PORT,
        "protocol": "$PROTOCOL",
        "settings": {
            "clients": [{ $CLIENT_CONFIG }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            $TLS_SETTINGS,
            "packetEncoding": "xudp"
        }
    }],
    "outbounds": [
        {
            "protocol": "freedom",
            "settings": {
                $DOMAIN_STRATEGY
            },
            "streamSettings": {
                "packetEncoding": "xudp"
            }
        }
    ]
}
EOF
            else
                CLIENT_CONFIG="\"id\": \"$UUID\""
                TLS_SETTINGS="\"tlsSettings\": {
                    \"certificates\": [{
                        \"certificateFile\": \"$CERT_PATH\",
                        \"keyFile\": \"$KEY_PATH\"
                    }],
                    \"serverName\": \"$DOMAIN\"
                }"
                cat << EOF > "${XRAY_CONFIG}"
{
    "log": {
        "loglevel": "warning",
        "access": "/var/log/xray-access.log",
        "error": "/var/log/xray-error.log"
    },
    "inbounds": [{
        $LISTEN_IPV6
        "port": $IN_PORT,
        "protocol": "$PROTOCOL",
        "settings": {
            "clients": [{ $CLIENT_CONFIG }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "ws",
            "security": "tls",
            "wsSettings": {
                "path": "$WS_PATH",
                "headers": { "Host": "$DOMAIN" }
            },
            $TLS_SETTINGS
        }
    }],
    "outbounds": [{
        "protocol": "freedom",
        "settings": {
            $DOMAIN_STRATEGY
        }
    }]
}
EOF
            fi
            ;;
        "shadowsocks")
            cat << EOF > "${XRAY_CONFIG}"
{
    "log": {
        "loglevel": "warning",
        "access": "/var/log/xray-access.log",
        "error": "/var/log/xray-error.log"
    },
    "inbounds": [{
        $LISTEN_IPV6
        "port": $IN_PORT,
        "protocol": "shadowsocks",
        "settings": {
            "method": "$SS_METHOD",
            "password": "$PASSWORD",
            "network": "tcp,udp"
        }
    }],
    "outbounds": [{
        "protocol": "freedom",
        "settings": {
            $DOMAIN_STRATEGY
        }
    }]
}
EOF
            ;;
    esac
}

# 获取公网IP函数
get_public_ip() {
    # 尝试获取IPv6地址
    ipv6_ip=$(curl -s -m 5 -6 icanhazip.com 2>/dev/null || curl -s -m 5 -6 ifconfig.me 2>/dev/null)
    if [ -n "$ipv6_ip" ] && [[ "$ipv6_ip" == *":"* ]]; then
        echo "[$ipv6_ip]"
        return
    fi
    
    # 尝试获取IPv4地址
    ipv4_ip=$(curl -s -m 5 -4 icanhazip.com 2>/dev/null || curl -s -m 5 -4 ifconfig.me 2>/dev/null || curl -s -m 5 -4 api.ipify.org 2>/dev/null)
    if [ -n "$ipv4_ip" ] && [[ "$ipv4_ip" != *":"* ]]; then
        echo "$ipv4_ip"
        return
    fi
    
    # 如果都获取失败，返回本地IP
    hostname -I | awk '{print $1}'
}

# Xray生成客户端链接 - 增强版
generate_links() {
    # 获取公网IP
    SERVER_IP=$(get_public_ip)
    
    blue "\n=============== 客户端配置链接 ================"
    case "$PROTOCOL" in
        "vmess")
            VMESS_JSON=$(cat <<EOF
{
    "v": "2",
    "ps": "Xray_VMess",
    "add": "$DOMAIN",
    "port": "$IN_PORT",
    "id": "$UUID",
    "aid": "0",
    "scy": "auto",
    "net": "ws",
    "type": "none",
    "host": "$DOMAIN",
    "path": "$WS_PATH",
    "tls": "tls",
    "sni": "$DOMAIN"
}
EOF
            )
            VMESS_LINK="vmess://$(echo "$VMESS_JSON" | base64 -w 0)"
            green "VMess 链接：\n$VMESS_LINK"
            ;;
        "trojan")
            # 精确提取Trojan密码
            PASSWORD="$TROJAN_PASSWORD"
            TROJAN_LINK="trojan://${PASSWORD}@${DOMAIN}:${IN_PORT}?security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WS_PATH}#Xray_Trojan"
            green "Trojan 链接：\n$TROJAN_LINK"
            ;;
        "vless")
            if [[ "$VLESS_TYPE" == "Reality" ]]; then
                VLESS_LINK="vless://${UUID}@${SERVER_IP}:${IN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${dest_server}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none&packetEncoding=xudp#Vless-Reality"
                green "VLESS (Reality with XUDP) 链接：\n$VLESS_LINK"
            else
                VLESS_LINK="vless://${UUID}@${DOMAIN}:${IN_PORT}?security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WS_PATH}#Xray_VLESS"
                green "VLESS 链接：\n$VLESS_LINK"
            fi
            ;;
        "shadowsocks")
            SS_LINK="ss://$(echo -n "${SS_METHOD}:${PASSWORD}" | base64 -w 0)@${SERVER_IP}:${IN_PORT}#Xray_Shadowsocks"
            green "Shadowsocks 链接：\n$SS_LINK"
            ;;
    esac
    blue "================================================\n"
}

# ============================== Hysteria2 安装部分 ==============================
install_hysteria2() {
    # 生成符合RFC 4122标准的UUIDv4函数
    generate_uuid() {
        local bytes=$(od -x -N 16 /dev/urandom | head -1 | awk '{OFS=""; $1=""; print}')
        local byte7=${bytes:12:4}
        byte7=$((0x${byte7} & 0x0fff | 0x4000))
        byte7=$(printf "%04x" $byte7)
        local byte9=${bytes:20:4}
        byte9=$((0x${byte9} & 0x3fff | 0x8000))
        byte9=$(printf "%04x" $byte9)
        echo "${bytes:0:8}-${bytes:8:4}-${byte7}-${byte9}-${bytes:24:12}" | tr '[:upper:]' '[:lower:]'
    }

    # 获取服务器公网地址并格式化
    get_server_address() {
        # 尝试获取IPv6地址
        ipv6_ip=$(curl -s -m 5 -6 icanhazip.com 2>/dev/null || curl -s -m 5 -6 ifconfig.me 2>/dev/null)
        if [ -n "$ipv6_ip" ] && [[ "$ipv6_ip" == *":"* ]]; then
            echo "[$ipv6_ip]"
            return
        fi
        
        # 尝试获取IPv4地址
        ipv4_ip=$(curl -s -m 5 -4 icanhazip.com 2>/dev/null || curl -s -m 5 -4 ifconfig.me 2>/dev/null || curl -s -m 5 -4 api.ipify.org 2>/dev/null)
        if [ -n "$ipv4_ip" ] && [[ "$ipv4_ip" != *":"* ]]; then
            echo "$ipv4_ip"
            return
        fi
        
        # 如果都获取失败，返回本地IP
        hostname -I | awk '{print $1}'
    }

    # 安装依赖（带检测）
    install_hysteria_deps() {
        case "$OS_TYPE" in
            "alpine")
                apk update
                # 定义依赖列表
                DEPS="wget curl git openssl openrc lsof coreutils libcap"
                for pkg in $DEPS; do
                    if ! apk info -e $pkg &>/dev/null; then
                        yellow "安装 $pkg..."
                        apk add --no-cache $pkg
                    else
                        green "$pkg 已安装"
                    fi
                done
                ;;
            "ubuntu"|"debian")
                apt update
                # 定义依赖列表
                DEPS="wget curl git openssl lsof coreutils libcap2-bin"
                for pkg in $DEPS; do
                    if ! dpkg -s $pkg &>/dev/null; then
                        yellow "安装 $pkg..."
                        apt install -y $pkg
                    else
                        green "$pkg 已安装"
                    fi
                done
                ;;
            "centos")
                # CentOS 7 镜像源修复
                if grep -q "CentOS Linux 7" /etc/os-release; then
                    echo "修复 CentOS 7 镜像源..."
                    sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
                    sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
                    yum clean all
                fi
                
                # 安装EPEL仓库
                if ! rpm -q epel-release >/dev/null; then
                    yellow "安装EPEL仓库..."
                    yum install -y epel-release
                fi
                
                # 定义依赖列表
                DEPS="wget curl git openssl lsof coreutils libcap"
                for pkg in $DEPS; do
                    if ! rpm -q $pkg >/dev/null; then
                        yellow "安装 $pkg..."
                        yum install -y $pkg
                    else
                        green "$pkg 已安装"
                    fi
                done
                ;;
            *)
                red "不支持的系统类型！"
                exit 1
                ;;
        esac
    }

    # 主安装流程
    echo -e "${YELLOW}Hysteria 2 安装脚本${NC}"
    echo "---------------------------------------"
    
    # 安装依赖
    echo -e "${YELLOW}正在安装必要的软件包...${NC}" >&2
    install_hysteria_deps
    echo -e "${GREEN}依赖包安装成功。${NC}" >&2
    
    # 用户输入配置
    DEFAULT_MASQUERADE_URL="https://www.bing.com"
    DEFAULT_ACME_EMAIL="$(head /dev/urandom | tr -dc a-z | head -c 8)@gmail.com"
    
    echo "" >&2
    echo -e "${YELLOW}请选择 TLS 验证方式:${NC}" >&2
    echo "1. 自定义证书 (适用于已有证书或生成自签名证书)" >&2
    echo "2. ACME HTTP 验证 (需要域名指向本机IP，且本机80端口可用)" >&2
    read -p "请选择 [1-2, 默认 1]: " TLS_TYPE
    TLS_TYPE=${TLS_TYPE:-1}
    
    # 初始化变量
    CERT_PATH=""
    KEY_PATH=""
    DOMAIN=""
    SNI=""
    ACME_EMAIL=""
    
    case $TLS_TYPE in
        1) # 自定义证书模式
            echo -e "${YELLOW}--- 自定义证书模式 ---${NC}" >&2
            read -p "请输入证书 (.crt) 文件绝对路径 (回车则生成自签名证书): " USER_CERT_PATH
            if [ -z "$USER_CERT_PATH" ]; then
                if ! command -v openssl &> /dev/null; then
                    echo -e "${RED}错误: openssl 未安装，请手动安装后重试${NC}" >&2
                    exit 1
                fi
                read -p "请输入用于自签名证书的伪装域名 (默认 www.bing.com): " SELF_SIGN_SNI
                SELF_SIGN_SNI=${SELF_SIGN_SNI:-"www.bing.com"}
                SNI="$SELF_SIGN_SNI"
                mkdir -p /etc/hysteria/certs
                CERT_PATH="/etc/hysteria/certs/server.crt"
                KEY_PATH="/etc/hysteria/certs/server.key"
                echo "正在生成自签名证书..." >&2
                if ! openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
                    -keyout "$KEY_PATH" -out "$CERT_PATH" \
                    -subj "/CN=$SNI" -days 36500; then
                    echo -e "${RED}错误: 自签名证书生成失败，请检查 openssl 配置！${NC}" >&2
                    exit 1
                fi
                echo -e "${GREEN}自签名证书已生成: $CERT_PATH, $KEY_PATH${NC}" >&2
            else
                read -p "请输入私钥 (.key) 文件绝对路径: " USER_KEY_PATH
                if [ -z "$USER_CERT_PATH" ] || [ -z "$USER_KEY_PATH" ]; then
                    echo -e "${RED}错误: 证书和私钥路径都不能为空。${NC}" >&2
                    exit 1
                fi
                CERT_PATH=$(realpath "$USER_CERT_PATH")
                KEY_PATH=$(realpath "$USER_KEY_PATH")
                if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
                    echo -e "${RED}错误: 提供的证书或私钥文件路径无效或文件不存在。${NC}" >&2
                    exit 1
                fi
                SNI=$(openssl x509 -noout -subject -in "$CERT_PATH" 2>/dev/null | grep -o 'CN=[^,]*' | cut -d= -f2 | tr -d ' ')
                if [ -z "$SNI" ]; then
                    read -p "无法从证书自动提取CN(域名)，请输入您希望使用的SNI: " MANUAL_SNI
                    if [ -z "$MANUAL_SNI" ]; then
                        echo -e "${RED}SNI 不能为空！${NC}" >&2
                        exit 1
                    fi
                    SNI="$MANUAL_SNI"
                else
                    echo "从证书中提取到的 SNI (CN): $SNI" >&2
                fi
            fi
            ;;
        2) # ACME HTTP 验证模式
            echo -e "${YELLOW}--- ACME HTTP 验证模式 ---${NC}" >&2
            read -p "请输入您的域名 (例如: example.com): " DOMAIN
            if [ -z "$DOMAIN" ]; then
                echo -e "${RED}域名不能为空！${NC}" >&2
                exit 1
            fi
            read -p "请输入用于 ACME 证书申请的邮箱 (回车默认 $DEFAULT_ACME_EMAIL): " INPUT_ACME_EMAIL
            ACME_EMAIL=${INPUT_ACME_EMAIL:-$DEFAULT_ACME_EMAIL}
            if [ -z "$ACME_EMAIL" ]; then
                echo -e "${RED}邮箱不能为空！${NC}" >&2
                exit 1
            fi
            SNI=$DOMAIN
            echo "检查 80 端口占用情况..." >&2
            if lsof -i:80 -sTCP:LISTEN -P -n &>/dev/null; then
                echo -e "${YELLOW}警告: 检测到 80 端口已被占用。Hysteria 将尝试使用此端口进行 ACME 验证。${NC}" >&2
                PID_80=$(lsof -t -i:80 -sTCP:LISTEN)
                [ -n "$PID_80" ] && echo "占用80端口的进程 PID(s): $PID_80" >&2
            else
                echo "80 端口未被占用，可用于 ACME HTTP 验证。" >&2
            fi
            ;;
        *) # 无效选项
            echo -e "${RED}无效选项，退出脚本。${NC}" >&2
            exit 1
            ;;
    esac
    
    # 端口配置 - 仅手动输入或随机生成
    read -p "请输入 Hysteria 端口 (留空则生成随机端口): " PORT
    if [[ -z "$PORT" ]]; then
        # 生成 20000-50000 之间的随机端口
        PORT=$((RANDOM % 30001 + 20000))
        
        # 检查端口是否被占用
        while lsof -i :$PORT >/dev/null 2>&1 || netstat -an | grep -q ":$PORT "; do
            PORT=$((RANDOM % 30001 + 20000))
        done
        
        green "已生成随机端口: $PORT"
    fi
    
    # 生成随机密码（16位，包含大小写字母和数字）
    RANDOM_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
    read -p "请输入 Hysteria 密码 (回车则使用随机密码): " PASSWORD
    if [ -z "$PASSWORD" ]; then
        PASSWORD=$RANDOM_PASSWORD
        echo "使用随机密码: $PASSWORD" >&2
    fi
    
    read -p "请输入伪装访问的目标URL (默认 $DEFAULT_MASQUERADE_URL): " MASQUERADE_URL
    MASQUERADE_URL=${MASQUERADE_URL:-$DEFAULT_MASQUERADE_URL}
    
    # 获取服务器公网地址
    SERVER_PUBLIC_ADDRESS=$(get_server_address)
    
    mkdir -p /etc/hysteria
    
    # 下载 Hysteria 二进制文件
    HYSTERIA_BIN="/usr/local/bin/hysteria"
    echo -e "${YELLOW}正在下载 Hysteria 最新版...${NC}" >&2
    ARCH=$(uname -m)
    case ${ARCH} in
        x86_64) HYSTERIA_ARCH="amd64";;
        aarch64) HYSTERIA_ARCH="arm64";;
        armv7l) HYSTERIA_ARCH="arm";;
        *) echo -e "${RED}不支持的系统架构: ${ARCH}${NC}" >&2; exit 1;;
    esac
    
    if ! wget -qO "$HYSTERIA_BIN" "https://download.hysteria.network/app/latest/hysteria-linux-${HYSTERIA_ARCH}"; then
        echo -e "${RED}下载 Hysteria 失败，请检查网络或手动下载。${NC}" >&2
        exit 1
    fi
    
    chmod +x "$HYSTERIA_BIN"
    echo -e "${GREEN}Hysteria 下载并设置权限完成: $HYSTERIA_BIN${NC}" >&2
    
    # 设置权限（ACME模式）
    if [ "$TLS_TYPE" -eq 2 ]; then
        echo "为 Hysteria 二进制文件设置权限..." >&2
        if ! command -v setcap &>/dev/null; then
            echo -e "${YELLOW}setcap 命令未找到，尝试安装依赖...${NC}" >&2
            case "$OS_TYPE" in
                "alpine") apk add --no-cache libcap >/dev/null ;;
                "ubuntu"|"debian") apt install -y libcap2-bin >/dev/null ;;
                "centos") yum install -y libcap >/dev/null ;;
            esac
        fi
        
        if ! setcap 'cap_net_bind_service=+ep' "$HYSTERIA_BIN"; then
            echo -e "${RED}错误: setcap 失败。ACME HTTP 验证可能无法工作。${NC}" >&2
        else
            echo -e "${GREEN}权限设置成功。${NC}" >&2
        fi
    fi
    
    # 生成配置文件
    echo -e "${YELLOW}正在生成配置文件 /etc/hysteria/config.yaml...${NC}" >&2
    cat > /etc/hysteria/config.yaml << EOF
listen: :$PORT
auth:
  type: password
  password: $PASSWORD
masquerade:
  type: proxy
  proxy:
    url: $MASQUERADE_URL
    rewriteHost: true
EOF

    # 根据TLS类型追加配置
    case $TLS_TYPE in
        1) # 自定义证书
            cat >> /etc/hysteria/config.yaml << EOF
tls:
  cert: $CERT_PATH
  key: $KEY_PATH
EOF
            LINK_SNI="$SNI"
            LINK_INSECURE=1
            echo -e "${YELLOW}注意: 使用自定义证书时，客户端需要设置 'insecure: true'${NC}" >&2
            ;;
        2) # ACME HTTP
            cat >> /etc/hysteria/config.yaml << EOF
acme:
  domains:
    - $DOMAIN
  email: $ACME_EMAIL
EOF
            LINK_SNI="$DOMAIN"
            LINK_INSECURE=0
            ;;
    esac
    echo -e "${GREEN}配置文件生成完毕。${NC}" >&2

    # 配置服务管理
    case "$OS_TYPE" in
        "alpine") # OpenRC 服务配置
            echo -e "${YELLOW}正在创建 OpenRC 服务文件 /etc/init.d/hysteria...${NC}" >&2
            cat > /etc/init.d/hysteria << EOF
#!/sbin/openrc-run
name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
pidfile="/var/run/\${name}.pid"
respawn_delay=5
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -f \$output_log -m 0644
    checkpath -f \$error_log -m 0644
}

start() {
    ebegin "Starting \$name"
    # 使用正确的start-stop-daemon语法
    start-stop-daemon --start --background \\
        --exec \$command \\
        --make-pidfile --pidfile \$pidfile \\
        -- \\
        \$command_args
    eend \$?
}

stop() {
    ebegin "Stopping \$name"
    start-stop-daemon --stop --pidfile \$pidfile
    eend \$?
}
EOF
            chmod +x /etc/init.d/hysteria
            rc-update add hysteria default >/dev/null
            service hysteria stop >/dev/null 2>&1
            service hysteria start
            ;;
        "ubuntu"|"debian"|"centos")
            # systemd 服务配置
            echo -e "${YELLOW}正在创建 systemd 服务文件 /etc/systemd/system/hysteria.service...${NC}" >&2
            cat > /etc/systemd/system/hysteria.service << EOF
[Unit]
Description=Hysteria VPN Service
After=network.target

[Service]
ExecStart=$HYSTERIA_BIN server --config /etc/hysteria/config.yaml
Restart=always
User=root
LimitNOFILE=infinity
StandardOutput=file:/var/log/hysteria.log
StandardError=file:/var/log/hysteria.error.log

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable hysteria
            systemctl stop hysteria >/dev/null 2>&1
            systemctl start hysteria
            ;;
    esac

    # 等待服务启动
    echo -e "${GREEN}等待服务启动...${NC}" >&2
    sleep 3
    
    # 检查服务状态
    case "$OS_TYPE" in
        "alpine")
            if rc-service hysteria status | grep -q "started"; then
                echo -e "${GREEN}Hysteria 服务已成功启动！${NC}"
            else
                echo -e "${RED}Hysteria 服务状态异常。请检查日志:${NC}"
                echo "  输出日志: tail -n 20 /var/log/hysteria.log"
                echo "  错误日志: tail -n 20 /var/log/hysteria.error.log"
            fi
            ;;
        "ubuntu"|"debian"|"centos")
            if systemctl is-active --quiet hysteria; then
                echo -e "${GREEN}Hysteria 服务已成功启动！${NC}"
            else
                echo -e "${RED}Hysteria 服务状态异常。请检查日志:${NC}"
                systemctl status hysteria
            fi
            ;;
    esac
    
    # 生成订阅链接
    if [ "$TLS_TYPE" -eq 2 ]; then
        # ACME模式使用域名
        LINK_ADDRESS="$DOMAIN"
    else
        # 自定义证书模式使用服务器IP
        LINK_ADDRESS="$SERVER_PUBLIC_ADDRESS"
        # 如果获取IP失败，使用备用域名
        if [ -z "$LINK_ADDRESS" ]; then
            LINK_ADDRESS="$SNI"
            yellow "警告: 无法获取公网IP，将使用SNI域名作为服务器地址"
        fi
    fi
    
    SUBSCRIPTION_LINK="hysteria2://${PASSWORD}@${LINK_ADDRESS}:${PORT}/?sni=${LINK_SNI}&insecure=${LINK_INSECURE}&alpn=h3#Hysteria-${LINK_SNI}"
    
    # 显示结果
    echo ""
    echo "------------------------------------------------------------------------"
    echo -e "${GREEN}Hysteria 2 安装和配置完成！${NC}"
    echo "------------------------------------------------------------------------"
    echo "服务器地址: ${LINK_ADDRESS}"
    echo "端口: $PORT"
    echo "密码: $PASSWORD"
    echo "SNI / 伪装域名: $LINK_SNI"
    echo "伪装目标站点: $MASQUERADE_URL"
    echo "TLS 模式: $([ "$TLS_TYPE" -eq 1 ] && echo "自定义证书" || echo "ACME HTTP")"
    
    if [ "$TLS_TYPE" -eq 1 ]; then
        echo "证书路径: $CERT_PATH"
        echo "私钥路径: $KEY_PATH"
    elif [ "$TLS_TYPE" -eq 2 ]; then
        echo "ACME 邮箱: $ACME_EMAIL"
    fi
    
    echo "客户端 insecure (0=false, 1=true): $LINK_INSECURE"
    echo "------------------------------------------------------------------------"
    echo -e "${YELLOW}订阅链接 (Hysteria V2):${NC}"
    echo "$SUBSCRIPTION_LINK"
    echo "------------------------------------------------------------------------"
    
    # 移除二维码显示部分
    
    echo "------------------------------------------------------------------------"
    echo "管理命令："
    case "$OS_TYPE" in
        "alpine")
            echo " service hysteria start - 启动服务"
            echo " service hysteria stop - 停止服务"
            echo " service hysteria restart - 重启服务"
            echo " service hysteria status - 查看状态"
            ;;
        "ubuntu"|"debian"|"centos")
            echo " systemctl start hysteria - 启动服务"
            echo " systemctl stop hysteria - 停止服务"
            echo " systemctl restart hysteria - 重启服务"
            echo " systemctl status hysteria - 查看状态"
            ;;
    esac
    echo " cat /etc/hysteria/config.yaml - 查看配置文件"
    echo " tail -f /var/log/hysteria.log - 查看实时日志"
    echo " tail -f /var/log/hysteria.error.log - 查看实时错误日志"
    
    echo "一键卸载命令："
    case "$OS_TYPE" in
        "alpine")
            echo " service hysteria stop ; rc-update del hysteria ; rm /etc/init.d/hysteria ; rm /usr/local/bin/hysteria ; rm -rf /etc/hysteria"
            ;;
        "ubuntu"|"debian"|"centos")
            echo " systemctl stop hysteria ; systemctl disable hysteria ; rm /etc/systemd/system/hysteria.service ; rm /usr/local/bin/hysteria ; rm -rf /etc/hysteria"
            ;;
    esac
    echo "------------------------------------------------------------------------"
    
    # 添加暂停以便用户查看链接
    read -p "按回车键返回主菜单..."
}

# ============================== AnyTLS-Go 安装部分 ==============================
install_anytls_go() {
    # 定义版本和下载URL
    ANYTLS_VERSION="v0.0.8"
    BASE_URL="https://github.com/anytls/anytls-go/releases/download"
    INSTALL_DIR="/usr/local/bin"
    BINARY_NAME="anytls-server"
    SERVICE_NAME="anytls-server"

    # 清理旧日志
    rm -f /var/log/anytls*.log

    yellow "检测系统类型：$OS_TYPE"
    
    # 安装 AnyTLS-Go 不再需要 jq, 但保留通用依赖安装
    install_anytls_deps() {
        case "$OS_TYPE" in
            "alpine")
                apk update
                DEPS="curl wget unzip openrc"
                for pkg in $DEPS; do
                    if ! apk info -e $pkg &>/dev/null; then
                        yellow "安装 $pkg..."
                        apk add --no-cache $pkg
                    else
                        green "$pkg 已安装"
                    fi
                done
                ;;
            "ubuntu"|"debian")
                apt update
                DEPS="curl wget unzip"
                for pkg in $DEPS; do
                    if ! dpkg -s $pkg &>/dev/null; then
                        yellow "安装 $pkg..."
                        apt install -y $pkg
                    else
                        green "$pkg 已安装"
                    fi
                done
                ;;
            "centos")
                DEPS="curl wget unzip"
                for pkg in $DEPS; do
                    if ! rpm -q $pkg >/dev/null; then
                        yellow "安装 $pkg..."
                        yum install -y $pkg
                    else
                        green "$pkg 已安装"
                    fi
                done
                ;;
            *)
                red "不支持的系统类型！"
                exit 1
                ;;
        esac
    }
    yellow "开始安装依赖..."
    install_anytls_deps
    
    # 输入配置信息
    read -p "请输入监听端口（默认8443）：" PORT
    [[ -z "$PORT" ]] && PORT=8443
    
    # 生成随机密码（16位，包含大小写字母和数字）
    RANDOM_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
    read -p "请输入 AnyTLS 服务端密码 (回车则使用随机密码): " PASSWORD
    if [ -z "$PASSWORD" ]; then
        PASSWORD=$RANDOM_PASSWORD
        green "随机密码已生成: $PASSWORD"
    fi
    
    # 获取系统架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64) ANYTLS_ARCH="amd64";;
        aarch64|arm64) ANYTLS_ARCH="arm64";;
        *) echo -e "${RED}不支持的系统架构: ${ARCH}${NC}"; exit 1;;
    esac
    green "检测到系统架构: $ANYTLS_ARCH"

    # 下载并安装AnyTLS-Go
    FILENAME="anytls_${ANYTLS_VERSION#v}_linux_${ANYTLS_ARCH}.zip"
    DOWNLOAD_URL="${BASE_URL}/${ANYTLS_VERSION}/${FILENAME}"
    TEMP_DIR=$(mktemp -d)

    yellow "正在下载 AnyTLS-Go..."
    if ! wget -q -O "${TEMP_DIR}/${FILENAME}" "$DOWNLOAD_URL"; then
        red "错误: 下载 AnyTLS-Go 失败。"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    yellow "正在解压文件..."
    if ! unzip -q -d "$TEMP_DIR" "${TEMP_DIR}/${FILENAME}"; then
        red "错误: 解压 AnyTLS-Go 失败。"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    if [ ! -f "${TEMP_DIR}/${BINARY_NAME}" ]; then
        red "错误: 解压后未找到 ${BINARY_NAME}。"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # 安装二进制文件
    yellow "正在安装服务端程序到 ${INSTALL_DIR}/${BINARY_NAME} ..."
    if ! mv "${TEMP_DIR}/${BINARY_NAME}" "${INSTALL_DIR}/${BINARY_NAME}"; then
        red "错误: 移动 ${BINARY_NAME} 失败。"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    chmod +x "${INSTALL_DIR}/${BINARY_NAME}"
    rm -rf "$TEMP_DIR"

    # 配置服务
    case "$OS_TYPE" in
        "alpine")
            # OpenRC 服务配置
            cat > /etc/init.d/${SERVICE_NAME} << EOF
#!/sbin/openrc-run
name="${SERVICE_NAME}"
description="AnyTLS-Go Service"
command="${INSTALL_DIR}/${BINARY_NAME}"
command_args="-l :${PORT} -p \"${PASSWORD}\""
pidfile="/var/run/\${name}.pid"
respawn_delay=5
output_log="/var/log/anytls.log"
error_log="/var/log/anytls.error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -f \$output_log -m 0644
    checkpath -f \$error_log -m 0644
}

start() {
    ebegin "Starting \$name"
    start-stop-daemon --start \\
        --exec \$command \\
        --background \\
        --make-pidfile --pidfile \$pidfile \\
        -- \\
        \$command_args
    eend \$?
}

stop() {
    ebegin "Stopping \$name"
    start-stop-daemon --stop --pidfile \$pidfile
    eend \$?
}
EOF
            chmod +x "/etc/init.d/${SERVICE_NAME}"
            rc-update add ${SERVICE_NAME} default >/dev/null
            service ${SERVICE_NAME} restart
            ;;
        "ubuntu"|"debian"|"centos")
            # systemd 服务配置
            cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=AnyTLS-Go Service
After=network.target

[Service]
ExecStart=${INSTALL_DIR}/${BINARY_NAME} -l :${PORT} -p "${PASSWORD}"
Restart=always
User=root
LimitNOFILE=30000
StandardOutput=file:/var/log/anytls.log
StandardError=file:/var/log/anytls.error.log

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable ${SERVICE_NAME}
            systemctl restart ${SERVICE_NAME}
            ;;
    esac

    # 获取公网IP
    SERVER_IP=$(get_public_ip)

    # 生成客户端链接
    ANYTLS_LINK="anytls://${PASSWORD}@${SERVER_IP}:${PORT}#Anytls-Go"

    # 显示结果
    echo ""
    echo "------------------------------------------------------------------------"
    echo -e "${GREEN}AnyTLS-Go 服务安装完成！${NC}"
    echo "------------------------------------------------------------------------"
    echo "服务器地址: ${SERVER_IP}"
    echo "端口: $PORT"
    echo "密码: $PASSWORD"
    echo "------------------------------------------------------------------------"
    echo -e "${YELLOW}客户端链接:${NC}"
    echo "$ANYTLS_LINK"
    echo "------------------------------------------------------------------------"
    
    echo "管理命令："
    case "$OS_TYPE" in
        "alpine")
            echo " service ${SERVICE_NAME} start - 启动服务"
            echo " service ${SERVICE_NAME} stop - 停止服务"
            echo " service ${SERVICE_NAME} restart - 重启服务"
            echo " service ${SERVICE_NAME} status - 查看状态"
            ;;
        "ubuntu"|"debian"|"centos")
            echo " systemctl start ${SERVICE_NAME} - 启动服务"
            echo " systemctl stop ${SERVICE_NAME} - 停止服务"
            echo " systemctl restart ${SERVICE_NAME} - 重启服务"
            echo " systemctl status ${SERVICE_NAME} - 查看状态"
            ;;
    esac
    echo "日志文件: /var/log/anytls.log"
    echo "错误日志: /var/log/anytls.error.log"
    
    echo "一键卸载命令："
    case "$OS_TYPE" in
        "alpine")
            echo " service ${SERVICE_NAME} stop ; rc-update del ${SERVICE_NAME} ; rm /etc/init.d/${SERVICE_NAME} ; rm ${INSTALL_DIR}/${BINARY_NAME}"
            ;;
        "ubuntu"|"debian"|"centos")
            echo " systemctl stop ${SERVICE_NAME} ; systemctl disable ${SERVICE_NAME} ; rm /etc/systemd/system/${SERVICE_NAME}.service ; rm ${INSTALL_DIR}/${BINARY_NAME}"
            ;;
    esac
    echo "------------------------------------------------------------------------"
    
    # 添加暂停以便用户查看链接
    read -p "按回车键返回主菜单..."
}

# ============================== 卸载功能 ==============================
uninstall_xray() {
    # 检查是否安装了 Xray
    if [ ! -f "${XRAY_BIN}" ]; then
        red "未找到 Xray 安装文件，可能未安装 Xray 服务！"
        sleep 2
        return
    fi
    
    echo -e "${YELLOW}开始卸载 Xray...${NC}"
    
    # 停止服务
    case "$OS_TYPE" in
        "alpine")
            service xray stop >/dev/null 2>&1
            rc-update del xray >/dev/null 2>&1
            rm -f "${XRAY_SERVICE_OPENRC}"
            ;;
        "debian"|"ubuntu"|"centos")
            systemctl stop xray >/dev/null 2>&1
            systemctl disable xray >/dev/null 2>&1
            rm -f "${XRAY_SERVICE_SYSTEMD}"
            systemctl daemon-reload
            ;;
    esac
    
    # 删除文件
    rm -rf "${XRAY_DIR}"
    rm -f ${XRAY_LOG_DIR}/xray*.log
    
    echo -e "${GREEN}Xray 已成功卸载！${NC}"
    sleep 2
}

uninstall_hysteria2() {
    # 检查是否安装了 Hysteria2
    if [ ! -f "/usr/local/bin/hysteria" ]; then
        red "未找到 Hysteria2 安装文件，可能未安装 Hysteria2 服务！"
        sleep 2
        return
    fi
    
    echo -e "${YELLOW}开始卸载 Hysteria2...${NC}"
    
    # 停止服务
    case "$OS_TYPE" in
        "alpine")
            service hysteria stop >/dev/null 2>&1
            rc-update del hysteria >/dev/null 2>&1
            rm -f /etc/init.d/hysteria
            ;;
        "ubuntu"|"debian"|"centos")
            systemctl stop hysteria >/dev/null 2>&1
            systemctl disable hysteria >/dev/null 2>&1
            rm -f /etc/systemd/system/hysteria.service
            systemctl daemon-reload
            ;;
    esac
    
    # 删除文件
    rm -f /usr/local/bin/hysteria
    rm -rf /etc/hysteria
    rm -f /var/log/hysteria*.log
    
    echo -e "${GREEN}Hysteria2 已成功卸载！${NC}"
    sleep 2
}

uninstall_anytls_go() {
    # 定义服务名称和二进制路径
    SERVICE_NAME="anytls-server"
    BINARY_PATH="/usr/local/bin/anytls-server"
    
    # 检查是否安装了 AnyTLS-Go
    if [ ! -f "$BINARY_PATH" ]; then
        red "未找到 AnyTLS-Go 安装文件，可能未安装 AnyTLS-Go 服务！"
        sleep 2
        return
    fi
    
    echo -e "${YELLOW}开始卸载 AnyTLS-Go...${NC}"
    
    # 停止服务
    case "$OS_TYPE" in
        "alpine")
            service $SERVICE_NAME stop >/dev/null 2>&1
            rc-update del $SERVICE_NAME >/dev/null 2>&1
            rm -f /etc/init.d/$SERVICE_NAME
            ;;
        "ubuntu"|"debian"|"centos")
            systemctl stop $SERVICE_NAME >/dev/null 2>&1
            systemctl disable $SERVICE_NAME >/dev/null 2>&1
            rm -f /etc/systemd/system/${SERVICE_NAME}.service
            systemctl daemon-reload
            ;;
    esac
    
    # 删除文件
    rm -f $BINARY_PATH
    rm -f /var/log/anytls*.log
    
    echo -e "${GREEN}AnyTLS-Go 已成功卸载！${NC}"
    sleep 2
}

# ============================== 显示客户端链接 ==============================
show_xray_links() {
    ensure_jq # 确保 jq 已安装
    
    if [ ! -f "${XRAY_CONFIG}" ]; then
        red "未找到 Xray 配置文件，请先安装 Xray！"
        sleep 2
        return
    fi
    
    # 使用 jq 解析配置文件
    PROTOCOL=$(jq -r '.inbounds[0].protocol' "${XRAY_CONFIG}")
    IN_PORT=$(jq -r '.inbounds[0].port' "${XRAY_CONFIG}")
    
    # 获取公网IP
    SERVER_IP=$(get_public_ip)
    
    case "$PROTOCOL" in
        "vmess"|"vless"|"trojan")
            # 获取域名
            DOMAIN=$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName' "${XRAY_CONFIG}")
            if [ "$DOMAIN" == "null" ]; then
                DOMAIN=$SERVER_IP
            fi
            
            # 获取 WebSocket 路径
            WS_PATH=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "${XRAY_CONFIG}")
            if [ "$WS_PATH" == "null" ]; then
                WS_PATH="/"
            fi
            
            case "$PROTOCOL" in
                "vmess")
                    UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "${XRAY_CONFIG}")
                    VMESS_JSON=$(cat <<EOF
{
    "v": "2",
    "ps": "Xray_VMess",
    "add": "$DOMAIN",
    "port": "$IN_PORT",
    "id": "$UUID",
    "aid": "0",
    "scy": "auto",
    "net": "ws",
    "type": "none",
    "host": "$DOMAIN",
    "path": "$WS_PATH",
    "tls": "tls",
    "sni": "$DOMAIN"
}
EOF
                    )
                    VMESS_LINK="vmess://$(echo "$VMESS_JSON" | base64 -w 0)"
                    blue "\n=============== VMess 客户端链接 ================"
                    green "$VMESS_LINK"
                    ;;
                "trojan")
                    PASSWORD=$(jq -r '.inbounds[0].settings.clients[0].password' "${XRAY_CONFIG}")
                    if [ -z "$PASSWORD" ] || [ "$PASSWORD" == "null" ]; then
                        red "无法提取Trojan密码，请检查配置文件"
                    else
                        TROJAN_LINK="trojan://${PASSWORD}@${DOMAIN}:${IN_PORT}?security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WS_PATH}#Xray_Trojan"
                        blue "\n=============== Trojan 客户端链接 ================"
                        green "$TROJAN_LINK"
                    fi
                    ;;
                "vless")
                    UUID=$(jq -r '.inbounds[0].settings.clients[0].id' "${XRAY_CONFIG}")
                    
                    # 检查是否是Reality模式
                    SECURITY_TYPE=$(jq -r '.inbounds[0].streamSettings.security' "${XRAY_CONFIG}")
                    if [ "$SECURITY_TYPE" == "reality" ]; then
                        # 提取Reality配置
                        dest_server=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "${XRAY_CONFIG}" | cut -d: -f1)
                        public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "${XRAY_CONFIG}")
                        short_id=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "${XRAY_CONFIG}")
                        
                        VLESS_LINK="vless://${UUID}@${SERVER_IP}:${IN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${dest_server}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none&packetEncoding=xudp#Vless-Reality"
                        blue "\n=============== VLESS (Reality) 客户端链接 ================"
                        green "$VLESS_LINK"
                    else
                        VLESS_LINK="vless://${UUID}@${DOMAIN}:${IN_PORT}?security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=${WS_PATH}#Xray_VLESS"
                        blue "\n=============== VLESS 客户端链接 ================"
                        green "$VLESS_LINK"
                    fi
                    ;;
            esac
            ;;
        "shadowsocks")
            METHOD=$(jq -r '.inbounds[0].settings.method' "${XRAY_CONFIG}")
            PASSWORD=$(jq -r '.inbounds[0].settings.password' "${XRAY_CONFIG}")
            
            SS_LINK="ss://$(echo -n "${METHOD}:${PASSWORD}" | base64 -w 0)@${SERVER_IP}:${IN_PORT}#Xray_Shadowsocks"
            
            blue "\n=============== Shadowsocks 客户端链接 ================"
            green "$SS_LINK"
            ;;
        *)
            red "未知协议类型: $PROTOCOL"
            ;;
    esac
    
    echo -e "${YELLOW}==============================================${NC}"
    read -p "按回车键返回..." 
}

show_hysteria_links() {
    if [ ! -f "/etc/hysteria/config.yaml" ]; then
        red "未找到 Hysteria2 配置文件，请先安装 Hysteria2！"
        sleep 2
        return
    fi
    
    # 从配置文件中提取信息
    PORT=$(grep 'listen:' /etc/hysteria/config.yaml | awk '{print $2}' | tr -d ':')
    PASSWORD=$(grep 'password:' /etc/hysteria/config.yaml | awk '{print $2}')
    MASQUERADE_URL=$(grep 'url:' /etc/hysteria/config.yaml | awk '{print $2}')
    
    # 获取TLS类型
    if grep -q 'acme:' /etc/hysteria/config.yaml; then
        TLS_TYPE=2
        DOMAIN=$(grep 'domains:' -A1 /etc/hysteria/config.yaml | tail -1 | awk '{print $2}' | tr -d '- ')
        LINK_SNI="$DOMAIN"
        LINK_INSECURE=0
    else
        TLS_TYPE=1
        CERT_PATH=$(grep 'cert:' /etc/hysteria/config.yaml | awk '{print $2}')
        # 尝试从证书提取域名
        if [ -f "$CERT_PATH" ]; then
            LINK_SNI=$(openssl x509 -noout -subject -in "$CERT_PATH" 2>/dev/null | grep -o 'CN=[^,]*' | cut -d= -f2 | tr -d ' ')
        fi
        if [ -z "$LINK_SNI" ]; then
            LINK_SNI="your_domain.com"
        fi
        LINK_INSECURE=1
    fi
    
    # 获取服务器地址
    SERVER_PUBLIC_ADDRESS=$(get_public_ip)
    
    if [ "$TLS_TYPE" -eq 2 ]; then
        LINK_ADDRESS="$DOMAIN"
    else
        LINK_ADDRESS="$SERVER_PUBLIC_ADDRESS"
    fi
    
    SUBSCRIPTION_LINK="hysteria2://${PASSWORD}@${LINK_ADDRESS}:${PORT}/?sni=${LINK_SNI}&insecure=${LINK_INSECURE}&alpn=h3#Hysteria-${LINK_SNI}"
    
    blue "\n=============== Hysteria2 客户端链接 ================"
    green "$SUBSCRIPTION_LINK"
    echo -e "${YELLOW}==============================================${NC}"
    
    read -p "按回车键返回..." 
}

show_anytls_links() {
    # 定义服务名称和二进制路径
    SERVICE_NAME="anytls-server"
    BINARY_PATH="/usr/local/bin/anytls-server"
    
    # 检查是否安装了 AnyTLS-Go
    if [ ! -f "$BINARY_PATH" ]; then
        red "未找到 AnyTLS-Go 安装文件，请先安装 AnyTLS-Go！"
        sleep 2
        return
    fi
    
    # 获取配置信息
    case "$OS_TYPE" in
        "alpine")
            PORT=$(grep 'command_args=' /etc/init.d/$SERVICE_NAME | grep -oE -- '-l :[0-9]+' | awk -F':' '{print $2}')
            PASSWORD=$(grep 'command_args=' /etc/init.d/$SERVICE_NAME | grep -oE -- '-p "[^"]+"' | awk -F'"' '{print $2}')
            ;;
        "ubuntu"|"debian"|"centos")
            PORT=$(grep 'ExecStart=' /etc/systemd/system/${SERVICE_NAME}.service | grep -oE -- '-l :[0-9]+' | awk -F':' '{print $2}')
            PASSWORD=$(grep 'ExecStart=' /etc/systemd/system/${SERVICE_NAME}.service | grep -oE -- '-p "[^"]+"' | awk -F'"' '{print $2}')
            ;;
    esac
    
    # 获取公网IP
    SERVER_IP=$(get_public_ip)

    # 生成客户端链接
    ANYTLS_LINK="anytls://${PASSWORD}@${SERVER_IP}:${PORT}#Anytls-Go"

    # 显示结果
    blue "\n=============== AnyTLS-Go 客户端链接 ================"
    green "$ANYTLS_LINK"
    echo -e "${YELLOW}==============================================${NC}"
    
    read -p "按回车键返回..." 
}

# ============================== 服务控制函数 ==============================
start_xray() {
    if [ ! -f "${XRAY_BIN}" ]; then
        red "未找到 Xray 安装文件，请先安装 Xray！"
        sleep 2
        return
    fi
    
    case "$OS_TYPE" in
        "alpine")
            service xray start
            ;;
        "debian"|"ubuntu"|"centos")
            systemctl start xray
            ;;
    esac
    echo -e "${GREEN}Xray 已启动${NC}"
    sleep 2
}

stop_xray() {
    if [ ! -f "${XRAY_BIN}" ]; then
        red "未找到 Xray 安装文件，请先安装 Xray！"
        sleep 2
        return
    fi
    
    case "$OS_TYPE" in
        "alpine")
            service xray stop
            ;;
        "debian"|"ubuntu"|"centos")
            systemctl stop xray
            ;;
    esac
    echo -e "${YELLOW}Xray 已停止${NC}"
    sleep 2
}

restart_xray() {
    if [ ! -f "${XRAY_BIN}" ]; then
        red "未找到 Xray 安装文件，请先安装 Xray！"
        sleep 2
        return
    fi
    
    case "$OS_TYPE" in
        "alpine")
            service xray restart
            ;;
        "debian"|"ubuntu"|"centos")
            systemctl restart xray
            ;;
    esac
    echo -e "${CYAN}Xray 已重启${NC}"
    sleep 2
}

start_hysteria2() {
    if [ ! -f "/usr/local/bin/hysteria" ]; then
        red "未找到 Hysteria2 安装文件，请先安装 Hysteria2！"
        sleep 2
        return
    fi
    
    case "$OS_TYPE" in
        "alpine")
            service hysteria start
            ;;
        "ubuntu"|"debian"|"centos")
            systemctl start hysteria
            ;;
    esac
    echo -e "${GREEN}Hysteria 2 已启动${NC}"
    sleep 2
}

stop_hysteria2() {
    if [ ! -f "/usr/local/bin/hysteria" ]; then
        red "未找到 Hysteria2 安装文件，请先安装 Hysteria2！"
        sleep 2
        return
    fi
    
    case "$OS_TYPE" in
        "alpine")
            service hysteria stop
            ;;
        "ubuntu"|"debian"|"centos")
            systemctl stop hysteria
            ;;
    esac
    echo -e "${YELLOW}Hysteria 2 已停止${NC}"
    sleep 2
}

restart_hysteria2() {
    if [ ! -f "/usr/local/bin/hysteria" ]; then
        red "未找到 Hysteria2 安装文件，请先安装 Hysteria2！"
        sleep 2
        return
    fi
    
    case "$OS_TYPE" in
        "alpine")
            service hysteria restart
            ;;
        "ubuntu"|"debian"|"centos")
            systemctl restart hysteria
            ;;
    esac
    echo -e "${CYAN}Hysteria 2 已重启${NC}"
    sleep 2
}

start_anytls_go() {
    # 定义服务名称
    SERVICE_NAME="anytls-server"
    
    # 检查是否安装了 AnyTLS-Go
    if [ ! -f "/usr/local/bin/$SERVICE_NAME" ]; then
        red "未找到 AnyTLS-Go 安装文件，请先安装 AnyTLS-Go！"
        sleep 2
        return
    fi
    
    case "$OS_TYPE" in
        "alpine")
            service $SERVICE_NAME start
            ;;
        "ubuntu"|"debian"|"centos")
            systemctl start $SERVICE_NAME
            ;;
    esac
    echo -e "${GREEN}AnyTLS-Go 已启动${NC}"
    sleep 2
}

stop_anytls_go() {
    # 定义服务名称
    SERVICE_NAME="anytls-server"
    
    # 检查是否安装了 AnyTLS-Go
    if [ ! -f "/usr/local/bin/$SERVICE_NAME" ]; then
        red "未找到 AnyTLS-Go 安装文件，请先安装 AnyTLS-Go！"
        sleep 2
        return
    fi
    
    case "$OS_TYPE" in
        "alpine")
            service $SERVICE_NAME stop
            ;;
        "ubuntu"|"debian"|"centos")
            systemctl stop $SERVICE_NAME
            ;;
    esac
    echo -e "${YELLOW}AnyTLS-Go 已停止${NC}"
    sleep 2
}

restart_anytls_go() {
    # 定义服务名称
    SERVICE_NAME="anytls-server"
    
    # 检查是否安装了 AnyTLS-Go
    if [ ! -f "/usr/local/bin/$SERVICE_NAME" ]; then
        red "未找到 AnyTLS-Go 安装文件，请先安装 AnyTLS-Go！"
        sleep 2
        return
    fi
    
    case "$OS_TYPE" in
        "alpine")
            service $SERVICE_NAME restart
            ;;
        "ubuntu"|"debian"|"centos")
            systemctl restart $SERVICE_NAME
            ;;
    esac
    echo -e "${CYAN}AnyTLS-Go 已重启${NC}"
    sleep 2
}

# ============================== 修改端口功能 ==============================
change_port() {
    echo -e "${YELLOW}请选择要修改端口的服务：${NC}"
    echo "1. Xray"
    echo "2. Hysteria2"
    echo "3. AnyTLS-Go"
    read -p "请选择 [1-3]: " service_choice

    case $service_choice in
        1) # Xray
            ensure_jq # 确保 jq 已安装
            
            if [ ! -f "${XRAY_CONFIG}" ]; then
                red "未找到 Xray 配置文件，请先安装 Xray！"
                sleep 2
                return
            fi
            
            # 显示当前端口
            current_port=$(jq -r '.inbounds[0].port' "${XRAY_CONFIG}")
            green "当前 Xray 端口: $current_port"
            
            # 输入新端口
            read -p "请输入新的监听端口: " new_port
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                red "无效的端口号！请输入 1-65535 之间的数字。"
                sleep 2
                return
            fi
            
            # 检查端口是否被占用
            if lsof -i :$new_port >/dev/null 2>&1 || netstat -an | grep -q ":$new_port "; then
                red "端口 $new_port 已被占用，请选择其他端口！"
                sleep 2
                return
            fi
            
            # 使用 jq 修改配置文件
            jq --argjson new_port "$new_port" '.inbounds[0].port = $new_port' "${XRAY_CONFIG}" > "${XRAY_CONFIG}.tmp"
            mv "${XRAY_CONFIG}.tmp" "${XRAY_CONFIG}"
            
            # 重启服务
            restart_xray
            green "Xray 端口已成功修改为: $new_port"
            ;;

        2) # Hysteria2
            if [ ! -f "/etc/hysteria/config.yaml" ]; then
                red "未找到 Hysteria2 配置文件，请先安装 Hysteria2！"
                sleep 2
                return
            fi
            
            # 显示当前端口
            current_port=$(grep 'listen:' /etc/hysteria/config.yaml | awk '{print $2}' | tr -d ':')
            green "当前 Hysteria2 端口: $current_port"
            
            # 输入新端口
            read -p "请输入新的监听端口: " new_port
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                red "无效的端口号！请输入 1-65535 之间的数字。"
                sleep 2
                return
            fi
            
            # 检查端口是否被占用
            if lsof -i :$new_port >/dev/null 2>&1 || netstat -an | grep -q ":$new_port "; then
                red "端口 $new_port 已被占用，请选择其他端口！"
                sleep 2
                return
            fi
            
            # 修改配置文件
            sed -i "s/listen: :$current_port/listen: :$new_port/" /etc/hysteria/config.yaml
            
            # 重启服务
            restart_hysteria2
            green "Hysteria2 端口已成功修改为: $new_port"
            ;;
            
        3) # AnyTLS-Go
            SERVICE_NAME="anytls-server"
            BINARY_PATH="/usr/local/bin/anytls-server"
            
            # 检查是否安装了 AnyTLS-Go
            if [ ! -f "$BINARY_PATH" ]; then
                red "未找到 AnyTLS-Go 安装文件，请先安装 AnyTLS-Go！"
                sleep 2
                return
            fi
            
            # 获取当前端口
            case "$OS_TYPE" in
                "alpine")
                    current_port=$(grep 'command_args=' /etc/init.d/$SERVICE_NAME | grep -oE -- '-l :[0-9]+' | awk -F':' '{print $2}')
                    ;;
                "ubuntu"|"debian"|"centos")
                    current_port=$(grep 'ExecStart=' /etc/systemd/system/${SERVICE_NAME}.service | grep -oE -- '-l :[0-9]+' | awk -F':' '{print $2}')
                    ;;
            esac
            
            if [ -z "$current_port" ]; then
                red "无法获取当前端口，请检查服务配置！"
                sleep 2
                return
            fi
            
            green "当前 AnyTLS-Go 端口: $current_port"
            
            # 输入新端口
            read -p "请输入新的监听端口: " new_port
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                red "无效的端口号！请输入 1-65535 之间的数字。"
                sleep 2
                return
            fi
            
            # 检查端口是否被占用
            if lsof -i :$new_port >/dev/null 2>&1 || netstat -an | grep -q ":$new_port "; then
                red "端口 $new_port 已被占用，请选择其他端口！"
                sleep 2
                return
            fi
            
            # 修改服务配置
            case "$OS_TYPE" in
                "alpine")
                    sed -i "s/-l :$current_port/-l :$new_port/" /etc/init.d/$SERVICE_NAME
                    ;;
                "ubuntu"|"debian"|"centos")
                    sed -i "s/-l :$current_port/-l :$new_port/" /etc/systemd/system/${SERVICE_NAME}.service
                    systemctl daemon-reload
                    ;;
            esac
            
            # 重启服务
            restart_anytls_go
            green "AnyTLS-Go 端口已成功修改为: $new_port"
            ;;

        *)
            red "无效选择！"
            ;;
    esac
    sleep 2
}

# ============================== 主菜单 ==============================
show_menu() {
    clear
    echo -e "${CYAN}=============================================="
    echo " 代理协议安装管理脚本"
    echo " 支持系统: Alpine/Ubuntu/Debian/CentOS"
    echo "=============================================="
    echo -e "${NC} 安装与更新"
    echo "=============================================="
    echo -e "${YELLOW}1. 安装 Xray (VMess/Trojan/VLESS/Shadowsocks)${NC}"
    echo -e "${YELLOW}2. 安装 Hysteria 2 (UDP协议加速)${NC}"
    echo -e "${YELLOW}3. 安装 AnyTLS-Go (TLS代理协议)${NC}"
    echo "=============================================="
    echo " 卸载服务"
    echo "=============================================="
    echo -e "${YELLOW}4. 卸载 Xray${NC}"
    echo -e "${YELLOW}5. 卸载 Hysteria 2${NC}"
    echo -e "${YELLOW}6. 卸载 AnyTLS-Go${NC}"
    echo "=============================================="
    echo " 配置管理"
    echo "=============================================="
    echo -e "${YELLOW}7. 查看 Xray 客户端链接${NC}"
    echo -e "${YELLOW}8. 查看 Hysteria 2 客户端链接${NC}"
    echo -e "${YELLOW}9. 查看 AnyTLS-Go 客户端链接${NC}"
    echo -e "${YELLOW}10. 修改服务端口${NC}"
    echo "=============================================="
    echo " 服务控制"
    echo "=============================================="
    echo -e "${YELLOW}11. 启动 Xray${NC}"
    echo -e "${YELLOW}12. 停止 Xray${NC}"
    echo -e "${YELLOW}13. 重启 Xray${NC}"
    echo -e "${YELLOW}14. 启动 Hysteria 2${NC}"
    echo -e "${YELLOW}15. 停止 Hysteria 2${NC}"
    echo -e "${YELLOW}16. 重启 Hysteria 2${NC}"
    echo -e "${YELLOW}17. 启动 AnyTLS-Go${NC}"
    echo -e "${YELLOW}18. 停止 AnyTLS-Go${NC}"
    echo -e "${YELLOW}19. 重启 AnyTLS-Go${NC}"
    echo "=============================================="
    echo " 退出"
    echo "=============================================="
    echo -e "${YELLOW}0. 退出${NC}"
    echo -e "${CYAN}=============================================="
    echo -e "${NC}"

    # 检查服务状态
    echo -e "${CYAN}当前服务状态:${NC}"
    
    # Xray 状态
    if [ -f "${XRAY_BIN}" ]; then
        case "$OS_TYPE" in
            "alpine")
                if rc-service xray status | grep -q "started"; then
                    echo -e " Xray: ${GREEN}已安装并运行中${NC}"
                else
                    echo -e " Xray: ${YELLOW}已安装但未运行${NC}"
                fi
                ;;
            "debian"|"ubuntu"|"centos")
                if systemctl is-active --quiet xray; then
                    echo -e " Xray: ${GREEN}已安装并运行中${NC}"
                else
                    echo -e " Xray: ${YELLOW}已安装但未运行${NC}"
                fi
                ;;
        esac
    else
        echo -e " Xray: ${RED}未安装${NC}"
    fi

    # Hysteria2 状态
    if [ -f "/usr/local/bin/hysteria" ]; then
        case "$OS_TYPE" in
            "alpine")
                if rc-service hysteria status | grep -q "started"; then
                    echo -e " Hysteria2: ${GREEN}已安装并运行中${NC}"
                else
                    echo -e " Hysteria2: ${YELLOW}已安装但未运行${NC}"
                fi
                ;;
            "ubuntu"|"debian"|"centos")
                if systemctl is-active --quiet hysteria; then
                    echo -e " Hysteria2: ${GREEN}已安装并运行中${NC}"
                else
                    echo -e " Hysteria2: ${YELLOW}已安装但未运行${NC}"
                fi
                ;;
        esac
    else
        echo -e " Hysteria2: ${RED}未安装${NC}"
    fi
    
    # AnyTLS-Go 状态
    if [ -f "/usr/local/bin/anytls-server" ]; then
        case "$OS_TYPE" in
            "alpine")
                if rc-service anytls-server status | grep -q "started"; then
                    echo -e " AnyTLS-Go: ${GREEN}已安装并运行中${NC}"
                else
                    echo -e " AnyTLS-Go: ${YELLOW}已安装但未运行${NC}"
                fi
                ;;
            "ubuntu"|"debian"|"centos")
                if systemctl is-active --quiet anytls-server; then
                    echo -e " AnyTLS-Go: ${GREEN}已安装并运行中${NC}"
                else
                    echo -e " AnyTLS-Go: ${YELLOW}已安装但未运行${NC}"
                fi
                ;;
        esac
    else
        echo -e " AnyTLS-Go: ${RED}未安装${NC}"
    fi
    
    echo -e "${CYAN}=============================================="
    echo -e "${NC}"

    read -p "请选择操作 [0-19]: " choice
    case $choice in
        1) install_xray ; show_menu ;;
        2) install_hysteria2 ; show_menu ;;
        3) install_anytls_go ; show_menu ;;
        4) uninstall_xray ; show_menu ;;
        5) uninstall_hysteria2 ; show_menu ;;
        6) uninstall_anytls_go ; show_menu ;;
        7) show_xray_links ; show_menu ;;
        8) show_hysteria_links ; show_menu ;;
        9) show_anytls_links ; show_menu ;;
        10) change_port ; show_menu ;;
        11) start_xray ; show_menu ;;
        12) stop_xray ; show_menu ;;
        13) restart_xray ; show_menu ;;
        14) start_hysteria2 ; show_menu ;;
        15) stop_hysteria2 ; show_menu ;;
        16) restart_hysteria2 ; show_menu ;;
        17) start_anytls_go ; show_menu ;;
        18) stop_anytls_go ; show_menu ;;
        19) restart_anytls_go ; show_menu ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选择，请重新输入${NC}"; sleep 1; show_menu ;;
    esac
}

# 启动主菜单
show_menu
