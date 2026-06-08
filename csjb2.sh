#!/bin/bash

################################################################################
# 代理协议安装管理脚本 v2.0.0 (改进版)
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

# ============================================================================
# 错误处理和日志
# ============================================================================

# 错误处理陷阱
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
    local timeout=3
    local retry=2
    local ip=""
    
    # IPv6 优先
    for i in $(seq 1 "$retry"); do
        ip=$(curl -s -m "$timeout" -6 icanhazip.com 2>/dev/null || true)
        if [ -n "$ip" ] && [[ "$ip" == *":"* ]]; then
            echo "[$ip]"
            return 0
        fi
    done
    
    # IPv4 备选
    for i in $(seq 1 "$retry"); do
        ip=$(curl -s -m "$timeout" -4 icanhazip.com 2>/dev/null || true)
        if [ -n "$ip" ] && [[ "$ip" != *":"* ]]; then
            echo "$ip"
            return 0
        fi
    done
    
    # 本地 IP 最后手段
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
            rc-service "$service" status 2>/dev/null | grep -q "started"
            ;;
        *)
            systemctl is-active --quiet "$service" 2>/dev/null
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
    local uuid=$(cat /proc/sys/kernel/random/uuid)
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
                "id": "$uuid",
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
                    "certificateFile": "$XRAY_CERT",
                    "keyFile": "$XRAY_KEY"
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
}

generate_xray_trojan_config() {
    local port=$1
    local password=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-16)
    local domain=${XRAY_DOMAIN:-"example.com"}
    local ws_path=${XRAY_WS_PATH:-"/"}
    
    # 保存密码供后续使用
    echo "$password" > "$XRAY_DIR/.trojan_password"
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
                "password": "$password"
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
                    "certificateFile": "$XRAY_CERT",
                    "keyFile": "$XRAY_KEY"
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
}

generate_xray_vless_config() {
    local port=$1
    local uuid=$(cat /proc/sys/kernel/random/uuid)
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
                "id": "$uuid",
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
                    "certificateFile": "$XRAY_CERT",
                    "keyFile": "$XRAY_KEY"
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
    
    # 安装依赖
    install_deps
    verify_dependencies || return 1
    
    # 选择协议
    yellow "\n请选择协议:"
    select protocol in "vmess" "trojan" "vless" "shadowsocks"; do
        XRAY_PROTOCOL=$protocol
        break
    done
    
    # 获取域名和路径
    if [ "$XRAY_PROTOCOL" != "shadowsocks" ]; then
        read -p "请输入域名 (已解析到本机IP): " XRAY_DOMAIN
        read -p "请输入 WebSocket 路径 (默认/): " XRAY_WS_PATH
        XRAY_WS_PATH=${XRAY_WS_PATH:-"/"}
        
        # 配置证书
        setup_certificates || return 1
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
    read -p "请输入监听端口 (默认443): " XRAY_PORT
    XRAY_PORT=${XRAY_PORT:-443}
    
    if ! check_port_available "$XRAY_PORT"; then
        log_error "端口 $XRAY_PORT 已被占用"
        return 1
    fi
    
    # 下载 Xray
    if [ ! -f "$XRAY_BIN" ]; then
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
    
    log_success "Xray 安装完成"
}

