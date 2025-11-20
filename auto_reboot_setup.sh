#!/bin/bash
# auto_reboot_setup.sh - Linux服务器循环重启自动配置脚本

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[警告]${NC} $1"
}

error() {
    echo -e "${RED}[错误]${NC} $1"
}

info() {
    echo -e "${BLUE}[信息]${NC} $1"
}

# 检查root权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请使用root权限运行此脚本: sudo $0"
        exit 1
    fi
}

# 验证数字输入
validate_number() {
    local input="$1"
    if ! [[ "$input" =~ ^[0-9]+$ ]] || [ "$input" -eq 0 ]; then
        return 1
    fi
    return 0
}

# 创建重启脚本
create_reboot_script() {
    local script_path="/usr/local/bin/auto_reboot.sh"
    
    cat > "$script_path" << 'EOF'
#!/bin/bash
# 自动重启脚本

LOG_FILE="/var/log/auto_reboot.log"
CONFIG_FILE="/etc/auto_reboot.conf"

# 加载配置
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    REBOOT_INTERVAL=8
fi

# 日志函数
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
    logger -t "auto-reboot" "$1"
}

# 检查是否有用户登录
check_users() {
    local users=$(who | wc -l)
    if [ "$users" -gt 0 ]; then
        log_message "检测到有用户登录，用户数: $users"
        return 0
    fi
    return 1
}

# 检查高负载
check_load() {
    local load=$(awk '{print $1}' /proc/loadavg)
    local cores=$(nproc)
    local threshold=$(echo "$cores * 2" | bc)
    
    if (( $(echo "$load > $threshold" | bc -l) )); then
        log_message "系统负载较高: $load (阈值: $threshold)，延迟重启"
        return 1
    fi
    return 0
}

# 主执行函数
main() {
    log_message "=== 开始执行自动重启 ==="
    log_message "重启间隔: ${REBOOT_INTERVAL}小时"
    log_message "当前系统运行时间: $(uptime -p)"
    log_message "当前负载: $(cat /proc/loadavg)"
    
    # 检查条件
    if check_users; then
        log_message "检测到有用户登录，发送重启通知但继续执行"
    fi
    
    if ! check_load; then
        log_message "系统负载过高，取消本次重启"
        exit 1
    fi
    
    # 发送重启通知
    log_message "发送重启广播通知"
    wall "警告：系统将在5分钟后自动重启进行定期维护，请立即保存您的工作！"
    
    # 记录重启前的系统信息
    log_message "内存使用: $(free -h | grep Mem | awk '{print $3"/"$2}')"
    log_message "磁盘使用: $(df -h / | awk 'NR==2 {print $3"/"$2 " ("$5")"}')"
    
    # 等待5分钟，给用户时间保存工作
    local countdown=300
    while [ $countdown -gt 0 ]; do
        if [ $((countdown % 60)) -eq 0 ]; then
            local minutes=$((countdown / 60))
            wall "系统将在 ${minutes} 分钟后重启，请保存工作！"
        fi
        sleep 1
        countdown=$((countdown - 1))
    done
    
    # 最终重启
    log_message "执行系统重启..."
    sync
    systemctl reboot
}

# 异常处理
trap 'log_message "脚本被中断"; exit 1' INT TERM

main "$@"
EOF

    chmod +x "$script_path"
    log "创建重启脚本: $script_path"
}

# 创建配置文件
create_config() {
    local interval="$1"
    local config_path="/etc/auto_reboot.conf"
    
    cat > "$config_path" << EOF
# 自动重启配置
REBOOT_INTERVAL=${interval}
CONFIG_VERSION="1.0"
EOF

    chmod 644 "$config_path"
    log "创建配置文件: $config_path"
}

# 创建systemd服务文件
create_systemd_service() {
    local service_path="/etc/systemd/system/auto-reboot.service"
    
    cat > "$service_path" << EOF
[Unit]
Description=Auto Reboot Service
Documentation=https://github.com/shijinyiA/shijinyiA
After=network.target multi-user.target
Wants=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/auto_reboot.sh
User=root
# 安全设置
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/log /etc

[Install]
WantedBy=multi-user.target
EOF

    log "创建systemd服务文件: $service_path"
}

# 创建systemd定时器文件
create_systemd_timer() {
    local interval="$1"
    local timer_path="/etc/systemd/system/auto-reboot.timer"
    
    # 计算随机延迟（最大10分钟）
    local random_delay=$(( RANDOM % 600 ))
    
    cat > "$timer_path" << EOF
[Unit]
Description=Auto Reboot Timer
Documentation=https://github.com/shijinyiA/shijinyiA
Requires=auto-reboot.service

[Timer]
# 每 interval 小时执行一次
OnCalendar=*-*-* */${interval}:00:00
RandomizedDelaySec=${random_delay}
Persistent=true
# 在系统启动后15分钟才开始考虑第一次执行
OnBootSec=15min
OnUnitActiveSec=${interval}h

[Install]
WantedBy=timers.target
EOF

    log "创建systemd定时器文件: $timer_path"
}

