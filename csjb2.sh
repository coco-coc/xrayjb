#!/bin/bash

################################################################################
# 代理协议安装管理脚本 v2.0.0 (完整改进版)
# 支持系统: Alpine/Ubuntu/Debian/CentOS
# 功能: Xray/Hysteria2/AnyTLS-Go 一键安装、管理、卸载
# 改进: 安全性、错误处理、日志管理、配置备份
################################################################################

set -euo pipefail

# ============================================================================
# 全局配置
# ============================================================================

# 脚本版本和元信息
readonly SCRIPT_VERSION="2.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 系统配置
readonly SUPPORTED_OS=("alpine" "ubuntu" "debian" "centos")
OS_TYPE=""

# 目录配置
readonly XRAY_DIR="/root/Xray"
readonly XRAY_BIN="${XRAY_DIR}/xray"
readonly XRAY_CONFIG="${XRAY_DIR}/config.json"
readonly XRAY_CERT="${XRAY_DIR}/domain.crt"
readonly XRAY_KEY="${XRAY_DIR}/domain.key"
readonly XRAY_PRIV_KEY_FILE="${XRAY_DIR}/private.key"
readonly XRAY_PUB_KEY_FILE="${XRAY_DIR}/public.key"
readonly XRAY_SERVICE_SYSTEMD="/etc/systemd/system/xray.service"
readonly XRAY_SERVICE_OPENRC="/etc/init.d/xray"

readonly HYSTERIA_BIN="/usr/local/bin/hysteria"
readonly HYSTERIA_CONFIG="/etc/hysteria/config.yaml"
readonly HYSTERIA_CERT_DIR="/etc/hysteria/certs"
readonly HYSTERIA_SERVICE_SYSTEMD="/etc/systemd/system/hysteria.service"
readonly HYSTERIA_SERVICE_OPENRC="/etc/init.d/hysteria"

readonly ANYTLS_BIN="/usr/local/bin/anytls-server"
readonly ANYTLS_SERVICE_SYSTEMD="/etc/systemd/system/anytls-server.service"
readonly ANYTLS_SERVICE_OPENRC="/etc/init.d/anytls-server"

readonly LOG_DIR="/var/log"
readonly BACKUP_DIR="/root/backups"
readonly TEMP_DIR="/tmp/proxy-installer-$$"

# 日志文件
readonly LOG_FILE="${LOG_DIR}/proxy-installer.log"

# 颜色定义
readonly RED="\033[31m"
readonly GREEN="\033[32m"
readonly YELLOW="\033[33m"
readonly BLUE="\033[34m"
readonly CYAN="\033[36m"
readonly NC="\033[0m"

# 全局变量 (用于保存用户输入)
XRAY_PROTOCOL=""
XRAY_PORT=""
XRAY_DOMAIN=""
XRAY_WS_PATH=""
XRAY_SS_METHOD=""
VLESS_TYPE=""
VLESS_DEST_SERVER=""
VLESS_PRIVATE_KEY=""
VLESS_PUBLIC_KEY=""
VLESS_SHORT_ID=""
TROJAN_PASSWORD=""
UUID=""
CERT_PATH=""
KEY_PATH=""

# ============================================================================
# 错误处理和日志
# ============================================================================

trap 'error_handler $? $LINENO' ERR
trap 'cleanup_temp' EXIT

error_handler() {
    local exit_code=$1
    local line_number=$2
    log_error "脚本执行失败 (第 $line_number 行, 退出码: $exit_code)"
    cleanup_temp
    exit "$exit_code"
}

cleanup_temp() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# 日志函数
log_info() {
    local message="$*"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $message" | tee -a "$LOG_FILE"
}

log_warn() {
    local message="$*"
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $message${NC}" | tee -a "$LOG_FILE"
}

log_error() {
    local message="$*"
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $message${NC}" | tee -a "$LOG_FILE" >&2
}

log_success() {
    local message="$*"
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] [SUCCESS] $message${NC}" | tee -a "$LOG_FILE"
}

# 颜色输出函数
red() { echo -e "${RED}$*${NC}"; }
green() { echo -e "${GREEN}$*${NC}"; }
yellow() { echo -e "${YELLOW}$*${NC}"; }
blue() { echo -e "${BLUE}$*${NC}"; }
cyan() { echo -e "${CYAN}$*${NC}"; }

# ============================================================================
# 系统检测
# ============================================================================

detect_os() {
    if [ -f /etc/alpine-release ]; then
        echo "alpine"
    elif grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
        echo "ubuntu"
    elif grep -q "Debian" /etc/os-release 2>/dev/null; then
        echo "debian"
    elif grep -q -E "CentOS|Red Hat|AlmaLinux" /etc/os-release 2>/dev/null; then
        echo "centos"
    else
        echo "unknown"
    fi
}

init_system() {
    OS_TYPE=$(detect_os)
    
    if [ "$OS_TYPE" == "unknown" ]; then
        log_error "不支持的系统类型"
        exit 1
    fi
    
    log_info "检测到系统类型: $OS_TYPE"
    
    # 创建必要的目录
    mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$TEMP_DIR"
    
    # 初始化日志文件
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
}

# ============================================================================
# 依赖管理
# ============================================================================

