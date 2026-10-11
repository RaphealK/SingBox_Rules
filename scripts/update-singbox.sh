#!/usr/bin/env bash
# ==============================================================================
# Sing-Box 自动化配置更新与守护脚本 (适用于 Ubuntu / Debian / CentOS / Arch)
# 功能特性:
#   1. 专有 User-Agent 识别 (防止 Sub-Store 下发错误的 YAML 格式)
#   2. 本地代理智能回退 (直连超时自动尝试通过 127.0.0.1:7890 代理重试)
#   3. 严格语法预检 (Dry-Run: sing-box check，校验失败绝不覆盖)
#   4. 零中断热重载 (SIGHUP，长连接无感保持)
#   5. 自愈回滚机制 (若重载后服务异常，自动还原上一次备份)
#   6. 支持 URL 持久化存储与参数传参
# ==============================================================================

set -o pipefail

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
BACKUP_FILE="${CONFIG_DIR}/config.json.bak"
TEMP_FILE="/tmp/singbox_config_new.json"
ENV_FILE="${CONFIG_DIR}/sub_url.env"
LOCAL_PROXY="http://127.0.0.1:7890"
USER_AGENT="sing-box/1.14.3"

# 颜色高亮
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${PLAIN} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${PLAIN} $1"; }
log_err()  { echo -e "${RED}[ERROR]${PLAIN} $1"; }

# 权限检查
if [ "$(id -u)" -ne 0 ]; then
    log_err "请使用 root 或 sudo 运行此脚本！"
    exit 1
fi

# 检查 sing-box 命令是否存在
if ! command -v sing-box &>/dev/null; then
    log_err "未找到 sing-box 命令，请确认是否已正确安装并在 PATH 中！"
    exit 1
fi

# 确保配置目录存在
mkdir -p "${CONFIG_DIR}"

# 打印帮助信息
show_help() {
    cat << EOF
用法: $(basename "$0") [选项]

选项:
  -u, --url <URL>      设置并保存新的订阅/配置链接，并立即执行更新
  -r, --rollback       回滚到上一次成功的备份配置 (config.json.bak)
  -t, --test           对当前生效的 /etc/sing-box/config.json 执行语法检查
  -l, --logs           实时查看 sing-box 运行日志 (彩色输出)
  -h, --help           显示此帮助信息

示例:
  sudo $(basename "$0") -u "https://sub.example.com/download?token=xxx#noCache"
  sudo $(basename "$0")
  sudo $(basename "$0") -r
EOF
    exit 0
}

# 回滚逻辑
do_rollback() {
    if [ ! -f "${BACKUP_FILE}" ]; then
        log_err "未找到备份文件: ${BACKUP_FILE}，无法回滚！"
        exit 1
    fi
    log_warn "正在回滚到上一次的备份配置..."
    cp "${BACKUP_FILE}" "${CONFIG_FILE}"
    if systemctl is-active --quiet sing-box; then
        systemctl reload sing-box
    else
        systemctl start sing-box
    fi
    log_info "已成功回滚并恢复服务运行！"
    exit 0
}

# 参数解析
NEW_URL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--url)
            NEW_URL="$2"
            shift 2
            ;;
        -r|--rollback)
            do_rollback
            ;;
        -t|--test)
            log_info "正在检验当前配置: ${CONFIG_FILE}"
            sing-box check -c "${CONFIG_FILE}" && log_info "配置语法正确！"
            exit 0
            ;;
        -l|--logs)
            exec journalctl -u sing-box -f -o cat
            ;;
        -h|--help)
            show_help
            ;;
        *)
            log_err "未知参数: $1"
            show_help
            ;;
    esac
done

# 如果指定了新 URL，持久化保存到 env 文件
if [ -n "${NEW_URL}" ]; then
    echo "SUB_URL=\"${NEW_URL}\"" > "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
    log_info "已保存订阅地址到 ${ENV_FILE}"
fi

# 读取持久化 URL
if [ -f "${ENV_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi

if [ -z "${SUB_URL}" ]; then
    log_err "未检测到配置订阅链接！"
    log_info "首次运行请提供链接，例如:"
    echo "  sudo $(basename "$0") -u \"https://你的SubStore链接或GitHub链接#noCache\""
    exit 1
fi

log_info "准备拉取配置: ${SUB_URL}"

# 1. 下载逻辑 (双模: 直连优先 -> 本地代理回退)
DOWNLOAD_SUCCESS=0
log_info "[1/4] 正在拉取远程配置 (直连模式)..."
if curl -fsSL -m 25 -A "${USER_AGENT}" "${SUB_URL}" -o "${TEMP_FILE}"; then
    DOWNLOAD_SUCCESS=1
else
    log_warn "直连拉取超时或失败，正在检测本地代理通道 (${LOCAL_PROXY})..."
    if curl -s -m 3 --proxy "${LOCAL_PROXY}" http://www.msftconnecttest.com/connecttest.txt &>/dev/null; then
        log_info "本地代理端口可用，尝试通过本地代理再次拉取..."
        if curl -fsSL -m 25 --proxy "${LOCAL_PROXY}" -A "${USER_AGENT}" "${SUB_URL}" -o "${TEMP_FILE}"; then
            DOWNLOAD_SUCCESS=1
        fi
    fi
fi

if [ "${DOWNLOAD_SUCCESS}" -ne 1 ]; then
    log_err "❌ 下载配置失败！请检查网络连通性或订阅链接有效性。原有配置已完整保留！"
    rm -f "${TEMP_FILE}"
    exit 1
fi

# 2. 语法预检 (Dry-Run: sing-box check)
log_info "[2/4] 正在执行语法与规则集预检 (sing-box check)..."
if ! sing-box check -c "${TEMP_FILE}"; then
    log_err "❌ 新配置语法或规则集校验失败！已拒绝应用，防止服务挂掉断网。"
    rm -f "${TEMP_FILE}"
    exit 1
fi

# 3. 备份与应用
log_info "[3/4] 语法预检 100% 通过，正在应用配置并备份旧配置..."
if [ -f "${CONFIG_FILE}" ]; then
    cp -p "${CONFIG_FILE}" "${BACKUP_FILE}"
fi
mv "${TEMP_FILE}" "${CONFIG_FILE}"
chmod 644 "${CONFIG_FILE}"

# 4. 平滑重载与自愈监控
log_info "[4/4] 正在应用配置..."
if systemctl is-active --quiet sing-box; then
    log_info "Sing-Box 正在运行，执行零中断平滑热重载 (systemctl reload)..."
    systemctl reload sing-box
else
    log_info "Sing-Box 未处于运行状态，执行启动 (systemctl start)..."
    systemctl start sing-box
fi

# 状态自愈验证: 暂停 1 秒检查进程是否存活
sleep 1
if ! systemctl is-active --quiet sing-box; then
    log_err "❌ 严重警告: 重载后服务异常退出！正在触发自动回滚救命机制..."
    if [ -f "${BACKUP_FILE}" ]; then
        cp "${BACKUP_FILE}" "${CONFIG_FILE}"
        systemctl start sing-box
        log_warn "已紧急恢复上一版本备份，请检查刚才下载的配置内容！"
    fi
    exit 1
fi

log_info "🎉 配置更新成功，服务运行正常！"
exit 0
