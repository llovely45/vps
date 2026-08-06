#!/bin/bash

# cf-ddns installer/updater
# 版本：2.0.0
#
# 菜单功能：
#   - 强制更新 A 记录
#   - 修改绑定域名
#   - 开启/关闭 Cloudflare 橙云代理
#   - 从 GitHub raw 地址升级本脚本
#   - 卸载脚本和定时任务

CF_DDNS_SCRIPT_VERSION="2.0.0"
DDNS_SCRIPT_URL="https://raw.githubusercontent.com/llovely45/vps/refs/heads/main/ddns.sh"

CONFIG_FILE="/etc/cf-ddns.conf"
UPDATE_SCRIPT="/usr/local/bin/cf-update.sh"
MENU_SCRIPT="/usr/local/bin/ddns"
INSTALLER_SCRIPT="/usr/local/bin/ddns-installer.sh"
CACHE_FILE="/var/tmp/cf_ddns_cache.txt"

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 权限运行此脚本" >&2
    exit 1
fi

umask 077

UPGRADE_ONLY=false
if [ "${1:-}" = "--upgrade" ]; then
    UPGRADE_ONLY=true
fi

# 配置文件是 root 可读文件，内容由本脚本生成。
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

CF_API_TOKEN="${CF_API_TOKEN:-}"
ZONE_ID="${ZONE_ID:-}"
DOMAIN_NAME="${DOMAIN_NAME:-}"
RECORD_ID="${RECORD_ID:-}"
PROXIED="${PROXIED:-true}"

die() {
    echo "错误：$*" >&2
    exit 1
}

is_api_success() {
    printf '%s' "$1" | grep -qE '"success"[[:space:]]*:[[:space:]]*true'
}

extract_record_id() {
    printf '%s' "$1" \
        | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -n 1 \
        | sed -E 's/.*"([^"]+)"/\1/'
}

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

json_quote() {
    printf '"%s"' "$(json_escape "$1")"
}

get_record_id() {
    local domain="$1"
    local response

    response=$(curl -sS --connect-timeout 10 --max-time 30 --get \
        --data-urlencode "name=${domain}" \
        --data-urlencode "type=A" \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json") || return 1

    if ! is_api_success "$response"; then
        return 1
    fi

    extract_record_id "$response"
}

save_config() {
    {
        printf 'CF_API_TOKEN=%q\n' "$CF_API_TOKEN"
        printf 'ZONE_ID=%q\n' "$ZONE_ID"
        printf 'DOMAIN_NAME=%q\n' "$DOMAIN_NAME"
        printf 'RECORD_ID=%q\n' "$RECORD_ID"
        printf 'PROXIED=%q\n' "$PROXIED"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

validate_config() {
    [ -n "$CF_API_TOKEN" ] || die "CF_API_TOKEN 不能为空"
    [ -n "$ZONE_ID" ] || die "ZONE_ID 不能为空"
    [ -n "$DOMAIN_NAME" ] || die "DOMAIN_NAME 不能为空"
    [ -n "$RECORD_ID" ] || die "RECORD_ID 不能为空"

    case "$PROXIED" in
        true|false) ;;
        *)
            echo "检测到旧配置没有有效的 PROXIED 值，已恢复为 true。"
            PROXIED=true
            ;;
    esac
}

prompt_for_config() {
    echo "========================="
    echo "   DDNS 自动安装配置"
    echo "========================="
    echo ""

    [ -n "$CF_API_TOKEN" ] || read -r -p "请输入 API Token: " CF_API_TOKEN
    [ -n "$ZONE_ID" ] || read -r -p "请输入 Zone ID: " ZONE_ID
    [ -n "$DOMAIN_NAME" ] || read -r -p "请输入需要绑定的域名: " DOMAIN_NAME

    if [ -z "$RECORD_ID" ]; then
        echo "正在自动获取 ${DOMAIN_NAME} 的 Record ID..."
        RECORD_ID="$(get_record_id "$DOMAIN_NAME" 2>/dev/null || true)"
        if [ -z "$RECORD_ID" ]; then
            echo "自动获取失败，请确保该域名已经存在 A 记录。"
            read -r -p "请手动输入 Record ID: " RECORD_ID
        else
            echo "Record ID 获取成功。"
        fi
    fi
}

install_update_script() {
    cat << 'EOF' > "$UPDATE_SCRIPT"
#!/bin/bash

CONFIG_FILE="/etc/cf-ddns.conf"
CACHE_FILE="/var/tmp/cf_ddns_cache.txt"

if [ ! -r "$CONFIG_FILE" ]; then
    echo "配置文件不存在：$CONFIG_FILE" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

CF_API_TOKEN="${CF_API_TOKEN:-}"
ZONE_ID="${ZONE_ID:-}"
DOMAIN_NAME="${DOMAIN_NAME:-}"
RECORD_ID="${RECORD_ID:-}"
PROXIED="${PROXIED:-true}"
FORCE_UPDATE="${1:-}"

case "$PROXIED" in
    true|false) ;;
    *) PROXIED=true ;;