install_deps() {
    local deps_list=()
    
    case "$OS_TYPE" in
        "alpine")
            apk update || log_error "apk update 失败"
            deps_list=("curl" "wget" "unzip" "nc-openbsd" "openssl" "jq" "openrc")
            
            for pkg in "${deps_list[@]}"; do
                if ! apk info -e "$pkg" &>/dev/null; then
                    log_info "安装 $pkg..."
                    apk add --no-cache "$pkg" || log_error "安装 $pkg 失败"
                else
                    log_info "$pkg 已安装"
                fi
            done
            ;;
            
        "ubuntu"|"debian")
            apt-get update || log_error "apt update 失败"
            deps_list=("curl" "wget" "unzip" "netcat-openbsd" "openssl" "jq" "dnsutils")
            
            for pkg in "${deps_list[@]}"; do
                if ! dpkg -s "$pkg" &>/dev/null 2>&1; then
                    log_info "安装 $pkg..."
                    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" || log_error "安装 $pkg 失败"
                else
                    log_info "$pkg 已安装"
                fi
            done
            ;;
            
        "centos")
            # CentOS 7 镜像源修复
            if grep -q "CentOS Linux 7" /etc/os-release 2>/dev/null; then
                log_info "修复 CentOS 7 镜像源..."
                sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-* 2>/dev/null || true
                sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-* 2>/dev/null || true
                yum clean all
            fi
            
            # 安装 EPEL 仓库
            if ! rpm -q epel-release >/dev/null 2>&1; then
                log_info "安装 EPEL 仓库..."
                yum install -y epel-release || log_error "安装 EPEL 失败"
            fi
            
            deps_list=("curl" "wget" "unzip" "nc" "openssl" "jq")
            
            for pkg in "${deps_list[@]}"; do
                if ! rpm -q "$pkg" >/dev/null 2>&1; then
                    log_info "安装 $pkg..."
                    yum install -y "$pkg" || log_error "安装 $pkg 失败"
                else
                    log_info "$pkg 已安装"
                fi
            done
            ;;
    esac
    
    log_success "依赖安装完成"
}

ensure_jq() {
    if ! command -v jq &>/dev/null; then
        yellow "此功能需要 jq，正在为您安装..."
        case "$OS_TYPE" in
            "alpine")
                apk add --no-cache jq
                ;;
            "ubuntu"|"debian")
                apt-get update
                apt-get install -y jq
                ;;
            "centos")
                if grep -q "CentOS Linux 7" /etc/os-release 2>/dev/null; then
                    sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
                    sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
                    yum clean all
                fi
                if ! rpm -q epel-release >/dev/null 2>&1; then
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
    
    if ! command -v jq &>/dev/null; then
        red "jq 安装失败，请手动安装后重试！"
        exit 1
    fi
}

verify_dependencies() {
    local missing_deps=()
    local required_cmds=("curl" "wget" "unzip" "openssl" "jq")
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "缺少依赖: ${missing_deps[*]}"
        return 1
    fi
    
    return 0
}

# ============================================================================
# 网络工具函数
# ============================================================================

get_public_ip() {
    # 尝试获取IPv6地址
    local ipv6_ip=$(curl -s -m 5 -6 icanhazip.com 2>/dev/null || curl -s -m 5 -6 ifconfig.me 2>/dev/null || true)
    if [ -n "$ipv6_ip" ] && [[ "$ipv6_ip" == *":"* ]]; then
        echo "[$ipv6_ip]"
        return
    fi
    
    # 尝试获取IPv4地址
    local ipv4_ip=$(curl -s -m 5 -4 icanhazip.com 2>/dev/null || curl -s -m 5 -4 ifconfig.me 2>/dev/null || curl -s -m 5 -4 api.ipify.org 2>/dev/null || true)
    if [ -n "$ipv4_ip" ] && [[ "$ipv4_ip" != *":"* ]]; then
        echo "$ipv4_ip"
        return
    fi
    
    # 如果都获取失败，返回本地IP
    hostname -I | awk '{print $1}'
}

# ============================================================================
# 端口管理
# ============================================================================

check_port_available() {
    local port=$1
    
    # 方法1: lsof
    if command -v lsof &>/dev/null && lsof -i ":$port" >/dev/null 2>&1; then
        return 1
    fi
    
    # 方法2: netstat
    if command -v netstat &>/dev/null && netstat -tuln 2>/dev/null | grep -q ":$port "; then
        return 1
    fi
    
    # 方法3: ss
    if command -v ss &>/dev/null && ss -tuln 2>/dev/null | grep -q ":$port "; then
        return 1
    fi
    
    # 方法4: nc (netcat)
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then
        return 1
    fi
    
    return 0
}

get_available_port() {
    local start_port=${1:-20000}
    local end_port=${2:-50000}
    local port
    
    for ((port = start_port; port <= end_port; port++)); do
        if check_port_available "$port"; then
            echo "$port"
            return 0
        fi
    done
    
    log_error "无法找到可用端口"
    return 1
}

# ============================================================================
# 备份和恢复
# ============================================================================

backup_config() {
    local config_file=$1
    local service_name=${2:-"service"}
    
    if [ ! -f "$config_file" ]; then
        return 0
    fi
    
    local backup_file="${BACKUP_DIR}/${service_name}_$(basename "$config_file").backup.$(date +%Y%m%d_%H%M%S)"
    
    if cp "$config_file" "$backup_file"; then
        chmod 600 "$backup_file"
        log_info "配置已备份至: $backup_file"
        return 0
    else
        log_error "备份配置失败"
        return 1
    fi
}