show_xray_links() {
    local port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
    local protocol=$(jq -r '.inbounds[0].protocol' "$XRAY_CONFIG")
    local server_ip=$(get_public_ip)
    
    blue "\n=============== Xray 客户端链接 ================"
    
    case "$protocol" in
        "vmess")
            local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")
            local domain=$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName' "$XRAY_CONFIG")
            local ws_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$XRAY_CONFIG")
            
            local vmess_json=$(cat <<EOF
{
    "v": "2",
    "ps": "Xray_VMess",
    "add": "$domain",
    "port": "$port",
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
            green "VMess 链接:\n$vmess_link"
            ;;
            
        "trojan")
            local password=$(cat "$XRAY_DIR/.trojan_password" 2>/dev/null || echo "PASSWORD")
            local domain=$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName' "$XRAY_CONFIG")
            local ws_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$XRAY_CONFIG")
            
            local trojan_link="trojan://${password}@${domain}:${port}?security=tls&sni=${domain}&type=ws&host=${domain}&path=${ws_path}#Xray_Trojan"
            green "Trojan 链接:\n$trojan_link"
            ;;
            
        "vless")
            local uuid=$(jq -r '.inbounds[0].settings.clients[0].id' "$XRAY_CONFIG")
            local domain=$(jq -r '.inbounds[0].streamSettings.tlsSettings.serverName' "$XRAY_CONFIG")
            local ws_path=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$XRAY_CONFIG")
            
            local vless_link="vless://${uuid}@${domain}:${port}?security=tls&sni=${domain}&type=ws&host=${domain}&path=${ws_path}#Xray_VLESS"
            green "VLESS 链接:\n$vless_link"
            ;;
            
        "shadowsocks")
            local password=$(cat "$XRAY_DIR/.ss_password" 2>/dev/null || echo "PASSWORD")
            local method=$(jq -r '.inbounds[0].settings.method' "$XRAY_CONFIG")
            
            local ss_link="ss://$(echo -n "${method}:${password}" | base64 -w 0)@${server_ip}:${port}#Xray_Shadowsocks"
            green "Shadowsocks 链接:\n$ss_link"
            ;;
    esac
    
    blue "================================================\n"
}

uninstall_xray() {
    if [ ! -f "$XRAY_BIN" ]; then
        log_warn "Xray 未安装"
        return 0
    fi
    
    log_info "开始卸载 Xray..."
    
    stop_service "xray" || true
    
    case "$OS_TYPE" in
        "alpine")
            rc-update del xray 2>/dev/null || true
            rm -f "$XRAY_SERVICE_OPENRC"
            ;;
        *)
            systemctl disable xray 2>/dev/null || true
            rm -f "$XRAY_SERVICE_SYSTEMD"
            systemctl daemon-reload
            ;;
    esac
    
    rm -rf "$XRAY_DIR"
    rm -f "${LOG_DIR}/xray"*.log
    rm -f /etc/logrotate.d/xray
    
    log_success "Xray 已卸载"
}

# ============================================================================
# Hysteria2 安装和管理
# ============================================================================

