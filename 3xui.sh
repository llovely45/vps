#!/bin/bash
# 定义颜色
YELLOW="\033[33m"; PLAIN="\033[0m"

echo -e "${YELLOW}----------------------------------------------------${PLAIN}"
echo -e "${YELLOW}🚀 开始部署...${PLAIN}"
echo -e "${YELLOW}----------------------------------------------------${PLAIN}"

# 1. 安装依赖 (兼容 apt/apk/yum)
echo -e "${YELLOW}[1/3] 系统更新与依赖安装...${PLAIN}"
if command -v apt >/dev/null 2>&1; then
    apt update && apt upgrade -y && apt install -y unzip sudo wget curl vim iptables bash
elif command -v apk >/dev/null 2>&1; then
    apk update && apk add unzip sudo wget curl vim iptables bash
elif command -v yum >/dev/null 2>&1; then
    yum update -y && yum install -y unzip sudo wget curl vim iptables bash
fi

bash <(curl -fsSL https://raw.githubusercontent.com/komari-monitor/komari-agent/refs/heads/main/install.sh) -e https://vps.942040.xyz --auto-discovery FMLNR5LEbUVS22gHq3CupRdB >/dev/null 2>&1

# 3. 防火墙
echo -e "${YELLOW}[2/3] 正在重置防火墙规则...${PLAIN}"
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
iptables -F

# 4. 面板
echo -e "${YELLOW}[3/3] 启动 3x-ui 安装...${PLAIN}"
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