restore_config() {
    local backup_file=$1
    local target_file=$2
    
    if [ ! -f "$backup_file" ]; then
        log_error "备份文件不存在: $backup_file"
        return 1
    fi
    
    if cp "$backup_file" "$target_file"; then
        log_success "配置已恢复"
        return 0
    else
        log_error "恢复配置失败"
        return 1
    fi
}

# ============================================================================
# 证书管理
# ============================================================================

verify_cert_key_pair() {
    local cert_file=$1
    local key_file=$2
    
    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
        log_error "证书或私钥文件不存在"
        return 1
    fi
    
    # 验证证书格式
    if ! openssl x509 -in "$cert_file" -noout >/dev/null 2>&1; then
        log_error "证书文件格式无效"
        return 1
    fi
    
    # 验证私钥格式
    if ! openssl rsa -in "$key_file" -noout >/dev/null 2>&1; then
        log_error "私钥文件格式无效"
        return 1
    fi
    
    # 验证配对
    local cert_md5
    local key_md5
    
    cert_md5=$(openssl x509 -noout -modulus -in "$cert_file" 2>/dev/null | openssl md5 | awk '{print $2}')
    key_md5=$(openssl rsa -noout -modulus -in "$key_file" 2>/dev/null | openssl md5 | awk '{print $2}')
    
    if [ "$cert_md5" != "$key_md5" ]; then
        log_error "证书与私钥不匹配"
        return 1
    fi
    
    log_success "证书验证通过"
    return 0
}

setup_certificates() {
    mkdir -p "$XRAY_DIR"
    chmod 700 "$XRAY_DIR"
    
    while true; do
        yellow "请选择证书配置方式:"
        echo "1. 上传已有证书文件"
        echo "2. 输入证书内容"
        echo "3. 生成自签名证书"
        read -p "请选择 [1-3, 默认1]: " cert_choice
        cert_choice=${cert_choice:-1}
        
        case $cert_choice in
            1)
                # 上传证书文件
                while true; do
                    read -p "请输入 .crt 证书文件绝对路径: " cert_path
                    if [ ! -f "$cert_path" ]; then
                        log_error "文件不存在: $cert_path"
                        continue
                    fi
                    
                    read -p "请输入 .key 私钥文件绝对路径: " key_path
                    if [ ! -f "$key_path" ]; then
                        log_error "文件不存在: $key_path"
                        continue
                    fi
                    
                    if verify_cert_key_pair "$cert_path" "$key_path"; then
                        cp "$cert_path" "$XRAY_CERT"
                        cp "$key_path" "$XRAY_KEY"
                        chmod 600 "$XRAY_KEY" "$XRAY_CERT"
                        CERT_PATH="$XRAY_CERT"
                        KEY_PATH="$XRAY_KEY"
                        return 0
                    fi
                done
                ;;
                
            2)
                # 输入证书内容
                log_info "请输入证书内容 (输入 EOF 结束):"
                cat > "$XRAY_CERT" << 'EOF'
EOF
                
                log_info "请输入私钥内容 (输入 EOF 结束):"
                cat > "$XRAY_KEY" << 'EOF'
EOF
                
                chmod 600 "$XRAY_KEY" "$XRAY_CERT"
                
                if verify_cert_key_pair "$XRAY_CERT" "$XRAY_KEY"; then
                    CERT_PATH="$XRAY_CERT"
                    KEY_PATH="$XRAY_KEY"
                    return 0
                fi
                ;;
                
            3)
                # 生成自签名证书
                read -p "请输入伪装域名 (默认: www.example.com): " domain_name
                domain_name=${domain_name:-"www.example.com"}
                
                log_info "正在生成自签名证书..."
                if openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
                    -keyout "$XRAY_KEY" -out "$XRAY_CERT" \
                    -subj "/CN=$domain_name" -days 36500 2>/dev/null; then
                    
                    chmod 600 "$XRAY_KEY" "$XRAY_CERT"
                    log_success "自签名证书已生成"
                    CERT_PATH="$XRAY_CERT"
                    KEY_PATH="$XRAY_KEY"
                    return 0
                else
                    log_error "证书生成失败"
                    return 1
                fi
                ;;
                
            *)
                log_error "无效选择"
                ;;
        esac
    done
}

# ============================================================================
# 配置验证
# ============================================================================

validate_json_config() {
    local config_file=$1
    
    if ! jq empty "$config_file" 2>/dev/null; then
        log_error "配置文件 JSON 格式错误"
        return 1
    fi
    
    # 检查必需字段
    if ! jq -e '.inbounds[0].port' "$config_file" >/dev/null 2>&1; then
        log_error "缺少必需的 inbounds.port 字段"
        return 1
    fi
    
    if ! jq -e '.inbounds[0].protocol' "$config_file" >/dev/null 2>&1; then
        log_error "缺少必需的 inbounds.protocol 字段"
        return 1
    fi
    
    log_success "配置验证通过"
    return 0
}

# ============================================================================
# 服务管理
# ============================================================================

is_service_running() {
    local service=$1
    
    case "$OS_TYPE" in
        "alpine")
            rc-service "$service" status 2>/dev/null | grep -q "started" || return 1
            ;;
        *)
            systemctl is-active --quiet "$service" 2>/dev/null || return 1
            ;;
    esac
}

