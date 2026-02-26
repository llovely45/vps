#!/bin/bash

# 检查是否以 root 权限运行
if [ "$(id -u)" != "0" ]; then
   echo "请使用 root 权限运行此脚本" 1>&2
   exit 1
fi

CONFIG_FILE="/etc/cf-ddns.conf"

# 1. 读取缓存配置 (如果存在则静默提取变量)
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

echo "========================="
echo "   DDNS 自动安装配置"
echo "========================="
echo ""

# 2. 只有当变量为空时才发起交互提问
[ -z "$CF_API_TOKEN" ] && read -p "请输入API: " CF_API_TOKEN
[ -z "$ZONE_ID" ] && read -p "请输入Zone: " ZONE_ID
[ -z "$DOMAIN_NAME" ] && read -p "请输入需要绑定的域名: " DOMAIN_NAME

# 如果缺少 Record ID（比如首次安装），则静默向平台请求
if [ -z "$RECORD_ID" ]; then
    API_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${DOMAIN_NAME}&type=A" \
         -H "Authorization: Bearer ${CF_API_TOKEN}" \
         -H "Content-Type: application/json")
    RECORD_ID=$(echo "$API_RESPONSE" | grep -o '"id":"[^"]*' | head -n 1 | cut -d'"' -f4)

    # 兜底：如果没查到，才提示手动输入
    if [ -z "$RECORD_ID" ]; then
        echo "自动获取失败！请确保你已提前添加了该域名的 A 记录。"
        read -p "请手动输入 Record ID: " RECORD_ID
    fi
fi

# 统一保存到独立配置文件，供后续脚本读取
cat << EOF > "$CONFIG_FILE"
CF_API_TOKEN="${CF_API_TOKEN}"
ZONE_ID="${ZONE_ID}"
DOMAIN_NAME="${DOMAIN_NAME}"
RECORD_ID="${RECORD_ID}"
EOF

# 3. 生成核心更新脚本 (使用单引号 'EOF' 防止变量在生成时被写死，改为运行时动态读取)
cat << 'EOF' > /usr/local/bin/cf-update.sh
#!/bin/bash
source /etc/cf-ddns.conf
CACHE_FILE="/var/tmp/cf_ddns_cache.txt"

FORCE_UPDATE=$1
CURRENT_IP=$(curl -s http://ip-api.com/line/?fields=query)

if [ -z "$CURRENT_IP" ]; then
    echo "无法获取当前 IP，退出。"
    exit 1
fi

CACHED_IP=$(cat "$CACHE_FILE" 2>/dev/null)

if [ "$CURRENT_IP" != "$CACHED_IP" ] || [ "$FORCE_UPDATE" == "-f" ]; then
    echo "检测到需要更新，正在将 IP 更新为 $CURRENT_IP ..."
    RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
         -H "Authorization: Bearer $CF_API_TOKEN" \
         -H "Content-Type: application/json" \
         --data "{\"type\":\"A\",\"name\":\"$DOMAIN_NAME\",\"content\":\"$CURRENT_IP\",\"ttl\":1,\"proxied\":true}")

    if echo "$RESPONSE" | grep -q '"success":true'; then
        echo "$CURRENT_IP" > "$CACHE_FILE"
        echo "IP 更新成功！代理已开启。"
    else
        echo "更新失败，返回报错：$RESPONSE"
    fi
else
    if [ "$FORCE_UPDATE" == "-f" ]; then
        echo "IP 未改变，无需更新。"
    fi
fi
EOF

chmod +x /usr/local/bin/cf-update.sh

# 4. 生成交互式命令面板 (加入 while 循环和按任意键返回)
cat << 'EOF' > /usr/local/bin/ddns
#!/bin/bash
CONFIG_FILE="/etc/cf-ddns.conf"
CACHE_FILE="/var/tmp/cf_ddns_cache.txt"

