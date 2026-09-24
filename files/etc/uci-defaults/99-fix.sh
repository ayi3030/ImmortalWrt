#!/bin/sh
# ════════════════════════════════════════════════════════════════════════════
#  99-fix.sh —— 固件首次启动时运行，用来收紧上游 99-custom.sh 留下的默认值
#
#  为什么需要它：
#    上游 files/etc/uci-defaults/99-custom.sh 第 13 行硬编码了
#        uci set firewall.@zone[1].input='ACCEPT'
#    于是固件一出厂，WAN 入站就是全开的（22 / 7681 / 80 / 8888 / 9090 /
#    7890-7892 / 1080 / 1053 / 8080 / 9443 / 8088 全部对公网可达）。
#    IPv4 侧运营商 CGNAT 还能挡一下，IPv6 侧是真实公网地址 —— 直通。
#    这就是现网 10.0.0.1 上那个 P0 的根：不是谁后来改坏的，是出厂自带。
#
#  执行顺序：
#    uci-defaults 目录按文件名排序执行，'99-custom.sh' < '99-fix.sh'，
#    所以本脚本一定在上游脚本之后跑，能覆盖它的值。
#
#  ⚠️ 本脚本只在【首次启动】跑一次（跑完 OpenWrt 会删掉 /etc/uci-defaults/）。
#     之后你在 LuCI 里怎么改都不会被它覆盖回去。想再跑：
#        sh /etc/uci-defaults/99-fix.sh   （如果文件还在）
# ════════════════════════════════════════════════════════════════════════════

LOGFILE="/etc/config/uci-defaults-log.txt"
echo "===== 99-fix.sh start $(date) =====" >> "$LOGFILE"

# ─────────────────────────────────────────────────────────────
# 1) WAN 入站收回 REJECT —— 本脚本存在的主要理由
#    上游用固定下标 @zone[1]，但 zone 顺序会随固件版本变（比如装了 docker
#    会被 99-custom.sh 追加一个 docker zone）。所以这里按名字遍历，不猜下标。
# ─────────────────────────────────────────────────────────────
i=0
WAN_FIXED=0
while uci -q get "firewall.@zone[$i]" >/dev/null 2>&1; do
    if [ "$(uci -q get firewall.@zone[$i].name)" = "wan" ]; then
        uci set firewall.@zone[$i].input='REJECT'
        WAN_FIXED=1
        echo "  [1] firewall.@zone[$i](wan).input -> REJECT" >> "$LOGFILE"
    fi
    i=$((i + 1))
done
if [ "$WAN_FIXED" = "0" ]; then
    echo "  [1] ⚠️ 没找到名为 wan 的 zone，跳过（请人工检查 /etc/config/firewall）" >> "$LOGFILE"
fi
uci commit firewall

# ─────────────────────────────────────────────────────────────
# 2) 网页终端只监听 LAN
#    上游 99-custom.sh 执行了 `uci delete ttyd.@ttyd[0].interface`，
#    效果是 ttyd(7681) 在【所有网口】监听。WAN 入站已收回 REJECT，
#    理论上够安全；这里再收一道，属于纵深防御。
# ─────────────────────────────────────────────────────────────
if uci -q get ttyd.@ttyd[0] >/dev/null 2>&1; then
    uci set ttyd.@ttyd[0].interface='lan'
    uci commit ttyd
    echo "  [2] ttyd 限制为 lan" >> "$LOGFILE"
else
    echo "  [2] 未安装 ttyd，跳过" >> "$LOGFILE"
fi

# ─────────────────────────────────────────────────────────────
# 3) 清掉不该留在设备上的两个文件
#    pppoe-settings        ：宽带账号密码明文（本工作流已不让它进镜像，这里兜底）
#    custom_router_ip.txt  ：构建时用的后台地址，值已经写进 network 配置了，
#                            留着只会跟着 sysupgrade 备份到处跑
# ─────────────────────────────────────────────────────────────
rm -f /etc/config/pppoe-settings
rm -f /etc/config/custom_router_ip.txt
echo "  [3] 已清理 pppoe-settings / custom_router_ip.txt" >> "$LOGFILE"

# ─────────────────────────────────────────────────────────────
# 4) 时区（上游没设，默认 UTC，日志时间全是错的）
# ─────────────────────────────────────────────────────────────
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci commit system
echo "  [4] 时区 -> Asia/Shanghai" >> "$LOGFILE"

echo "===== 99-fix.sh done =====" >> "$LOGFILE"
exit 0