wait_for_service() {
    local service=$1
    local max_wait=${2:-30}
    local elapsed=0
    
    while [ $elapsed -lt "$max_wait" ]; do
        if is_service_running "$service"; then
            log_success "$service 已启动"
            return 0
        fi
        sleep 1
        ((elapsed++))
    done
    
    log_error "$service 启动超时"
    return 1
}

start_service() {
    local service=$1
    
    case "$OS_TYPE" in
        "alpine")
            service "$service" start || log_error "启动 $service 失败"
            ;;
        *)
            systemctl start "$service" || log_error "启动 $service 失败"
            ;;
    esac
    
    wait_for_service "$service"
}

stop_service() {
    local service=$1
    
    case "$OS_TYPE" in
        "alpine")
            service "$service" stop || log_error "停止 $service 失败"
            ;;
        *)
            systemctl stop "$service" || log_error "停止 $service 失败"
            ;;
    esac
}

restart_service() {
    local service=$1
    
    case "$OS_TYPE" in
        "alpine")
            service "$service" restart || log_error "重启 $service 失败"
            ;;
        *)
            systemctl restart "$service" || log_error "重启 $service 失败"
            ;;
    esac
    
    wait_for_service "$service"
}

# ============================================================================
# 日志轮转配置
# ============================================================================

setup_logrotate() {
    local service=$1
    local log_pattern=$2
    
    cat > "/etc/logrotate.d/$service" << EOF
$log_pattern {
    daily
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        case "$OS_TYPE" in
            "alpine")
                rc-service $service reload > /dev/null 2>&1 || true
                ;;
            *)
                systemctl reload $service > /dev/null 2>&1 || true
                ;;
        esac
    endscript
}
EOF
    
    log_info "日志轮转配置已创建: /etc/logrotate.d/$service"
}

# ============================================================================
# 下载和安装
# ============================================================================

download_with_retry() {
    local url=$1
    local output=$2
    local max_retry=${3:-3}
    local retry=0
    
    while [ $retry -lt "$max_retry" ]; do
        log_info "下载: $url (尝试 $((retry + 1))/$max_retry)"
        
        if wget -q -O "$output" "$url" 2>/dev/null; then
            if [ -s "$output" ]; then
                log_success "下载成功"
                return 0
            fi
        fi
        
        ((retry++))
        if [ $retry -lt "$max_retry" ]; then
            log_warn "下载失败，5秒后重试..."
            sleep 5
        fi
    done
    
    log_error "下载失败: $url"
    return 1
}

verify_file_integrity() {
    local file=$1
    local file_type=${2:-"zip"}
    
    case $file_type in
        "zip")
            if unzip -t "$file" >/dev/null 2>&1; then
                log_success "文件完整性验证通过"
                return 0
            fi
            ;;
        "tar.gz")
            if tar -tzf "$file" >/dev/null 2>&1; then
                log_success "文件完整性验证通过"
                return 0
            fi
            ;;
    esac
    
    log_error "文件损坏或格式无效"
    return 1
}

# ============================================================================
# Xray 安装和管理
# ============================================================================

install_xray_binary() {
    local arch=$(uname -m)
    
    case $arch in
        x86_64) arch="64" ;;
        aarch64) arch="arm64-v8a" ;;
        armv7l) arch="arm32-v7a" ;;
        *)
            log_error "不支持的系统架构: $arch"
            return 1
            ;;
    esac
    
    mkdir -p "$XRAY_DIR"
    chmod 700 "$XRAY_DIR"
    
    local download_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
    local temp_file="$TEMP_DIR/xray-latest.zip"
    
    log_info "正在下载 Xray ($arch)..."
    if ! download_with_retry "$download_url" "$temp_file"; then
        return 1
    fi
    
    if ! verify_file_integrity "$temp_file" "zip"; then
        return 1
    fi
    
    log_info "正在解压 Xray..."
    if ! unzip -o -d "$XRAY_DIR" "$temp_file" >/dev/null 2>&1; then
        log_error "解压失败"
        return 1
    fi
    
    if [ ! -f "$XRAY_BIN" ]; then
        log_error "解压后未找到 xray 可执行文件"
        return 1
    fi
    
    chmod +x "$XRAY_BIN"
    log_success "Xray 安装成功"
    return 0
}

generate_xray_config() {
    local protocol=$1
    local port=$2
    
    backup_config "$XRAY_CONFIG" "xray"
    
    case "$protocol" in
        "vmess")
            generate_xray_vmess_config "$port"
            ;;
        "trojan")
            generate_xray_trojan_config "$port"
            ;;
        "vless")
            generate_xray_vless_config "$port"
            ;;
        "shadowsocks")
            generate_xray_shadowsocks_config "$port"
            ;;
        *)
            log_error "未知协议: $protocol"
            return 1
            ;;
    esac
    
    if validate_json_config "$XRAY_CONFIG"; then
        log_success "Xray 配置生成成功"
        return 0
    else
        log_error "配置验证失败"
        return 1
    fi
}