install_hysteria2() {
    log_info "开始安装 Hysteria2..."
    
    # 安装依赖
    install_deps
    verify_dependencies || return 1
    
    # 选择 TLS 验证方式
    yellow "\n请选择 TLS 验证方式:"
    echo "1. 自定义证书"
    echo "2. ACME HTTP 验证"
    read -p "请选择 [1-2, 默认1]: " tls_type
    tls_type=${tls_type:-1}
    
    local hysteria_domain=""
    local hysteria_acme_email=""
    
    case $tls_type in
        1)
            # 自定义证书
            read -p "请输入证书路径 (留空则生成自签名): " cert_path
            
            if [ -z "$cert_path" ]; then
                read -p "请输入伪装域名 (默认www.example.com): " hysteria_domain
                hysteria_domain=${hysteria_domain:-"www.example.com"}
                
                mkdir -p "$HYSTERIA_CERT_DIR"
                chmod 700 "$HYSTERIA_CERT_DIR"
                
                log_info "生成自签名证书..."
                openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
                    -keyout "$HYSTERIA_CERT_DIR/server.key" \
                    -out "$HYSTERIA_CERT_DIR/server.crt" \
                    -subj "/CN=$hysteria_domain" -days 36500 || return 1
                
                chmod 600 "$HYSTERIA_CERT_DIR/server.key"
                chmod 644 "$HYSTERIA_CERT_DIR/server.crt"
            else
                if [ ! -f "$cert_path" ]; then
                    log_error "证书文件不存在"
                    return 1
                fi
                
                read -p "请输入私钥路径: " key_path
                if [ ! -f "$key_path" ]; then
                    log_error "私钥文件不存在"
                    return 1
                fi
                
                verify_cert_key_pair "$cert_path" "$key_path" || return 1
                
                mkdir -p "$HYSTERIA_CERT_DIR"
                cp "$cert_path" "$HYSTERIA_CERT_DIR/server.crt"
                cp "$key_path" "$HYSTERIA_CERT_DIR/server.key"
                chmod 600 "$HYSTERIA_CERT_DIR/server.key"
            fi
            ;;
            
        2)
            # ACME HTTP
            read -p "请输入域名: " hysteria_domain
            if [ -z "$hysteria_domain" ]; then
                log_error "域名不能为空"
                return 1
            fi
            
            read -p "请输入 ACME 邮箱 (默认随机): " hysteria_acme_email
            if [ -z "$hysteria_acme_email" ]; then
                hysteria_acme_email="$(openssl rand -hex 4)@example.com"
            fi
            ;;
            
        *)
            log_error "无效选择"
            return 1
            ;;
    esac
    
    # 获取端口
    read -p "请输入监听端口 (留空则自动生成): " hysteria_port
    if [ -z "$hysteria_port" ]; then
        hysteria_port=$(get_available_port 20000 50000) || return 1
        log_info "已分配端口: $hysteria_port"
    fi
    
    if ! check_port_available "$hysteria_port"; then
        log_error "端口 $hysteria_port 已被占用"
        return 1
    fi
    
    # 获取密码
    read -p "请输入密码 (留空则自动生成): " hysteria_password
    if [ -z "$hysteria_password" ]; then
        hysteria_password=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-16)
        log_info "已生成密码: $hysteria_password"
    fi
    
    # 获取伪装 URL
    read -p "请输入伪装 URL (默认https://www.bing.com): " masquerade_url
    masquerade_url=${masquerade_url:-"https://www.bing.com"}
    
    # 下载 Hysteria2
    local arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l) arch="arm" ;;
        *)
            log_error "不支持的系统架构: $arch"
            return 1
            ;;
    esac
    
    local download_url="https://download.hysteria.network/app/latest/hysteria-linux-${arch}"
    
    log_info "下载 Hysteria2..."
    if ! download_with_retry "$download_url" "$HYSTERIA_BIN"; then
        return 1
    fi
    
    chmod +x "$HYSTERIA_BIN"
    
    # 设置权限 (ACME 模式)
    if [ "$tls_type" -eq 2 ]; then
        if command -v setcap &>/dev/null; then
            setcap 'cap_net_bind_service=+ep' "$HYSTERIA_BIN" || log_warn "setcap 设置失败"
        fi
    fi
    
    # 生成配置
    mkdir -p "$(dirname "$HYSTERIA_CONFIG")"
    chmod 700 "$(dirname "$HYSTERIA_CONFIG")"
    
    cat > "$HYSTERIA_CONFIG" << EOF
listen: :$hysteria_port
auth:
  type: password
  password: $hysteria_password
masquerade:
  type: proxy
  proxy:
    url: $masquerade_url
    rewriteHost: true
EOF
    
    if [ "$tls_type" -eq 1 ]; then
        cat >> "$HYSTERIA_CONFIG" << EOF
tls:
  cert: $HYSTERIA_CERT_DIR/server.crt
  key: $HYSTERIA_CERT_DIR/server.key
EOF
    else
        cat >> "$HYSTERIA_CONFIG" << EOF
acme:
  domains:
    - $hysteria_domain
  email: $hysteria_acme_email
EOF
    fi
    
    chmod 600 "$HYSTERIA_CONFIG"
    
    # 配置服务
    case "$OS_TYPE" in
        "alpine")
            cat > "$HYSTERIA_SERVICE_OPENRC" << 'EOF'
#!/sbin/openrc-run
name="hysteria"
description="Hysteria2 Service"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
pidfile="/run/hysteria.pid"
respawn_delay=5
output_log="/var/log/hysteria.log"
error_log="/var/log/hysteria.error.log"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -f "$output_log" -m 0644
    checkpath -f "$error_log" -m 0644
}

start() {
    ebegin "Starting hysteria"
    start-stop-daemon --start --background \
        --exec $command \
        --make-pidfile --pidfile $pidfile \
        -- $command_args
    eend $?
}

stop() {
    ebegin "Stopping hysteria"
    start-stop-daemon --stop --pidfile $pidfile
    eend $?
}
EOF
            chmod +x "$HYSTERIA_SERVICE_OPENRC"
            rc-update add hysteria default 2>/dev/null || true
            ;;
            
        *)
            cat > "$HYSTERIA_SERVICE_SYSTEMD" << EOF