esac

is_api_success() {
    printf '%s' "$1" | grep -qE '"success"[[:space:]]*:[[:space:]]*true'
}

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

json_quote() {
    printf '"%s"' "$(json_escape "$1")"
}

if [ -z "$CF_API_TOKEN" ] || [ -z "$ZONE_ID" ] || [ -z "$DOMAIN_NAME" ] || [ -z "$RECORD_ID" ]; then
    echo "配置不完整，无法更新 DNS 记录。" >&2
    exit 1
fi

CURRENT_IP="$(curl -fsS --connect-timeout 10 --max-time 20 https://api4.ipify.org 2>/dev/null | tr -d '\r\n')"
if [ -z "$CURRENT_IP" ]; then
    echo "无法获取当前 IPv4，退出。" >&2
    exit 1
fi

CACHED_IP="$(cat "$CACHE_FILE" 2>/dev/null || true)"
if [ "$CURRENT_IP" != "$CACHED_IP" ] || [ "$FORCE_UPDATE" = "-f" ]; then
    echo "正在将 ${DOMAIN_NAME} 更新为 ${CURRENT_IP}（橙云：${PROXIED}）..."

    PAYLOAD=$(printf '{"type":"A","name":%s,"content":%s,"ttl":1,"proxied":%s}' \
        "$(json_quote "$DOMAIN_NAME")" \
        "$(json_quote "$CURRENT_IP")" \
        "$PROXIED")

    RESPONSE=$(curl -sS --connect-timeout 10 --max-time 30 \
        -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$PAYLOAD")
    CURL_STATUS=$?

    if [ "$CURL_STATUS" -eq 0 ] && is_api_success "$RESPONSE"; then
        printf '%s\n' "$CURRENT_IP" > "$CACHE_FILE"
        if [ "$PROXIED" = "true" ]; then
            echo "IP 更新成功，Cloudflare 橙云已开启。"
        else
            echo "IP 更新成功，Cloudflare 橙云已关闭（DNS only）。"
        fi
    else
        echo "更新失败，HTTP/API 返回：$RESPONSE" >&2
        exit 1
    fi
fi
EOF

    chmod 700 "$UPDATE_SCRIPT"
}