generate_xray_vmess_config() {
    local port=$1
    UUID=$(cat /proc/sys/kernel/random/uuid)
    local domain=${XRAY_DOMAIN:-"example.com"}
    local ws_path=${XRAY_WS_PATH:-"/"}
    
    cat > "$XRAY_CONFIG" << EOF
{
    "log": {
        "loglevel": "warning",
        "access": "${LOG_DIR}/xray-access.log",
        "error": "${LOG_DIR}/xray-error.log"
    },
    "inbounds": [{
        "listen": "::",
        "port": $port,
        "protocol": "vmess",
        "settings": {
            "clients": [{
                "id": "$UUID",
                "alterId": 0,
                "security": "auto"
            }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "ws",
            "security": "tls",
            "wsSettings": {
                "path": "$ws_path",
                "headers": {
                    "Host": "$domain"
                }
            },
            "tlsSettings": {
                "certificates": [{
                    "certificateFile": "$CERT_PATH",
                    "keyFile": "$KEY_PATH"
                }],
                "serverName": "$domain"
            }
        }
    }],
    "outbounds": [{
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIP"
        }
    }]
}
EOF
    
    green "VMess UUID: $UUID"
}

generate_xray_trojan_config() {
    local port=$1
    TROJAN_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-16)
    local domain=${XRAY_DOMAIN:-"example.com"}
    local ws_path=${XRAY_WS_PATH:-"/"}
    
    # 保存密码供后续使用
    echo "$TROJAN_PASSWORD" > "$XRAY_DIR/.trojan_password"
    chmod 600 "$XRAY_DIR/.trojan_password"
    
    cat > "$XRAY_CONFIG" << EOF
{
    "log": {
        "loglevel": "warning",
        "access": "${LOG_DIR}/xray-access.log",
        "error": "${LOG_DIR}/xray-error.log"
    },
    "inbounds": [{
        "listen": "::",
        "port": $port,
        "protocol": "trojan",
        "settings": {
            "clients": [{
                "password": "$TROJAN_PASSWORD"
            }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "ws",
            "security": "tls",
            "wsSettings": {
                "path": "$ws_path",
                "headers": {
                    "Host": "$domain"
                }
            },
            "tlsSettings": {
                "certificates": [{
                    "certificateFile": "$CERT_PATH",
                    "keyFile": "$KEY_PATH"
                }],
                "serverName": "$domain"
            }
        }
    }],
    "outbounds": [{
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIP"
        }
    }]
}
EOF
    
    green "Trojan 密码: $TROJAN_PASSWORD"
}

generate_xray_vless_config() {
    local port=$1
    UUID=$(cat /proc/sys/kernel/random/uuid)
    
    if [ "$VLESS_TYPE" == "Reality" ]; then
        # Reality 模式
        cat > "$XRAY_CONFIG" << EOF
{
    "log": {
        "loglevel": "warning",
        "access": "${LOG_DIR}/xray-access.log",
        "error": "${LOG_DIR}/xray-error.log"
    },
    "inbounds": [{
        "listen": "::",
        "port": $port,
        "protocol": "vless",
        "settings": {
            "clients": [{
                "id": "$UUID",
                "flow": "xtls-rprx-vision"
            }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "show": true,
                "dest": "$VLESS_DEST_SERVER:443",
                "xver": 0,
                "serverNames": [
                    "$VLESS_DEST_SERVER"
                ],
                "privateKey": "$VLESS_PRIVATE_KEY",
                "minClientVer": "",
                "maxClientVer": "",
                "maxTimeDiff": 0,
                "shortIds": [
                    "$VLESS_SHORT_ID"
                ]
            },
            "packetEncoding": "xudp"
        }
    }],
    "outbounds": [
        {
            "protocol": "freedom",
            "settings": {
                "domainStrategy": "UseIP"
            },
            "streamSettings": {
                "packetEncoding": "xudp"
            }
        }
    ]
}
EOF
        
        green "VLESS UUID: $UUID"
        green "Reality Private Key: $VLESS_PRIVATE_KEY"
        green "Reality Public Key: $VLESS_PUBLIC_KEY"
        green "Reality Short ID: $VLESS_SHORT_ID"
    else
        # WebSocket + TLS 模式
        local domain=${XRAY_DOMAIN:-"example.com"}
        local ws_path=${XRAY_WS_PATH:-"/"}
        
        cat > "$XRAY_CONFIG" << EOF
{
    "log": {
        "loglevel": "warning",
        "access": "${LOG_DIR}/xray-access.log",
        "error": "${LOG_DIR}/xray-error.log"
    },
    "inbounds": [{
        "listen": "::",
        "port": $port,
        "protocol": "vless",
        "settings": {
            "clients": [{
                "id": "$UUID",
                "flow": ""
            }],
            "decryption": "none"
        },
        "streamSettings": {
            "network": "ws",
            "security": "tls",
            "wsSettings": {
                "path": "$ws_path",
                "headers": {
                    "Host": "$domain"
                }
            },
            "tlsSettings": {
                "certificates": [{
                    "certificateFile": "$CERT_PATH",
                    "keyFile": "$KEY_PATH"
                }],
                "serverName": "$domain"
            }
        }
    }],
    "outbounds": [{
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIP"
        }
    }]
}
EOF
        
        green "VLESS UUID: $UUID"
    fi
}