[Unit]
Description=Hysteria2 Service
After=network.target

[Service]
Type=simple
ExecStart=$HYSTERIA_BIN server --config $HYSTERIA_CONFIG
Restart=always
RestartSec=10
User=root
LimitNOFILE=infinity
StandardOutput=file:/var/log/hysteria-access.log
StandardError=file:/var/log/hysteria-error.log

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable hysteria 2>/dev/null || true
            ;;
    esac
    
    setup_logrotate "hysteria" "/var/log/hysteria*.log"
    
    # 启动服务
    start_service "hysteria" || return 1
    
    # 显示链接
    show_hysteria_links
    
    log_success "Hysteria2 安装完成"
}

show_hysteria_links() {
    local port=$(grep 'listen:' "$HYSTERIA_CONFIG" | awk '{print $2}' | tr -d ':')
    local password=$(grep 'password:' "$HYSTERIA_CONFIG" | awk '{print $2}')
    local server_ip=$(get_public_ip)
    
    local sni=""
    local insecure=0
    
    if grep -q 'acme:' "$HYSTERIA_CONFIG"; then
        sni=$(grep 'domains:' -A1 "$HYSTERIA_CONFIG" | tail -1 | awk '{print $2}' | tr -d '- ')
        insecure=0
    else
        sni=$(openssl x509 -noout -subject -in "$HYSTERIA_CERT_DIR/server.crt" 2>/dev/null | grep -o 'CN=[^,]*' | cut -d= -f2 | tr -d ' ')
        insecure=1
    fi
    
    local link="hysteria2://${password}@${server_ip}:${port}/?sni=${sni}&insecure=${insecure}&alpn=h3#Hysteria2"
    
    blue "\n=============== Hysteria2 客户端链接 ================"
    green "$link"
    blue "=====================================================\n"
}

uninstall_hysteria2() {
    if [ ! -f "$HYSTERIA_BIN" ]; then
        log_warn "Hysteria2 未安装"
        return 0
    fi
    
    log_info "开始卸载 Hysteria2..."
    
    stop_service "hysteria" || true
    
    case "$OS_TYPE" in
        "alpine")
            rc-update del hysteria 2>/dev/null || true
            rm -f "$HYSTERIA_SERVICE_OPENRC"
            ;;
        *)
            systemctl disable hysteria 2>/dev/null || true
            rm -f "$HYSTERIA_SERVICE_SYSTEMD"
            systemctl daemon-reload
            ;;
    esac
    
    rm -f "$HYSTERIA_BIN"
    rm -rf "$(dirname "$HYSTERIA_CONFIG")"
    rm -f /var/log/hysteria*.log
    rm -f /etc/logrotate.d/hysteria
    
    log_success "Hysteria2 已卸载"
}

# ============================================================================
# AnyTLS-Go 安装和管理
# ============================================================================

install_anytls_go() {
    log_info "开始安装 AnyTLS-Go..."
    
    # 安装依赖
    install_deps
    verify_dependencies || return 1
    
    # 获取端口
    read -p "请输入监听端口 (默认8443): " anytls_port
    anytls_port=${anytls_port:-8443}
    
    if ! check_port_available "$anytls_port"; then
        log_error "端口 $anytls_port 已被占用"
        return 1
    fi
    
    # 获取密码
    read -p "请输入密码 (留空则自动生成): " anytls_password
    if [ -z "$anytls_password" ]; then
        anytls_password=$(openssl rand -base64 16 | tr -d '=+/' | cut -c1-16)
        log_info "已生成密码: $anytls_password"
    fi
    
    # 下载 AnyTLS-Go
    local arch=$(uname -m)
    case $arch in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)
            log_error "不支持的系统架构: $arch"
            return 1
            ;;
    esac
    
    local version="v0.0.8"
    local filename="anytls_${version#v}_linux_${arch}.zip"
    local download_url="https://github.com/anytls/anytls-go/releases/download/${version}/${filename}"
    local temp_file="$TEMP_DIR/$filename"
    
    log_info "下载 AnyTLS-Go..."
    if ! download_with_retry "$download_url" "$temp_file"; then
        return 1
    fi
    
    if ! verify_file_integrity "$temp_file" "zip"; then
        return 1
    fi
    
    log_info "解压 AnyTLS-Go..."
    if ! unzip -q -d "$TEMP_DIR" "$temp_file"; then
        log_error "解压失败"
        return 1
    fi
    
    if [ ! -f "$TEMP_DIR/anytls-server" ]; then
        log_error "解压后未找到 anytls-server"
        return 1
    fi
    
    mv "$TEMP_DIR/anytls-server" "$ANYTLS_BIN"
    chmod +x "$ANYTLS_BIN"
    
    # 配置服务
    case "$OS_TYPE" in
        "alpine")
            cat > "$ANYTLS_SERVICE_OPENRC" << EOF