# 安装必要工具
install_dependencies() {
    if ! command -v bc &> /dev/null; then
        log "安装 bc 工具..."
        if command -v apt &> /dev/null; then
            apt update && apt install -y bc
        elif command -v yum &> /dev/null; then
            yum install -y bc
        elif command -v dnf &> /dev/null; then
            dnf install -y bc
        else
            warn "无法自动安装 bc，请手动安装"
        fi
    fi
}

# 启用并启动服务
enable_services() {
    log "重新加载systemd配置..."
    systemctl daemon-reload
    
    log "启用auto-reboot定时器..."
    systemctl enable auto-reboot.timer
    
    log "启动auto-reboot定时器..."
    systemctl start auto-reboot.timer
}

# 显示状态信息
show_status() {
    echo
    info "=== 自动重启配置完成 ==="
    log "重启间隔: ${REBOOT_INTERVAL} 小时"
    log "重启脚本: /usr/local/bin/auto_reboot.sh"
    log "配置文件: /etc/auto_reboot.conf"
    log "日志文件: /var/log/auto_reboot.log"
    
    echo
    info "=== 服务状态 ==="
    systemctl status auto-reboot.timer --no-pager -l
    
    echo
    info "=== 下次重启时间 ==="
    local next_time=$(systemctl list-timers auto-reboot.timer --no-legend 2>/dev/null | awk '{print $3 " " $4 " " $5}')
    if [ -n "$next_time" ]; then
        log "下次重启: $next_time"
    else
        warn "无法获取下次重启时间，请检查定时器状态"
    fi
    
    echo
    info "=== 管理命令 ==="
    echo "查看定时器状态: systemctl status auto-reboot.timer"
    echo "查看下次执行: systemctl list-timers auto-reboot.timer"
    echo "查看服务日志: journalctl -u auto-reboot.service -f"
    echo "查看应用日志: tail -f /var/log/auto_reboot.log"
    echo "停止自动重启: systemctl stop auto-reboot.timer && systemctl disable auto-reboot.timer"
    echo "重启定时器: systemctl restart auto-reboot.timer"
}

# 备份现有配置
backup_existing_config() {
    if [ -f "/etc/systemd/system/auto-reboot.service" ]; then
        local backup_dir="/root/auto_reboot_backup_$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$backup_dir"
        
        cp /etc/systemd/system/auto-reboot.service "$backup_dir/" 2>/dev/null || true
        cp /etc/systemd/system/auto-reboot.timer "$backup_dir/" 2>/dev/null || true
        cp /usr/local/bin/auto_reboot.sh "$backup_dir/" 2>/dev/null || true
        cp /etc/auto_reboot.conf "$backup_dir/" 2>/dev/null || true
        
        log "现有配置已备份到: $backup_dir"
    fi
}

# 停止现有服务
stop_existing_services() {
    if systemctl is-active --quiet auto-reboot.timer; then
        log "停止现有auto-reboot定时器..."
        systemctl stop auto-reboot.timer
        systemctl disable auto-reboot.timer
    fi
    
    if systemctl is-active --quiet auto-reboot.service; then
        log "停止现有auto-reboot服务..."
        systemctl stop auto-reboot.service
    fi
}

# 主函数
main() {
    echo
    info "=== Linux服务器循环重启自动配置脚本 ==="
    echo
    
    # 检查root权限
    check_root
    
    # 显示警告信息
    warn "此脚本将配置系统定期自动重启！"
    warn "请确保在业务低峰期进行配置。"
    echo
    
    # 获取重启间隔
    while true; do
        read -p "请输入重启间隔（小时）: " REBOOT_INTERVAL
        if validate_number "$REBOOT_INTERVAL"; then
            break
        else
            error "请输入有效的正整数！"
        fi
    done
    
    echo
    log "开始配置自动重启，间隔: ${REBOOT_INTERVAL} 小时"
    
    # 备份现有配置
    backup_existing_config
    
    # 停止现有服务
    stop_existing_services
    
    # 安装依赖
    install_dependencies
    
    # 创建文件
    create_reboot_script
    create_config "$REBOOT_INTERVAL"
    create_systemd_service
    create_systemd_timer "$REBOOT_INTERVAL"
    
    # 启用服务
    enable_services
    
    # 显示状态
    show_status
    
    echo
    log "配置完成！系统将每 ${REBOOT_INTERVAL} 小时自动重启一次。"
}

# 脚本入口
main "$@"