while true; do
    clear
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        echo "配置文件丢失！请重新运行安装脚本。"
        exit 1
    fi

    echo "正在获取信息，请稍候..."
    CURRENT_IP=$(curl -s --connect-timeout 5 http://ip-api.com/line/?fields=query || echo "获取失败")
    CACHED_IP=$(cat "$CACHE_FILE" 2>/dev/null || echo "暂无缓存")

    echo ""
    echo "================ DDNS 状态 ================"
    echo " 绑定域名   : $DOMAIN_NAME"
    echo " 缓存 IP    : $CACHED_IP"
    echo " 当前 IP    : $CURRENT_IP"
    echo " 代理状态   : 已开启"
    echo "==========================================="
    echo " 1. 强制更新 IP 到 域名"
    echo " 2. 修改绑定的域名"
    echo " 3. 查询当前域名的 Record ID"
    echo " 4. 彻底卸载 DDNS 脚本及定时任务"
    echo " 0. 退出菜单"
    echo "==========================================="
    read -p "请输入选项 [0-4]: " choice

    echo ""
    case $choice in
        1)
            /usr/local/bin/cf-update.sh -f
            ;;
        2)
            read -p "请输入新的域名: " NEW_DOMAIN
            if [ -n "$NEW_DOMAIN" ]; then
                echo "正在向平台请求 $NEW_DOMAIN 的 Record ID..."
                RES=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${NEW_DOMAIN}&type=A" \
                     -H "Authorization: Bearer ${CF_API_TOKEN}" \
                     -H "Content-Type: application/json")
                REC_ID=$(echo "$RES" | grep -o '"id":"[^"]*' | head -n 1 | cut -d'"' -f4)
                
                if [ -n "$REC_ID" ]; then
                    # 动态修改配置文件
                    sed -i "s/^DOMAIN_NAME=.*/DOMAIN_NAME=\"$NEW_DOMAIN\"/" "$CONFIG_FILE"
                    sed -i "s/^RECORD_ID=.*/RECORD_ID=\"$REC_ID\"/" "$CONFIG_FILE"
                    echo "域名修改成功！已自动保存新的 Record ID。"
                    
                    # 删掉旧 IP 缓存，强制立刻给新域名推一次 IP
                    rm -f "$CACHE_FILE"
                    echo "正在为新域名执行首次 IP 更新..."
                    /usr/local/bin/cf-update.sh -f
                else
                    echo "获取 Record ID 失败，请确保平台已存在该域名的 A 记录。"
                fi
            else
                echo "域名不能为空。"
            fi
            ;;
        3)
            echo "当前域名 ($DOMAIN_NAME) 的 Record ID 为: $RECORD_ID"
            ;;
        4)
            read -p "确定要彻底卸载并清理配置吗？(y/N): " confirm
            if [[ "$confirm" == [yY] || "$confirm" == [yY][eE][sS] ]]; then
                echo "正在清理定时任务..."
                crontab -l 2>/dev/null | grep -v '/usr/local/bin/cf-update.sh' | crontab -
                echo "正在删除脚本和配置..."
                rm -f /usr/local/bin/cf-update.sh
                rm -f /usr/local/bin/ddns
                rm -f "$CONFIG_FILE"
                rm -f "$CACHE_FILE"
                echo "卸载完成！"
                exit 0
            else
                echo "已取消卸载。"
            fi
            ;;
        0)
            clear
            exit 0
            ;;
        *)
            echo "无效选项。"
            ;;
    esac
    
    echo ""
    # 等待用户按任意键，然后循环回到开头
    read -n 1 -s -r -p "按任意键返回菜单..."
done
EOF

chmod +x /usr/local/bin/ddns

# 5. 静默检查并安装 cron 服务 (不输出杂乱信息)
if ! command -v crontab &> /dev/null; then
    if command -v apt &> /dev/null; then
        apt update >/dev/null 2>&1 && apt install -y cron >/dev/null 2>&1
        systemctl enable cron >/dev/null 2>&1 && systemctl start cron >/dev/null 2>&1
    elif command -v yum &> /dev/null; then
        yum install -y cronie >/dev/null 2>&1
        systemctl enable crond >/dev/null 2>&1 && systemctl start crond >/dev/null 2>&1
    elif command -v apk &> /dev/null; then
        apk add cronie >/dev/null 2>&1
        rc-update add crond >/dev/null 2>&1 && rc-service crond start >/dev/null 2>&1
    fi
fi

# 6. 配置定时任务 (Cron)
crontab -l 2>/dev/null | grep -v '/usr/local/bin/cf-update.sh' > /tmp/current_cron
echo "@reboot sleep 60 && /usr/local/bin/cf-update.sh" >> /tmp/current_cron
echo "0 */3 * * * /usr/local/bin/cf-update.sh" >> /tmp/current_cron
crontab /tmp/current_cron
rm -f /tmp/current_cron

# 7. 如果之前有缓存，说明是二次执行，直接在后台静默跑一次更新
if [ -f "/var/tmp/cf_ddns_cache.txt" ]; then
    /usr/local/bin/cf-update.sh -f >/dev/null 2>&1
fi

echo "==========================================="
echo " 安装完成！现在你可以直接输入 ddns 来管理了。"
echo "==========================================="