#!/sbin/openrc-run
name="anytls-server"
description="AnyTLS-Go Service"
command="$ANYTLS_BIN"
command_args="-l :$anytls_port -p \"$anytls_password\""
pidfile="/run/anytls-server.pid"
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
    ebegin "Starting anytls-server"
    start-stop-daemon --start --background \\
        --exec \$command \\
        --make-pidfile --pidfile \$pidfile \\
        -- \\
        \$command_args
    eend \$?
}

stop() {
    ebegin "Stopping anytls-server"
    start-stop-daemon --stop --pidfile \$pidfile
    eend \$?
}
EOF
            chmod +x "$ANYTLS_SERVICE_OPENRC"
            rc-update add anytls-server default 2>/dev/null || true
            ;;
            
        *)
            cat > "$ANYTLS_SERVICE_SYSTEMD" << EOF
[Unit]
Description=AnyTLS-Go Service
After=network.target

[Service]
Type=simple
ExecStart=$ANYTLS_BIN -l :$anytls_port -p "$anytls_password"
Restart=always
RestartSec=10
User=root
LimitNOFILE=30000
StandardOutput=file:/var/log/anytls-access.log
StandardError=file:/var/log/anytls-error.log

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable anytls-server 2>/dev/null || true
            ;;
    esac
    
    setup_logrotate "anytls-server" "/var/log/anytls*.log"
    
    # 启动服务
    start_service "anytls-server" || return 1
    
    # 显示链接
    show_anytls_links
    
    log_success "AnyTLS-Go 安装完成"
}

show_anytls_links() {
    local server_ip=$(get_public_ip)
    local port=8443
    local password="PASSWORD"
    
    # 尝试从服务配置中获取实际信息
    case "$OS_TYPE" in
        "alpine")
            if [ -f "$ANYTLS_SERVICE_OPENRC" ]; then
                port=$(grep 'command_args=' "$ANYTLS_SERVICE_OPENRC" | grep -oE -- '-l :[0-9]+' | awk -F':' '{print $2}')
                password=$(grep 'command_args=' "$ANYTLS_SERVICE_OPENRC" | grep -oE -- '-p "[^"]+"' | awk -F'"' '{print $2}')
            fi
            ;;
        *)
            if [ -f "$ANYTLS_SERVICE_SYSTEMD" ]; then
                port=$(grep 'ExecStart=' "$ANYTLS_SERVICE_SYSTEMD" | grep -oE -- '-l :[0-9]+' | awk -F':' '{print $2}')
                password=$(grep 'ExecStart=' "$ANYTLS_SERVICE_SYSTEMD" | grep -oE -- '-p "[^"]+"' | awk -F'"' '{print $2}')
            fi
            ;;
    esac
    
    local link="anytls://${password}@${server_ip}:${port}#AnyTLS-Go"
    
    blue "\n=============== AnyTLS-Go 客户端链接 ================"
    green "$link"
    blue "====================================================\n"
}