install_menu_script() {
    local menu_tmp
    menu_tmp="$(mktemp /tmp/cf-ddns-menu.XXXXXX)" || die "无法创建临时文件"

    cat << 'EOF' > "$menu_tmp"
#!/bin/bash

CF_DDNS_SCRIPT_VERSION="__CF_DDNS_SCRIPT_VERSION__"
DDNS_SCRIPT_URL="__DDNS_SCRIPT_URL__"
CONFIG_FILE="/etc/cf-ddns.conf"
UPDATE_SCRIPT="/usr/local/bin/cf-update.sh"
MENU_SCRIPT="/usr/local/bin/ddns"
INSTALLER_SCRIPT="/usr/local/bin/ddns-installer.sh"
CACHE_FILE="/var/tmp/cf_ddns_cache.txt"

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 权限运行此菜单" >&2
    exit 1
fi

umask 077

if [ ! -r "$CONFIG_FILE" ]; then
    echo "配置文件丢失，请重新运行安装脚本。" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

CF_API_TOKEN="${CF_API_TOKEN:-}"
ZONE_ID="${ZONE_ID:-}"
DOMAIN_NAME="${DOMAIN_NAME:-}"
RECORD_ID="${RECORD_ID:-}"
PROXIED="${PROXIED:-true}"

is_api_success() {
    printf '%s' "$1" | grep -qE '"success"[[:space:]]*:[[:space:]]*true'
}

extract_record_id() {
    printf '%s' "$1" \
        | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' \
        | head -n 1 \
        | sed -E 's/.*"([^"]+)"/\1/'
}

extract_proxied() {
    printf '%s' "$1" \
        | grep -oE '"proxied"[[:space:]]*:[[:space:]]*(true|false)' \
        | head -n 1 \
        | sed -E 's/.*:[[:space:]]*(true|false)/\1/'
}

get_record_response() {
    curl -sS --connect-timeout 10 --max-time 30 \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json"
}

get_record_id() {
    local domain="$1"
    local response

    response=$(curl -sS --connect-timeout 10 --max-time 30 --get \
        --data-urlencode "name=${domain}" \
        --data-urlencode "type=A" \
        "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json") || return 1

    if ! is_api_success "$response"; then
        return 1
    fi

    extract_record_id "$response"
}

