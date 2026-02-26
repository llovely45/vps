> 这是我自己在 VPS / Linux 服务器上用的一个小脚本集合，仅用于**个人自用**。
> 不保证通用性、不保证兼容所有系统环境，也不提供任何形式的售后/技术支持。

---

# 一句话说明

用于我自己日常初始化/维护 VPS 的脚本（可能包含安装依赖、环境配置、常用工具、服务管理等操作）。
脚本内容会根据我自己的需求随时修改，可能会出现**破坏性变更**。

---

# 使用方式

**在线执行：**
3xui
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/llovely45/vps/refs/heads/main/3xui.sh)
```
ddns
```bash
bash <(curl -sL https://raw.githubusercontent.com/llovely45/vps/refs/heads/main/ddns.sh)
```

如果你的系统没有 curl，可以先装：

**Debian/Ubuntu：**

```bash
apt update && apt install -y curl
```

**CentOS/RHEL：**

```bash
yum install -y curl
```

**Alpine：**

```bash
apk add curl
```

# 重要提醒（必读）

纯自用：只保证我自己的环境能跑，不保证你能跑。

运行前请先看脚本内容：不要在不了解脚本做什么的情况下直接执行。

可能包含：

- 修改系统配置（如 sysctl、limits、ssh、swap、iptables 等）
- 安装/卸载软件包、拉取镜像、写入配置文件
- 重启服务/系统等操作

建议在 **干净机器 / 快照可回滚** 的环境里测试。

**你运行即代表你已理解并愿意自行承担风险。**

# 支持的系统（不保证）

- 理论上偏向常见 Linux 发行版（例如 Debian/Ubuntu/CentOS/Alpine 等），但实际以脚本内容为准。
- 有些功能可能需要 root 权限。

# 免责声明

本仓库脚本按 “现状（AS IS）” 提供。
因使用脚本导致的任何数据丢失、服务中断、费用损失等问题，作者不承担任何责任。

# License

不做开源承诺；仅作个人备份与自用。
如需复用，请自行评估风险并遵守相关法律法规。