uninstall_anytls_go() {
    if [ ! -f "$ANYTLS_BIN" ]; then
        log_warn "AnyTLS-Go 未安装"
        return 0
    fi
    
    log_info "开始卸载 AnyTLS-Go..."
    
    stop_service "anytls-server" || true
    
    case "$OS_TYPE" in
        "alpine")
            rc-update del anytls-server 2>/dev/null || true
            rm -f "$ANYTLS_SERVICE_OPENRC"
            ;;
        *)
            systemctl disable anytls-server 2>/dev/null || true
            rm -f "$ANYTLS_SERVICE_SYSTEMD"
            systemctl daemon-reload
            ;;
    esac
    
    rm -f "$ANYTLS_BIN"
    rm -f /var/log/anytls*.log
    rm -f /etc/logrotate.d/anytls-server
    
    log_success "AnyTLS-Go 已卸载"
}

# ============================================================================
# 服务控制
# ============================================================================

manage_service() {
    yellow "\n请选择要管理的服务:"
    echo "1. Xray"
    echo "2. Hysteria2"
    echo "3. AnyTLS-Go"
    read -p "请选择 [1-3]: " service_choice
    
    case $service_choice in
        1)
            yellow "\n请选择操作:"
            echo "1. 启动"
            echo "2. 停止"
            echo "3. 重启"
            echo "4. 查看状态"
            read -p "请选择 [1-4]: " action
            
            case $action in
                1) start_service "xray" ;;
                2) stop_service "xray" ;;
                3) restart_service "xray" ;;
                4) 
                    if is_service_running "xray"; then
                        green "Xray 正在运行"
                    else
                        yellow "Xray 未运行"
                    fi
                    ;;
            esac
            ;;
            
        2)
            yellow "\n请选择操作:"
            echo "1. 启动"
            echo "2. 停止"
            echo "3. 重启"
            echo "4. 查看状态"
            read -p "请选择 [1-4]: " action
            
            case $action in
                1) start_service "xray" ;;
                2) stop_service "xray" ;;
                3) restart_service "xray" ;;
                4) 
                    if is_service_running "xray"; then
                        green "Xray 正在运行"
                    else
                        yellow "Xray 未运行"
                    fi
                    ;;
            esac
            ;;
            
        2)
            yellow "\n请选择操作:"
            echo "1. 启动"
            echo "2. 停止"
            echo "3. 重启"
            echo "4. 查看状态"
            read -p "请选择 [1-4]: " action
            
            case $action in
                1) start_service "hysteria" ;;
                2) stop_service "hysteria" ;;
                3) restart_service "hysteria" ;;
                4)
                    if is_service_running "hysteria"; then
                        green "Hysteria2 正在运行"
                    else
                        yellow "Hysteria2 未运行"
                    fi
                    ;;
            esac
            ;;
            
        3)
            yellow "\n请选择操作:"
            echo "1. 启动"
            echo "2. 停止"
            echo "3. 重启"
            echo "4. 查看状态"
            read -p "请选择 [1-4]: " action
            
            case $action in
                1) start_service "anytls-server" ;;
                2) stop_service "anytls-server" ;;
                3) restart_service "anytls-server" ;;
                4)
                    if is_service_running "anytls-server"; then
                        green "AnyTLS-Go 正在运行"
                    else
                        yellow "AnyTLS-Go 未运行"
                    fi
                    ;;
            esac
            ;;
    esac
    
    read -p "按回车键返回..."
}

# ============================================================================
# 端口修改
# ============================================================================

