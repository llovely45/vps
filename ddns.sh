#!/bin/bash

# 检查是否以 root 权限运行
if [ "$(id -u)" != "0" ]; then
   echo "请使用 root 权限运行此脚本 (例如: sudo bash install-ddns.sh)" 1>&2
   exit 1
fi

echo "========================="
echo "   DDNS 自动安装配置"
echo "========================="
echo ""

# 1. 交互式获取核心配置
read -p "请输入API: " CF_API_TOKEN
read -p "请输入Zone: " ZONE_ID
read -p "请输入需要绑定的域名: " DOMAIN_NAME

# 2. 自动查询 Record ID
echo ""
echo "正在自动获取 $DOMAIN_NAME 的 Record ID..."
API_RESPONSE=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=${DOMAIN_NAME}&type=A" \
     -H "Authorization: Bearer ${CF_API_TOKEN}" \
     -H "Content-Type: application/json")

# 提取纯文本 JSON 中的 id 字段
RECORD_ID=$(echo "$API_RESPONSE" | grep -o '"id":"[^"]*' | head -n 1 | cut -d'"' -f4)

if [ -z "$RECORD_ID" ]; then
    echo "自动获取失败！请确保你已提前添加了该域名的 A 记录。"
    read -p "请手动输入 Record ID: " RECORD_ID
else
    echo "成功获取 Record ID: $RECORD_ID"
fi

echo ""
echo "正在生成脚本和定时任务..."

# 3. 生成核心更新脚本 (cf-update.sh)
cat << EOF > /usr/local/bin/cf-update.sh
#!/bin/bash
CF_API_TOKEN="${CF_API_TOKEN}"
ZONE_ID="${ZONE_ID}"
RECORD_ID="${RECORD_ID}"
DOMAIN_NAME="${DOMAIN_NAME}"
CACHE_FILE="/var/tmp/cf_ddns_cache.txt"

FORCE_UPDATE=\$1
CURRENT_IP=\$(curl -s http://ip-api.com/line/?fields=query)

if [ -z "\$CURRENT_IP" ]; then
    echo "无法获取当前 IP，退出。"
    exit 1
fi

CACHED_IP=\$(cat "\$CACHE_FILE" 2>/dev/null)

if [ "\$CURRENT_IP" != "\$CACHED_IP" ] || [ "\$FORCE_UPDATE" == "-f" ]; then
    echo "检测到需要更新，正在将 IP 更新为 \$CURRENT_IP ..."
    # 注意：开启 proxied 时，ttl 必须设置为 1 (自动)
    RESPONSE=\$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/\$ZONE_ID/dns_records/\$RECORD_ID" \\
         -H "Authorization: Bearer \$CF_API_TOKEN" \\
         -H "Content-Type: application/json" \\
         --data "{\"type\":\"A\",\"name\":\"\$DOMAIN_NAME\",\"content\":\"\$CURRENT_IP\",\"ttl\":1,\"proxied\":true}")

    if echo "\$RESPONSE" | grep -q '"success":true'; then
        echo "\$CURRENT_IP" > "\$CACHE_FILE"
        echo "IP 更新成功！代理已开启。"
    else
        echo "更新失败，Cloudflare 返回：\$RESPONSE"
    fi
else
    if [ "\$FORCE_UPDATE" == "-f" ]; then
        echo "IP 未改变，无需更新。"
    fi
fi
EOF

chmod +x /usr/local/bin/cf-update.sh

# 4. 生成交互式命令面板 (ddns)
cat << EOF > /usr/local/bin/ddns
#!/bin/bash
DOMAIN_NAME="${DOMAIN_NAME}"
CACHE_FILE="/var/tmp/cf_ddns_cache.txt"

echo "正在获取信息，请稍候..."
CURRENT_IP=\$(curl -s --connect-timeout 5 http://ip-api.com/line/?fields=query || echo "获取失败")
CACHED_IP=\$(cat "\$CACHE_FILE" 2>/dev/null || echo "暂无缓存")

echo ""
echo "================ DDNS 状态 ================"
echo " 绑定域名   : \$DOMAIN_NAME"
echo " 缓存 IP    : \$CACHED_IP"
echo " 当前 IP    : \$CURRENT_IP"
echo " 代理状态   : 已开启"
echo "==========================================="
echo " 1. 强制更新 IP 到 域名"
echo " 2. 查询当前域名的 Record ID"
echo " 3. 彻底卸载 DDNS 脚本及定时任务"
echo " 0. 退出"
echo "==========================================="
read -p "请输入选项 [0-3]: " choice

case \$choice in
    1)
        /usr/local/bin/cf-update.sh -f
        ;;
    2)
        echo "正在查询 \$DOMAIN_NAME 的 Record ID..."
        RES=\$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?name=\$DOMAIN_NAME&type=A" \\
             -H "Authorization: Bearer ${CF_API_TOKEN}" \\
             -H "Content-Type: application/json")
        REC_ID=\$(echo "\$RES" | grep -o '"id":"[^"]*' | head -n 1 | cut -d'"' -f4)
        if [ -n "\$REC_ID" ]; then
            echo "查询成功！当前域名的 Record ID 为: \$REC_ID"
        else
            echo "查询失败，请检查域名是否在存在 A 记录。"
        fi
        ;;
    3)
        read -p "确定要彻底卸载并清理配置吗？(y/N): " confirm
        if [[ "\$confirm" == [yY] || "\$confirm" == [yY][eE][sS] ]]; then
            echo "正在清理定时任务..."
            crontab -l 2>/dev/null | grep -v '/usr/local/bin/cf-update.sh' | crontab -
            echo "正在删除脚本文件..."
            rm -f /usr/local/bin/cf-update.sh
            rm -f /usr/local/bin/ddns
            rm -f \$CACHE_FILE
            echo "卸载完成！"
        else
            echo "已取消卸载。"
        fi
        ;;
    0)
        exit 0
        ;;
    *)
        echo "无效选项。"
        ;;
esac
EOF

chmod +x /usr/local/bin/ddns

# 5. 配置定时任务 (Cron)
crontab -l 2>/dev/null | grep -v '/usr/local/bin/cf-update.sh' > /tmp/current_cron
echo "@reboot sleep 60 && /usr/local/bin/cf-update.sh" >> /tmp/current_cron
echo "0 */3 * * * /usr/local/bin/cf-update.sh" >> /tmp/current_cron
crontab /tmp/current_cron
rm -f /tmp/current_cron

echo "==========================================="
echo " 安装完成！现在你可以直接输入 ddns 来管理了。"
echo "==========================================="