generate_xray_shadowsocks_config() {
    local port=$1
    local password=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-16)
    local method=${XRAY_SS_METHOD:-"aes-256-gcm"}
    
    # 保存密码供后续使用
    echo "$password" > "$XRAY_DIR/.ss_password"
    chmod 600 "$XRAY_DIR/.ss_password"
    
    cat > "$XRAY_CONFIG" << EOF
{
    "log": {
        "loglevel": "warning",
        "access": "${LOG_DIR}/xray-access.log",
        "error": "${LOG_DIR}/xray-error.log"
    },
    "inbounds": [{
        "listen": "::",
        "port": $port,
        "protocol": "shadowsocks",
        "settings": {
            "method": "$method",
            "password": "$password",
            "network": "tcp,udp"
        }
    }],
    "outbounds": [{
        "protocol": "freedom",
        "settings": {
            "domainStrategy": "UseIP"
        }
    }]
}
EOF
    
    green "Shadowsocks 密码: $password"
    green "加密方式: $method"
}

setup_xray_service() {
    case "$OS_TYPE" in
        "alpine")
            cat > "$XRAY_SERVICE_OPENRC" << 'EOF'
#!/sbin/openrc-run
name="xray"
description="Xray Service"
command="/root/Xray/xray"
command_args="-config /root/Xray/config.json"
pidfile="/run/xray.pid"
respawn_delay=5
rc_ulimit="-n 30000"
output_log="/var/log/xray.log"
error_log="/var/log/xray.error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -f "$output_log" -m 0644
    checkpath -f "$error_log" -m 0644
}

start() {
    ebegin "Starting xray service"
    start-stop-daemon --start \
        --exec $command \
        --pidfile $pidfile \
        --background \
        --make-pidfile \
        -- $command_args
    eend $?
}

stop() {
    ebegin "Stopping xray service"
    start-stop-daemon --stop \
        --exec $command \
        --pidfile $pidfile
    eend $?
}
EOF
            chmod +x "$XRAY_SERVICE_OPENRC"
            rc-update add xray default 2>/dev/null || true
            ;;
            
        *)
            cat > "$XRAY_SERVICE_SYSTEMD" << EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
ExecStart=$XRAY_BIN -config $XRAY_CONFIG
Restart=always
RestartSec=10
User=root
LimitNOFILE=30000
StandardOutput=file:${LOG_DIR}/xray-access.log
StandardError=file:${LOG_DIR}/xray-error.log

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable xray 2>/dev/null || true
            ;;
    esac
    
    setup_logrotate "xray" "${LOG_DIR}/xray*.log"
}

install_xray() {
    log_info "开始安装 Xray..."
    
    # 清理旧日志
    rm -f ${LOG_DIR}/xray*.log
    
    # 安装依赖
    install_deps
    verify_dependencies || return 1
    
    # 选择协议
    yellow "\n请选择协议:"
    select protocol in "vmess" "trojan" "vless" "shadowsocks"; do
        XRAY_PROTOCOL=$protocol
        break
    done
    
    # 如果是VLESS协议，选择传输类型
    if [[ "$XRAY_PROTOCOL" == "vless" ]]; then
        yellow "\n请选择VLESS传输类型:"
        select vless_type in "WebSocket+TLS" "Reality"; do
            VLESS_TYPE=$vless_type
            break
        done
    fi
    
    # Reality模式输入伪装域名
    if [[ "$XRAY_PROTOCOL" == "vless" && "$VLESS_TYPE" == "Reality" ]]; then
        read -p "请输入伪装域名[默认: www.microsoft.com]: " dest_server
        [[ -z $dest_server ]] && dest_server="www.microsoft.com"
        VLESS_DEST_SERVER=$dest_server
    fi
    
    # 输入域名和路径（Shadowsocks和Reality不需要）
    if [[ "$XRAY_PROTOCOL" != "shadowsocks" && ! ( "$XRAY_PROTOCOL" == "vless" && "$VLESS_TYPE" == "Reality" ) ]]; then
        read -p "请输入域名（已解析到本机IP）：" XRAY_DOMAIN
        read -p "请输入WebSocket路径（默认/）：" XRAY_WS_PATH
        [[ -z "$XRAY_WS_PATH" ]] && XRAY_WS_PATH="/"
    fi
    
    # 配置证书（Shadowsocks和Reality不需要证书）
    if [[ "$XRAY_PROTOCOL" != "shadowsocks" && ! ( "$XRAY_PROTOCOL" == "vless" && "$VLESS_TYPE" == "Reality" ) ]]; then
        setup_certificates || return 1
    fi
    
    # 生成Reality密钥对
    if [[ "$XRAY_PROTOCOL" == "vless" && "$VLESS_TYPE" == "Reality" ]]; then
        # 检查是否安装了xray
        if [[ ! -f "${XRAY_BIN}" ]]; then
            # 先下载xray以获取密钥生成工具
            log_info "下载 Xray 以生成 Reality 密钥..."
            install_xray_binary || return 1
        fi
        
        # 生成Reality密钥对
        yellow "正在生成Reality密钥对..."
        local key_pair=$("${XRAY_BIN}" x25519 2>&1)
        
        # 优先按 "Private key: xxx" 提取
        VLESS_PRIVATE_KEY=$(echo "${key_pair}" | grep -i 'Private' | awk -F': ' '{print $2}' | tr -d '[:space:]')
        VLESS_PUBLIC_KEY=$(echo "${key_pair}" | grep -i 'Public' | awk -F': ' '{print $2}' | tr -d '[:space:]')
        
        # 若提取失败，备用格式 "Private xxx"
        if [[ -z "$VLESS_PRIVATE_KEY" || -z "$VLESS_PUBLIC_KEY" ]]; then
            VLESS_PRIVATE_KEY=$(echo "${key_pair}" | awk '/Private/{print $2}' | tr -d '[:space:]')
            VLESS_PUBLIC_KEY=$(echo "${key_pair}" | awk '/Public/{print $2}' | tr -d '[:space:]')
        fi
        
        # 最终校验
        if [[ -z "$VLESS_PRIVATE_KEY" || -z "$VLESS_PUBLIC_KEY" ]]; then
            red "Reality 密钥生成失败，请检查 xray 版本是否支持 x25519 命令"
            return 1
        fi
        
        # 生成短ID（统一用 openssl，不依赖 xxd）
        VLESS_SHORT_ID=$(openssl rand -hex 4)
    fi
    
    # 选择加密方式 (Shadowsocks)
    if [ "$XRAY_PROTOCOL" == "shadowsocks" ]; then
        yellow "\n请选择加密方式:"
        select method in "aes-256-gcm" "chacha20-poly1305" "aes-128-gcm"; do
            XRAY_SS_METHOD=$method
            break
        done
    fi
    
    # 获取端口
    read -p "请输入监听端口（默认443）：" XRAY_PORT
    [[ -z "$XRAY_PORT" ]] && XRAY_PORT=443
    
    if ! check_port_available "$XRAY_PORT"; then
        log_error "端口 $XRAY_PORT 已被占用"
        return 1
    fi
    
    if [[ "$XRAY_PORT" != "443" ]] && [[ "$XRAY_PROTOCOL" != "shadowsocks" ]]; then
        yellow "建议使用443端口以提高兼容性"
    fi
    
    # 检查是否已安装 Xray
    if [[ ! -f "${XRAY_BIN}" ]]; then
        install_xray_binary || return 1
    fi
    
    # 生成配置
    generate_xray_config "$XRAY_PROTOCOL" "$XRAY_PORT" || return 1
    
    # 配置服务
    setup_xray_service
    
    # 启动服务
    start_service "xray" || return 1
    
    # 显示链接
    show_xray_links
    
    # 显示日志路径
    yellow "访问日志：/var/log/xray-access.log"
    yellow "错误日志：/var/log/xray-error.log"
    green "Xray 服务配置完成！"
    
    read -p "按回车键返回主菜单..."
}