change_port() {
    yellow "\n请选择要修改端口的服务:"
    echo "1. Xray"
    echo "2. Hysteria2"
    echo "3. AnyTLS-Go"
    read -p "请选择 [1-3]: " service_choice
    
    case $service_choice in
        1)
            if [ ! -f "$XRAY_CONFIG" ]; then
                log_error "Xray 未安装"
                return 1
            fi
            
            local current_port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG")
            green "当前 Xray 端口: $current_port"
            
            read -p "请输入新端口: " new_port
            
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                log_error "无效的端口号"
                return 1
            fi
            
            if ! check_port_available "$new_port"; then
                log_error "端口 $new_port 已被占用"
                return 1
            fi
            
            backup_config "$XRAY_CONFIG" "xray"
            jq --argjson new_port "$new_port" '.inbounds[0].port = $new_port' "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp"
            mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"
            
            restart_service "xray"
            log_success "Xray 端口已修改为: $new_port"
            ;;
            
        2)
            if [ ! -f "$HYSTERIA_CONFIG" ]; then
                log_error "Hysteria2 未安装"
                return 1
            fi
            
            local current_port=$(grep 'listen:' "$HYSTERIA_CONFIG" | awk '{print $2}' | tr -d ':')
            green "当前 Hysteria2 端口: $current_port"
            
            read -p "请输入新端口: " new_port
            
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                log_error "无效的端口号"
                return 1
            fi
            
            if ! check_port_available "$new_port"; then
                log_error "端口 $new_port 已被占用"
                return 1
            fi
            
            backup_config "$HYSTERIA_CONFIG" "hysteria"
            sed -i "s/listen: :$current_port/listen: :$new_port/" "$HYSTERIA_CONFIG"
            
            restart_service "hysteria"
            log_success "Hysteria2 端口已修改为: $new_port"
            ;;
            
        3)
            if [ ! -f "$ANYTLS_BIN" ]; then
                log_error "AnyTLS-Go 未安装"
                return 1
            fi
            
            local current_port=8443
            case "$OS_TYPE" in
                "alpine")
                    if [ -f "$ANYTLS_SERVICE_OPENRC" ]; then
                        current_port=$(grep 'command_args=' "$ANYTLS_SERVICE_OPENRC" | grep -oE -- '-l :[0-9]+' | awk -F':' '{print $2}')
                    fi
                    ;;
                *)
                    if [ -f "$ANYTLS_SERVICE_SYSTEMD" ]; then
                        current_port=$(grep 'ExecStart=' "$ANYTLS_SERVICE_SYSTEMD" | grep -oE -- '-l :[0-9]+' | awk -F':' '{print $2}')
                    fi
                    ;;
            esac
            
            green "当前 AnyTLS-Go 端口: $current_port"
            
            read -p "请输入新端口: " new_port
            
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
                log_error "无效的端口号"
                return 1
            fi
            
            if ! check_port_available "$new_port"; then
                log_error "端口 $new_port 已被占用"
                return 1
            fi
            
            case "$OS_TYPE" in
                "alpine")
                    sed -i "s/-l :$current_port/-l :$new_port/" "$ANYTLS_SERVICE_OPENRC"
                    ;;
                *)
                    sed -i "s/-l :$current_port/-l :$new_port/" "$ANYTLS_SERVICE_SYSTEMD"
                    systemctl daemon-reload
                    ;;
            esac
            
            restart_service "anytls-server"
            log_success "AnyTLS-Go 端口已修改为: $new_port"
            ;;
    esac
    
    read -p "按回车键返回..."
}

# ============================================================================
# 日志查看
# ============================================================================

view_logs() {
    yellow "\n请选择要查看的日志:"
    echo "1. Xray 访问日志"
    echo "2. Xray 错误日志"
    echo "3. Hysteria2 日志"
    echo "4. AnyTLS-Go 日志"
    read -p "请选择 [1-4]: " log_choice
    
    case $log_choice in
        1)
            if [ -f "${LOG_DIR}/xray-access.log" ]; then
                tail -f "${LOG_DIR}/xray-access.log"
            else
                log_error "日志文件不存在"
            fi
            ;;
        2)
            if [ -f "${LOG_DIR}/xray-error.log" ]; then
                tail -f "${LOG_DIR}/xray-error.log"
            else
                log_error "日志文件不存在"
            fi
            ;;
        3)
            if [ -f "/var/log/hysteria.log" ]; then
                tail -f "/var/log/hysteria.log"
            else
                log_error "日志文件不存在"
            fi
            ;;
        4)
            if [ -f "/var/log/anytls.log" ]; then
                tail -f "/var/log/anytls.log"
            else
                log_error "日志文件不存在"
            fi
            ;;
    esac
}

# ============================================================================
# 系统状态
# ============================================================================