save_config() {
    {
        printf 'CF_API_TOKEN=%q\n' "$CF_API_TOKEN"
        printf 'ZONE_ID=%q\n' "$ZONE_ID"
        printf 'DOMAIN_NAME=%q\n' "$DOMAIN_NAME"
        printf 'RECORD_ID=%q\n' "$RECORD_ID"
        printf 'PROXIED=%q\n' "$PROXIED"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

show_proxy_state() {
    local response remote_proxied

    response="$(get_record_response 2>/dev/null || true)"
    if is_api_success "$response"; then
        remote_proxied="$(extract_proxied "$response")"
        if [ "$remote_proxied" = "true" ] || [ "$remote_proxied" = "false" ]; then
            PROXIED="$remote_proxied"
            save_config
        fi
    fi
}

toggle_proxy() {
    local new_value response curl_status

    if [ "$PROXIED" = "true" ]; then
        new_value=false
    else
        new_value=true
    fi

    echo "正在切换 Cloudflare 橙云为：$([ "$new_value" = "true" ] && echo 开启 || echo 关闭)..."
    response=$(curl -sS --connect-timeout 10 --max-time 30 \
        -X PATCH "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{\"proxied\":${new_value}}")
    curl_status=$?

    if [ "$curl_status" -eq 0 ] && is_api_success "$response"; then
        PROXIED="$new_value"
        save_config
        if [ "$PROXIED" = "true" ]; then
            echo "橙云已开启。"
        else
            echo "橙云已关闭，当前为 DNS only。"
        fi
    else
        echo "切换失败，HTTP/API 返回：$response"
    fi
}

upgrade_script() {
    local upgrade_tmp
    upgrade_tmp="$(mktemp /tmp/cf-ddns-upgrade.XXXXXX)" || {
        echo "无法创建升级临时文件。"
        return
    }

    echo "正在从 GitHub 下载最新版脚本..."
    if ! curl -fsSL --connect-timeout 10 --max-time 60 "$DDNS_SCRIPT_URL" -o "$upgrade_tmp"; then
        echo "下载失败，请检查服务器网络或 GitHub 访问。"
        rm -f "$upgrade_tmp"
        return
    fi

    if ! grep -q '^#!/bin/bash' "$upgrade_tmp" || \
       ! grep -q '^CF_DDNS_SCRIPT_VERSION=' "$upgrade_tmp"; then
        echo "下载内容不是可识别的新版 ddns.sh，已取消升级。"
        rm -f "$upgrade_tmp"
        return
    fi

    chmod 700 "$upgrade_tmp"
    if bash "$upgrade_tmp" --upgrade; then
        rm -f "$upgrade_tmp"
        echo "升级成功，正在重新加载菜单..."
        exec "$MENU_SCRIPT"
    else
        echo "升级失败，现有菜单未被替换。"
        rm -f "$upgrade_tmp"
    fi
}

uninstall_all() {
    local cron_tmp
    read -r -p "确定要彻底卸载 DDNS、定时任务和配置吗？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[yY]([eE][sS])?$ ]]; then
        echo "已取消卸载。"
        return
    fi

    echo "正在清理定时任务..."
    if command -v crontab >/dev/null 2>&1; then
        cron_tmp="$(mktemp /tmp/cf-ddns-cron.XXXXXX)"
        if crontab -l 2>/dev/null > "$cron_tmp"; then
            grep -vF "$UPDATE_SCRIPT" "$cron_tmp" > "${cron_tmp}.new" || true
            crontab "${cron_tmp}.new" 2>/dev/null || true
            rm -f "${cron_tmp}.new"
        fi
        rm -f "$cron_tmp"
    fi

    rm -f "$UPDATE_SCRIPT" "$MENU_SCRIPT" "$INSTALLER_SCRIPT" "$CONFIG_FILE" "$CACHE_FILE"
    echo "卸载完成。"
    exit 0
}

while true; do
    clear 2>/dev/null || true
    # 每次打开菜单时从 Cloudflare 同步一次状态，避免手工在网页切换后显示旧值。
    show_proxy_state

    echo "================ DDNS 状态 ================"
    echo " 脚本版本   : $CF_DDNS_SCRIPT_VERSION"
    echo " 绑定域名   : $DOMAIN_NAME"
    echo " 缓存 IP    : $(cat "$CACHE_FILE" 2>/dev/null || echo '暂无缓存')"
    echo " 当前 IP    : $(curl -fsS --connect-timeout 5 --max-time 10 https://api4.ipify.org 2>/dev/null || echo '获取失败')"
    if [ "$PROXIED" = "true" ]; then
        echo " 代理状态   : 橙云已开启"
    else
        echo " 代理状态   : 橙云已关闭（DNS only）"
    fi
    echo "==========================================="
    echo " 1. 强制更新 IP 到域名"
    echo " 2. 修改绑定的域名"
    echo " 3. 查询当前域名的 Record ID"
    echo " 4. 开启/关闭 Cloudflare 橙云"
    echo " 5. 升级 DDNS 脚本"
    echo " 6. 彻底卸载 DDNS 脚本及定时任务"
    echo " 0. 退出菜单"
    echo "==========================================="
    read -r -p "请输入选项 [0-6]: " choice
    echo ""

    case "$choice" in
        1)
            "$UPDATE_SCRIPT" -f
            ;;
        2)
            read -r -p "请输入新的域名: " new_domain
            if [ -z "$new_domain" ]; then
                echo "域名不能为空。"
                break
            fi

            echo "正在向 Cloudflare 请求 ${new_domain} 的 Record ID..."
            new_record_id="$(get_record_id "$new_domain" 2>/dev/null || true)"
            if [ -n "$new_record_id" ]; then
                DOMAIN_NAME="$new_domain"
                RECORD_ID="$new_record_id"
                save_config
                rm -f "$CACHE_FILE"
                echo "域名修改成功，已自动保存新的 Record ID。"
                echo "正在为新域名执行首次 IP 更新..."
                "$UPDATE_SCRIPT" -f
            else
                echo "获取 Record ID 失败，请确保平台已存在该域名的 A 记录。"
            fi
            ;;
        3)
            echo "当前域名（$DOMAIN_NAME）的 Record ID 为：$RECORD_ID"
            ;;
        4)
            toggle_proxy
            ;;
        5)
            upgrade_script
            ;;
        6)
            uninstall_all
            ;;
        0)
            clear 2>/dev/null || true
            exit 0
            ;;
        *)
            echo "无效选项。"
            ;;
    esac

    echo ""
    read -r -n 1 -s -p "按任意键返回菜单..."
    echo ""