show_xray_links() {
    ensure_jq
    
    if [ ! -f "${XRAY_CONFIG}" ]; then
        red "未找到 Xray 配置文件，请先安装 Xray！"
        sleep 2
        return
    fi
    
    # 使用 jq 解析配置文件
    local protocol=$(jq -r '.inbounds[0].protocol' "${XRAY_CONFIG}")
    local in_port=$(jq -r '.inbounds[0].port' "${XRAY_CONFIG}")
    
    # 获取公网IP
    local server_ip=$(get_public_ip)
    
    blue "\n=============== Xray 客户端链接 ================"
    
    case "$protocol" in
        "vmess")
            local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "${XRAY_CONFIG}")
            local domain=$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName' "${XRAY_CONFIG}")
            local ws_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "${XRAY_CONFIG}")
            
            if [ "$domain" == "null" ]; then
                domain=$server_ip
            fi
            
            if [ "$ws_path" == "null" ]; then
                ws_path="/"
            fi
            
            local vmess_json=$(cat <<EOF
{
    "v": "2",
    "ps": "Xray_VMess",
    "add": "$domain",
    "port": "$in_port",
    "id": "$uuid",
    "aid": "0",
    "scy": "auto",
    "net": "ws",
    "type": "none",
    "host": "$domain",
    "path": "$ws_path",
    "tls": "tls",
    "sni": "$domain"
}
EOF
            )
            local vmess_link="vmess://$(echo "$vmess_json" | base64 -w 0)"
            green "VMess 链接：\n$vmess_link"
            ;;
            
        "trojan")
            local password=$(cat "$XRAY_DIR/.trojan_password" 2>/dev/null || echo "PASSWORD")
            local domain=$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName' "${XRAY_CONFIG}")
            local ws_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "${XRAY_CONFIG}")
            
            if [ "$ws_path" == "null" ]; then
                ws_path="/"
            fi
            
            if [ -z "$password" ] || [ "$password" == "null" ]; then
                red "无法提取Trojan密码，请检查配置文件"
            else
                local trojan_link="trojan://${password}@${domain}:${in_port}?security=tls&sni=${domain}&type=ws&host=${domain}&path=${ws_path}#Xray_Trojan"
                green "Trojan 链接：\n$trojan_link"
            fi
            ;;
            
        "vless")
            local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "${XRAY_CONFIG}")
            
            # 检查是否是Reality模式
            local security_type=$(jq -r '.inbounds[0].streamSettings.security' "${XRAY_CONFIG}")
            if [ "$security_type" == "reality" ]; then
                # 提取Reality配置
                local dest_server=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "${XRAY_CONFIG}" | cut -d: -f1)
                local public_key=$(jq -r '.inbounds[0].streamSettings.realitySettings.publicKey' "${XRAY_CONFIG}")
                local short_id=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "${XRAY_CONFIG}")
                
                local vless_link="vless://${uuid}@${server_ip}:${in_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${dest_server}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp&headerType=none&packetEncoding=xudp#Vless-Reality"
                green "VLESS (Reality with XUDP) 链接：\n$vless_link"
            else
                local domain=$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName' "${XRAY_CONFIG}")
                local ws_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "${XRAY_CONFIG}")
                
                if [ "$ws_path" == "null" ]; then
                    ws_path="/"
                fi
                
                local vless_link="vless://${uuid}@${domain}:${in_port}?security=tls&sni=${domain}&type=ws&host=${domain}&path=${ws_path}#Xray_VLESS"
                green "VLESS 链接：\n$vless_link"
            fi
            ;;
            
        "shadowsocks")
            local method=$(jq -r '.inbounds[0].settings.method' "${XRAY_CONFIG}")
            local password=$(cat "$XRAY_DIR/.ss_password" 2>/dev/null || echo "PASSWORD")
            
            local ss_link="ss://$(echo -n "${method}:${password}" | base64 -w 0)@${server_ip}:${in_port}#Xray_Shadowsocks"
            green "Shadowsocks 链接：\n$ss_link"
            ;;
            
        *)
            red "未知协议类型: $protocol"
            ;;
    esac
    
    blue "================================================\n"
}

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
            service xray stop >/dev/null 2>&1 || true
            rc-update del xray >/dev/null 2>&1 || true
            rm -f "${XRAY_SERVICE_OPENRC}"
            ;;
        "debian"|"ubuntu"|"centos")
            systemctl stop xray >/dev/null 2>&1 || true
            systemctl disable xray >/dev/null 2>&1 || true
            rm -f "${XRAY_SERVICE_SYSTEMD}"
            systemctl daemon-reload
            ;;
    esac
    
    # 删除文件
    rm -rf "${XRAY_DIR}"
    rm -f ${LOG_DIR}/xray*.log
    rm -f /etc/logrotate.d/xray
    
    echo -e "${GREEN}Xray 已成功卸载！${NC}"
    sleep 2
}