show_system_status() {
    clear
    cyan "=============== 系统状态 ==============="
    
    echo ""
    cyan "系统信息:"
    echo "  操作系统: $OS_TYPE"
    echo "  主机名: $(hostname)"
    echo "  内核版本: $(uname -r)"
    echo "  CPU 核心数: $(nproc)"
    echo "  内存: $(free -h | awk '/^Mem:/ {print $2}')"
    echo "  磁盘使用: $(df -h / | awk 'NR==2 {print $5}')"
    
    echo ""
    cyan "服务状态:"
    
    # Xray
    if [ -f "$XRAY_BIN" ]; then
        if is_service_running "xray"; then
            green "  ✓ Xray: 运行中"
            local xray_port=$(jq -r '.inbounds[0].port' "$XRAY_CONFIG" 2>/dev/null || echo "未知")
            echo "    端口: $xray_port"
        else
            yellow "  ✗ Xray: 已安装但未运行"
        fi
    else
        red "  ✗ Xray: 未安装"
    fi
    
    # Hysteria2
    if [ -f "$HYSTERIA_BIN" ]; then
        if is_service_running "hysteria"; then
            green "  ✓ Hysteria2: 运行中"
            local hysteria_port=$(grep 'listen:' "$HYSTERIA_CONFIG" 2>/dev/null | awk '{print $2}' | tr -d ':' || echo "未知")
            echo "    端口: $hysteria_port"
        else
            yellow "  ✗ Hysteria2: 已安装但未运行"
        fi
    else
        red "  ✗ Hysteria2: 未安装"
    fi
    
    # AnyTLS-Go
    if [ -f "$ANYTLS_BIN" ]; then
        if is_service_running "anytls-server"; then
            green "  ✓ AnyTLS-Go: 运行中"
            echo "    端口: 8443"
        else
            yellow "  ✗ AnyTLS-Go: 已安装但未运行"
        fi
    else
        red "  ✗ AnyTLS-Go: 未安装"
    fi
    
    echo ""
    cyan "网络信息:"
    echo "  公网 IP: $(get_public_ip)"
    echo "  本地 IP: $(hostname -I | awk '{print $1}')"
    
    echo ""
    cyan "========================================"
    read -p "按回车键返回..."
}

# ============================================================================
# 主菜单
# ============================================================================

show_menu() {
    clear
    cyan "╔════════════════════════════════════════════════════════╗"
    cyan "║     代理协议安装管理脚本 v${SCRIPT_VERSION}                    ║"
    cyan "║  支持系统: Alpine/Ubuntu/Debian/CentOS                ║"
    cyan "╚════════════════════════════════════════════════════════╝"
    
    echo ""
    yellow "【安装与更新】"
    echo "  1. 安装 Xray (VMess/Trojan/VLESS/Shadowsocks)"
    echo "  2. 安装 Hysteria 2 (UDP加速)"
    echo "  3. 安装 AnyTLS-Go (TLS代理)"
    
    echo ""
    yellow "【卸载服务】"
    echo "  4. 卸载 Xray"
    echo "  5. 卸载 Hysteria 2"
    echo "  6. 卸载 AnyTLS-Go"
    
    echo ""
    yellow "【配置管理】"
    echo "  7. 查看 Xray 客户端链接"
    echo "  8. 查看 Hysteria 2 客户端链接"
    echo "  9. 查看 AnyTLS-Go 客户端链接"
    echo "  10. 修改服务端口"
    
    echo ""
    yellow "【服务控制】"
    echo "  11. 管理服务 (启动/停止/重启)"
    echo "  12. 查看日志"
    echo "  13. 系统状态"
    
    echo ""
    yellow "【其他】"
    echo "  14. 查看备份文件"
    echo "  0. 退出"
    
    cyan "════════════════════════════════════════════════════════"
    echo ""
    read -p "请选择操作 [0-14]: " choice
    
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
        11) manage_service ; show_menu ;;
        12) view_logs ; show_menu ;;
        13) show_system_status ; show_menu ;;
        14) 
            if [ -d "$BACKUP_DIR" ] && [ "$(ls -A "$BACKUP_DIR")" ]; then
                ls -lh "$BACKUP_DIR"
            else
                log_warn "没有备份文件"
            fi
            read -p "按回车键返回..."
            show_menu
            ;;
        0) 
            green "感谢使用，再见！"
            exit 0
            ;;
        *)
            log_error "无效选择"
            sleep 1
            show_menu
            ;;
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