done
EOF

    sed -e "s|__CF_DDNS_SCRIPT_VERSION__|$CF_DDNS_SCRIPT_VERSION|g" \
        -e "s|__DDNS_SCRIPT_URL__|$DDNS_SCRIPT_URL|g" \
        "$menu_tmp" > "$MENU_SCRIPT"
    rm -f "$menu_tmp"
    chmod 700 "$MENU_SCRIPT"
}

install_self() {
    local source_path="${1:-}"

    # 让本机始终保留一份可手动执行的当前安装器；通过 curl | bash 执行时跳过。
    if [ -f "$source_path" ] && [ "$source_path" != "$INSTALLER_SCRIPT" ]; then
        cp "$source_path" "${INSTALLER_SCRIPT}.tmp"
        chmod 700 "${INSTALLER_SCRIPT}.tmp"
        mv -f "${INSTALLER_SCRIPT}.tmp" "$INSTALLER_SCRIPT"
        chmod 700 "$INSTALLER_SCRIPT"
    fi
}

install_cron() {
    local cron_tmp

    if ! command -v crontab >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update >/dev/null 2>&1 && apt-get install -y cron >/dev/null 2>&1
            if command -v systemctl >/dev/null 2>&1; then
                systemctl enable cron >/dev/null 2>&1 || true
                systemctl start cron >/dev/null 2>&1 || true
            fi
        elif command -v yum >/dev/null 2>&1; then
            yum install -y cronie >/dev/null 2>&1
            if command -v systemctl >/dev/null 2>&1; then
                systemctl enable crond >/dev/null 2>&1 || true
                systemctl start crond >/dev/null 2>&1 || true
            fi
        elif command -v apk >/dev/null 2>&1; then
            apk add cronie >/dev/null 2>&1
            command -v rc-update >/dev/null 2>&1 && rc-update add crond >/dev/null 2>&1 || true
            command -v rc-service >/dev/null 2>&1 && rc-service crond start >/dev/null 2>&1 || true
        fi
    fi

    if ! command -v crontab >/dev/null 2>&1; then
        echo "警告：未找到 crontab，定时更新未配置。"
        return 0
    fi

    cron_tmp="$(mktemp /tmp/cf-ddns-cron.XXXXXX)" || die "无法创建 cron 临时文件"
    crontab -l 2>/dev/null | grep -vF "$UPDATE_SCRIPT" > "$cron_tmp" || true
    printf '@reboot sleep 60 && %s\n' "$UPDATE_SCRIPT" >> "$cron_tmp"
    printf '0 */3 * * * %s\n' "$UPDATE_SCRIPT" >> "$cron_tmp"
    crontab "$cron_tmp"
    rm -f "$cron_tmp"
}

if [ "$UPGRADE_ONLY" = true ]; then
    [ -f "$CONFIG_FILE" ] || die "配置文件不存在，不能执行升级。"
    echo "正在升级 DDNS 脚本（保留现有配置）..."
else
    prompt_for_config
fi

validate_config
save_config
install_update_script
install_menu_script
install_self "$0"
install_cron

# 二次安装或升级时，使用现有缓存强制同步一次；不输出 token 等敏感配置。
if [ -f "$CACHE_FILE" ]; then
    "$UPDATE_SCRIPT" -f >/dev/null 2>&1 || true
fi

echo "==========================================="
if [ "$UPGRADE_ONLY" = true ]; then
    echo " DDNS 脚本升级完成！"
else
    echo " DDNS 安装完成！"
fi
echo " 现在可以直接输入 ddns 打开管理菜单。"
echo "==========================================="