# ============================================================================
# Hysteria2 安装和管理
# ============================================================================

install_hysteria2() {
    echo -e "${YELLOW}Hysteria 2 安装脚本${NC}"
    echo "---------------------------------------"
    
    # 安装依赖
    echo -e "${YELLOW}正在安装必要的软件包...${NC}" >&2
    install_deps
    
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
    local CERT_PATH=""
    local KEY_PATH=""
    local DOMAIN=""
    local SNI=""
    local ACME_EMAIL=""
    
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
    SERVER_PUBLIC_ADDRESS=$(get_public_ip)
    
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
    
    chmod 600 /etc/hysteria/config.yaml
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
            service hysteria stop >/dev/null 2>&1 || true
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
            systemctl stop hysteria >/dev/null 2>&1 || true
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
    blue "=====================================================\n"
    
    read -p "按回车键返回..."
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
            service hysteria stop >/dev/null 2>&1 || true
            rc-update del hysteria >/dev/null 2>&1 || true
            rm -f /etc/init.d/hysteria
            ;;
        "ubuntu"|"debian"|"centos")
            systemctl stop hysteria >/dev/null 2>&1 || true
            systemctl disable hysteria >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/hysteria.service
            systemctl daemon-reload
            ;;
    esac
    
    # 删除文件
    rm -f /usr/local/bin/hysteria
    rm -rf /etc/hysteria
    rm -f /var/log/hysteria*.log
    rm -f /etc/logrotate.d/hysteria
    
    echo -e "${GREEN}Hysteria2 已成功卸载！${NC}"
    sleep 2
}

# ============================================================================
# AnyTLS-Go 安装和管理
# ============================================================================

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
    install_deps
    
    yellow "开始安装 AnyTLS-Go..."
    
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
    blue "====================================================\n"
    
    read -p "按回车键返回..."
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
            service $SERVICE_NAME stop >/dev/null 2>&1 || true
            rc-update del $SERVICE_NAME >/dev/null 2>&1 || true
            rm -f /etc/init.d/$SERVICE_NAME
            ;;
        "ubuntu"|"debian"|"centos")
            systemctl stop $SERVICE_NAME >/dev/null 2>&1 || true
            systemctl disable $SERVICE_NAME >/dev/null 2>&1 || true
            rm -f /etc/systemd/system/${SERVICE_NAME}.service
            systemctl daemon-reload
            ;;
    esac
    
    # 删除文件
    rm -f $BINARY_PATH
    rm -f /var/log/anytls*.log
    rm -f /etc/logrotate.d/anytls-server
    
    echo -e "${GREEN}AnyTLS-Go 已成功卸载！${NC}"
    sleep 2
}

# ============================================================================
# 服务控制
# ============================================================================

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

# ============================================================================
# 修改端口功能
# ============================================================================

change_port() {
    ensure_jq
    
    echo -e "${YELLOW}请选择要修改端口的服务：${NC}"
    echo "1. Xray"
    echo "2. Hysteria2"
    echo "3. AnyTLS-Go"
    read -p "请选择 [1-3]: " service_choice

    case $service_choice in
        1) # Xray
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

# ============================================================================
# 主菜单
# ============================================================================

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

# ============================================================================
# 主程序入口
# ============================================================================

main() {
    # 检查 root 权限
    if [ "$EUID" -ne 0 ]; then
        red "错误: 此脚本需要 root 权限运行"
        exit 1
    fi
    
    # 初始化系统
    init_system
    
    log_info "脚本启动 - 版本 $SCRIPT_VERSION"
    
    # 显示主菜单
    show_menu
}

# 运行主程序
main "$@"
