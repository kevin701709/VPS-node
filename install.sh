#!/usr/bin/env bash
# =====================================================================
#  xa-menu : VLESS + XHTTP + Reality + Encryption (Xray)  +  AnyTLS / Hysteria2 / VLESS-WS-TLS (sing-box)
#  功能: Argo 隧道 / BBR 开关 / 脚本自更新(可回滚) / 每周自动升级内核(pre-release, 失败回滚) / 自定义 UUID / WARP 模式(关闭|全局|分流) / 端口与SNI / 节点链接
#  系统: Debian / Ubuntu / CentOS / Rocky / Alma (systemd, amd64/arm64)
#
#  一键安装:
#    bash <(curl -fsSL https://raw.githubusercontent.com/kevin701709/VPS-node/main/install.sh)
#  安装后直接输入:  kv   (快捷管理命令)
# =====================================================================
set -u

# 上传 GitHub 后改成你自己的地址(用于把脚本保存为 kv 命令)
SCRIPT_URL="https://raw.githubusercontent.com/kevin701709/VPS-node/main/install.sh"
SCRIPT_VERSION="2026.11.11"

BASE=/etc/xa-menu
STATE=$BASE/state.env
XRAY_BIN=/usr/local/bin/xray
SB_BIN=/usr/local/bin/sing-box
XRAY_CFG=$BASE/xray.json
SB_CFG=$BASE/sing-box.json
CERT=$BASE/anytls.crt
KEY=$BASE/anytls.key
SELF=/usr/local/bin/kv
KV_BACKUPS=$BASE/kv-backups
CF_BIN=/usr/local/bin/cloudflared
BBR_CONF=/etc/sysctl.d/99-xa-bbr.conf
ARGO_SINCE="10 minutes ago"

# WARP "分流"模式走 WARP 的域名(后缀匹配),可自行增删
SPLIT_DOMAINS=(
  openai.com chatgpt.com oaistatic.com oaiusercontent.com
  anthropic.com claude.ai
  netflix.com nflxvideo.net nflximg.net nflxext.com nflxso.net
  disneyplus.com disney-plus.net bamgrid.com dssott.com
  hulu.com
)

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; N=$'\e[0m'
info(){ echo -e "${G}[信息]${N} $*"; }
warn(){ echo -e "${Y}[警告]${N} $*"; }
err(){  echo -e "${R}[错误]${N} $*"; }

# ---------------------------------------------------------------- 基础
need_root(){ [[ $EUID -eq 0 ]] || { err "请使用 root 运行"; exit 1; }; }

check_env(){
  command -v systemctl >/dev/null || { err "需要 systemd"; exit 1; }
  case "$(uname -m)" in
    x86_64|amd64)  SB_ARCH=amd64; XR_ARCH=64 ;;
    aarch64|arm64) SB_ARCH=arm64; XR_ARCH=arm64-v8a ;;
    *) err "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}

# 小内存 VPS: apt 安装时容易被 OOM 杀掉(显示 Killed), 内存 <700MB 且没有 swap 时自动建 512MB swap
ensure_swap(){
  local mem_kb swap_kb avail_mb f=/swapfile-xa
  mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
  swap_kb=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
  (( mem_kb < 700000 && swap_kb == 0 )) || return 0
  avail_mb=$(df -Pm / | awk 'NR==2{print $4}')
  (( avail_mb > 1500 )) || { warn "内存仅 $((mem_kb/1024))MB 且磁盘空间不足,跳过创建 swap"; return 0; }
  warn "内存仅 $((mem_kb/1024))MB 且无 swap,创建 512MB swap 防止安装被系统杀掉..."
  if [[ ! -f $f ]]; then
    fallocate -l 512M "$f" 2>/dev/null || dd if=/dev/zero of="$f" bs=1M count=512 status=none
    chmod 600 "$f"; mkswap "$f" >/dev/null 2>&1
  fi
  if swapon "$f" 2>/dev/null; then
    grep -q "$f" /etc/fstab || echo "$f none swap sw 0 0" >>/etc/fstab
    info "swap 已启用"
  else
    warn "swap 启用失败(OpenVZ/LXC 等容器型 VPS 可能不支持),继续尝试安装"
    rm -f "$f"
  fi
}

# 逐个安装软件包, 某个失败不影响其他 (小内存机器一次装多个容易被 OOM 杀掉)
APT_UPDATED=0
pkg_install(){
  local c
  if command -v apt-get >/dev/null; then
    if [[ $APT_UPDATED == 0 ]]; then apt-get update -y >/dev/null 2>&1; APT_UPDATED=1; fi
    for c in "$@"; do
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$c" >/dev/null 2>&1 \
        || warn "$c 安装失败(内存不足被杀?)"
    done
  elif command -v dnf >/dev/null; then
    for c in "$@"; do dnf install -y "$c" >/dev/null 2>&1 || warn "$c 安装失败"; done
  elif command -v yum >/dev/null; then
    for c in "$@"; do yum install -y "$c" >/dev/null 2>&1 || warn "$c 安装失败"; done
  else
    warn "未识别的包管理器,请手动安装: $*"
  fi
}

# 脚本只硬性依赖 curl / openssl / tar。不再需要 jq (配置用 heredoc 生成) 和 unzip (按需解压, 见 unzip_to)
install_deps(){
  info "检查依赖..."
  ensure_swap
  local c missing=()
  for c in curl openssl tar; do command -v "$c" >/dev/null || missing+=("$c"); done
  if (( ${#missing[@]} )); then
    info "需要安装: ${missing[*]}"
    pkg_install "${missing[@]}"
  fi
  for c in curl openssl tar; do
    command -v "$c" >/dev/null || { err "依赖 $c 安装失败。可手动执行: apt-get install -y $c  然后重新运行脚本"; exit 1; }
  done
}

has_busybox_unzip(){ command -v busybox >/dev/null && busybox --list 2>/dev/null | grep -qx unzip; }

# 只解压 zip 里的单个文件(避免把 geoip/geosite 等大文件也解出来占磁盘/内存)
# 用法: unzip_to <zip> <目标目录> <zip内文件名>
# 解压工具优先级: unzip -> busybox unzip -> python3 -> 尝试安装 unzip
unzip_to(){
  local z=$1 d=$2 m=$3
  if ! command -v unzip >/dev/null && ! has_busybox_unzip && ! command -v python3 >/dev/null; then
    warn "没有可用的解压工具,尝试安装 unzip..."
    pkg_install unzip
  fi
  if command -v unzip >/dev/null; then
    unzip -qo "$z" "$m" -d "$d"
  elif has_busybox_unzip; then
    busybox unzip -qo "$z" "$m" -d "$d"
  elif command -v python3 >/dev/null; then
    python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extract(sys.argv[2], sys.argv[3])' "$z" "$m" "$d"
  else
    err "找不到可用的解压工具(unzip / busybox / python3)"; return 1
  fi
  [[ -f $d/$m ]]
}

ask(){ local v; read -rp "$1" v </dev/tty; echo "${v:-${2:-}}"; }
rand_str(){ head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "${1:-16}"; }
valid_uuid(){ [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
valid_port(){ [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_domain(){ [[ $1 =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]; }

# 随机端口: 20001-32767(避开系统临时端口段 32768+),跳过已占用端口和 $1
rand_port(){
  local p i
  for i in $(seq 1 50); do
    p=$(shuf -i 20001-32767 -n1)
    [[ " $* " == *" $p "* ]] && continue
    ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}$" || { echo "$p"; return; }
  done
  echo $((20001 + RANDOM % 12767))
}

# 询问端口: ask_port <提示> <已被其他协议占用的端口(空格分隔)>
ask_port(){
  local dp v used=" ${2:-} "
  dp=$(rand_port ${2:-}); 
  while true; do
    v=$(ask "$1 [回车随机: $dp]: " "$dp")
    if valid_port "$v" && [[ $used != *" $v "* ]]; then echo "$v"; return; fi
    warn "端口无效或与其他协议端口冲突" >&2
  done
}

# Hysteria2 走 QUIC(UDP), 适当放大 UDP 缓冲区上限(只是上限, 不会预先占用内存)
tune_udp(){
  cat >/etc/sysctl.d/99-xa-udp.conf <<EOF
net.core.rmem_max=7500000
net.core.wmem_max=7500000
EOF
  sysctl --system >/dev/null 2>&1
}

get_ip(){
  SERVER_IP=$(curl -s4m5 https://api.ipify.org || curl -s4m5 https://ip.sb)
  [[ -z $SERVER_IP ]] && SERVER_IP=$(curl -s6m5 https://api64.ipify.org)
  [[ -z $SERVER_IP ]] && SERVER_IP="YOUR_SERVER_IP"
  return 0
}

bbr_avail(){ sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null; }
bbr_cc(){ sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null; }

bbr_status(){
  local cc qd av
  cc=$(bbr_cc); qd=$(sysctl -n net.core.default_qdisc 2>/dev/null); av=$(bbr_avail)
  echo "内核版本: $(uname -r)"
  echo "当前拥塞控制算法: ${cc:-未知}    默认队列: ${qd:-未知}"
  echo "内核可用算法: ${av:-未知}"
  if [[ $cc == bbr ]]; then echo -e "BBR: ${G}已启用${N}"; else echo -e "BBR: ${Y}未启用${N}"; fi
  if [[ -f $BBR_CONF ]]; then echo "开机自动启用: 是 ($BBR_CONF)"; else echo "开机自动启用: 否"; fi
}

bbr_enable(){
  modprobe tcp_bbr >/dev/null 2>&1
  local av; av=$(bbr_avail)
  if [[ " $av " != *" bbr "* ]]; then
    err "当前内核不支持 BBR (可用算法: ${av:-未知})。OpenVZ/LXC 容器或 4.9 以下的旧内核无法开启"
    return 1
  fi
  cat >"$BBR_CONF" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl -p "$BBR_CONF" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1
  if [[ $(bbr_cc) == bbr ]]; then info "BBR 已开启"; else warn "已写入配置但当前未生效(当前: $(bbr_cc)),可尝试重启系统"; fi
}

bbr_disable(){
  rm -f "$BBR_CONF"
  local av to=reno; av=$(bbr_avail)
  [[ " $av " == *" cubic "* ]] && to=cubic
  sysctl -w net.ipv4.tcp_congestion_control="$to" >/dev/null 2>&1
  info "已关闭 BBR, 拥塞控制回到 $to (默认队列 fq 保持不变, 无副作用)"
}

# 安装时调用: 静默尝试开启, 失败只提示
enable_bbr(){ bbr_enable >/dev/null 2>&1 || warn "BBR 未能开启(内核不支持?), 可稍后在菜单 12 查看"; }

menu_bbr(){
  bbr_status
  echo "1) 开启 BBR   2) 关闭 BBR   3) 仅查看状态"
  case "$(ask "请选择 [3]: " 3)" in
    1) bbr_enable; bbr_status ;;
    2) bbr_disable; bbr_status ;;
  esac
}

open_ports(){
  local p
  for p in "$@"; do
    if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
      ufw allow "$p"/tcp >/dev/null 2>&1; ufw allow "$p"/udp >/dev/null 2>&1
    fi
    if command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
      firewall-cmd --permanent --add-port="$p"/tcp >/dev/null 2>&1
      firewall-cmd --permanent --add-port="$p"/udp >/dev/null 2>&1
      firewall-cmd --reload >/dev/null 2>&1
    fi
  done
}

# ---------------------------------------------------------------- 状态
save_state(){
  mkdir -p "$BASE"
  cat >"$STATE" <<EOF
UUID='$UUID'
XHTTP_PORT='$XHTTP_PORT'
XHTTP_PATH='$XHTTP_PATH'
REALITY_SNI='$REALITY_SNI'
REALITY_PRIV='$REALITY_PRIV'
REALITY_PUB='$REALITY_PUB'
SHORT_ID='$SHORT_ID'
PROTO='$PROTO'
ENC_ON='$ENC_ON'
VLESS_DEC='$VLESS_DEC'
VLESS_ENC='$VLESS_ENC'
ANYTLS_PORT='$ANYTLS_PORT'
ANYTLS_PASS='$ANYTLS_PASS'
ANYTLS_SNI='$ANYTLS_SNI'
HY2_PORT='$HY2_PORT'
HY2_PASS='$HY2_PASS'
HY2_SNI='$HY2_SNI'
HY2_OBFS='$HY2_OBFS'
WS_PORT='$WS_PORT'
WS_PATH='$WS_PATH'
WS_DOMAIN='$WS_DOMAIN'
WS_CERT_MODE='$WS_CERT_MODE'
WS_CERT='$WS_CERT'
WS_KEY='$WS_KEY'
WS_EMAIL='$WS_EMAIL'
ARGO_MODE='$ARGO_MODE'
ARGO_PORT='$ARGO_PORT'
ARGO_PATH='$ARGO_PATH'
ARGO_DOMAIN='$ARGO_DOMAIN'
ARGO_TOKEN='$ARGO_TOKEN'
ARGO_PROTO='$ARGO_PROTO'
WARP_MODE='$WARP_MODE'
WARP_PRIV='$WARP_PRIV'
WARP_PUB='$WARP_PUB'
WARP_V4='$WARP_V4'
WARP_V6='$WARP_V6'
WARP_RESERVED='$WARP_RESERVED'
EOF
  chmod 600 "$STATE"
}

load_state(){
  UUID=; XHTTP_PORT=; XHTTP_PATH=; REALITY_SNI=; REALITY_PRIV=; REALITY_PUB=; SHORT_ID=
  PROTO=both; ENC_ON=0; VLESS_DEC=; VLESS_ENC=
  ANYTLS_PORT=; ANYTLS_PASS=; ANYTLS_SNI=; HY2_PORT=; HY2_PASS=; HY2_SNI=; HY2_OBFS=; WS_PORT=; WS_PATH=; WS_DOMAIN=; WS_CERT_MODE=acme; WS_CERT=; WS_KEY=; WS_EMAIL=; ARGO_MODE=quick; ARGO_PORT=; ARGO_PATH=; ARGO_DOMAIN=; ARGO_TOKEN=; ARGO_PROTO=http2; WARP_MODE=off; WARP_PRIV=; WARP_PUB=
  WARP_V4=; WARP_V6=; WARP_RESERVED=
  # shellcheck disable=SC1090
  [[ -f $STATE ]] && source "$STATE"
  # 兼容旧版: both = vless + anytls
  [[ ${PROTO:-} == both || -z ${PROTO:-} ]] && PROTO="vless,anytls"
}

# PROTO 是逗号分隔的协议集合: vless(Xray) / anytls / hy2 / ws(均为 sing-box), 例如 "vless,anytls,hy2,ws"
# anytls、hy2、ws 共用同一个 sing-box 进程
has_p(){ [[ ",${PROTO:-}," == *",$1,"* ]]; }
has_vless(){  has_p vless; }
has_anytls(){ has_p anytls; }
has_hy2(){    has_p hy2; }
has_ws(){     has_p ws; }
has_selfcert(){ has_anytls || has_hy2; }   # AnyTLS / Hysteria2 使用本机生成的自签证书
has_argo(){   has_p argo; }
has_sb(){     has_anytls || has_hy2 || has_ws || has_argo; }
svc_list(){ has_vless && echo xa-xray; has_sb && echo xa-singbox; has_argo && echo xa-argo; }

installed(){
  [[ -f $STATE ]] || return 1
  if has_vless;  then [[ -x $XRAY_BIN ]] || return 1; fi
  if has_sb;     then [[ -x $SB_BIN ]]   || return 1; fi
  return 0
}
need_installed(){ installed || { err "尚未安装,请先选择 1 安装"; return 1; }; }

# ---------------------------------------------------------------- 内核
log(){ echo "[$(date '+%F %T')] $*"; }
ver_base(){ local v=${1#v}; echo "${v%%[-+]*}"; }

# 取最新发布的 tag (含 pre-release): 优先用 releases.atom 订阅源(不限流), 失败再用 GitHub API
# 在最近 15 个发布里挑 "版本号最高" 的; 版本号相同则取发布时间最新的 (避免老分支补丁版被当成最新)
latest_tag(){
  local repo=$1 tags t
  tags=$(curl -fsSL "https://github.com/${repo}/releases.atom" 2>/dev/null \
         | grep -oE '/releases/tag/v[0-9][0-9A-Za-z._-]*' | sed 's#.*/tag/##' | awk '!s[$0]++' | head -n 15)
  [[ -z $tags ]] && tags=$(curl -fsSL "https://api.github.com/repos/${repo}/releases?per_page=15" 2>/dev/null \
         | grep -oE '"tag_name": *"v[^"]+"' | cut -d'"' -f4 | head -n 15)
  [[ -z $tags ]] && return 1
  while read -r t; do echo "$(ver_base "$t") $t"; done <<<"$tags" | sort -s -k1,1Vr | head -n1 | awk '{print $2}'
}

# 临时目录放在磁盘(/var/tmp), 不用 /tmp: 新系统的 /tmp 是内存盘, 小内存机器会被撑爆
mk_tmp(){ mkdir -p /var/tmp; mktemp -d -p /var/tmp xa.XXXXXX; }

install_xray(){
  info "下载 Xray-core (最新版, 含 pre-release)..."
  local tmp tag url; tmp=$(mk_tmp)
  tag=$(latest_tag XTLS/Xray-core)
  if [[ -n $tag ]]; then
    info "Xray 目标版本: $tag"
    url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${XR_ARCH}.zip"
  else
    warn "获取最新版本号失败,回退到稳定版 latest(版本可能较旧)"
    url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XR_ARCH}.zip"
  fi
  curl -fsSL -o "$tmp/x.zip" "$url" || { err "Xray 下载失败: $url"; rm -rf "$tmp"; return 1; }
  unzip_to "$tmp/x.zip" "$tmp" xray || { err "Xray 解压失败"; rm -rf "$tmp"; return 1; }
  install -m755 "$tmp/xray" "$XRAY_BIN"
  rm -rf "$tmp"
  "$XRAY_BIN" version | head -n1
}

install_singbox(){
  info "下载 sing-box (最新版, 含 pre-release)..."
  local tmp tag ver; tmp=$(mk_tmp)
  tag=$(latest_tag SagerNet/sing-box)
  [[ -z $tag ]] && { err "获取 sing-box 版本失败(GitHub 访问受限?)"; rm -rf "$tmp"; return 1; }
  ver=${tag#v}
  info "sing-box 目标版本: $tag"
  curl -fsSL -o "$tmp/sb.tgz" "https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${ver}-linux-${SB_ARCH}.tar.gz" \
    || { err "sing-box 下载失败"; rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/sb.tgz" -C "$tmp" && install -m755 "$tmp"/sing-box-*/sing-box "$SB_BIN"
  rm -rf "$tmp"
  "$SB_BIN" version | head -n1
}

# ---- 自动升级 ----
core_ver(){
  case $1 in
    xray)    "$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}' ;;
    singbox) "$SB_BIN" version 2>/dev/null | awk 'NR==1{print $3}' ;;
  esac
}

# 升级单个内核: 先用新内核校验现有配置, 升级后服务起不来则自动回滚
upgrade_core(){
  local name=$1 repo bin svc tag new cur tmp url nb=""
  if [[ $name == xray ]]; then repo=XTLS/Xray-core; bin=$XRAY_BIN; svc=xa-xray
  else repo=SagerNet/sing-box; bin=$SB_BIN; svc=xa-singbox; fi

  tag=$(latest_tag "$repo")
  [[ -n $tag ]] || { log "$name: 获取最新版本失败,跳过"; return 1; }
  new=${tag#v}; cur=$(core_ver "$name")
  if [[ $new == "$cur" ]]; then log "$name 已是最新: $cur"; return 0; fi
  if [[ -n $cur && $(printf '%s\n%s\n' "$(ver_base "$cur")" "$(ver_base "$new")" | sort -V | tail -n1) != "$(ver_base "$new")" ]]; then
    log "$name 当前 $cur 高于 $new,不降级"; return 0
  fi
  log "$name: ${cur:-未知} -> $new"

  tmp=$(mk_tmp)
  if [[ $name == xray ]]; then
    url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${XR_ARCH}.zip"
    curl -fsSL -o "$tmp/p.zip" "$url" && unzip_to "$tmp/p.zip" "$tmp" xray && nb="$tmp/xray"
  else
    url="https://github.com/SagerNet/sing-box/releases/download/${tag}/sing-box-${new}-linux-${SB_ARCH}.tar.gz"
    curl -fsSL -o "$tmp/p.tgz" "$url" && tar -xzf "$tmp/p.tgz" -C "$tmp" && nb=$(ls "$tmp"/sing-box-*/sing-box 2>/dev/null | head -n1)
  fi
  [[ -n $nb && -f $nb ]] || { log "$name 下载/解压失败: $url"; rm -rf "$tmp"; return 1; }
  chmod +x "$nb"

  # 先按当前状态重新生成一次配置(用最新的模板, 例如补上新版内核需要的选项), 再让新内核校验
  if [[ $name == xray ]]; then write_xray; else write_singbox; fi
  if [[ $name == xray ]]; then "$nb" run -test -c "$XRAY_CFG" >/dev/null 2>&1
  else "$nb" check -c "$SB_CFG" >/dev/null 2>&1; fi \
    || { log "$name 新版本无法通过现有配置校验,保留旧版本"; rm -rf "$tmp"; return 1; }

  cp -f "$bin" "$bin.bak"
  install -m755 "$nb" "$bin"; rm -rf "$tmp"
  systemctl restart "$svc"; sleep 3
  if systemctl is-active --quiet "$svc"; then log "$name 升级成功: $new"; return 0; fi
  log "$name 升级后服务未运行,回滚到 ${cur:-旧版本}"
  install -m755 "$bin.bak" "$bin"; systemctl restart "$svc"
  return 1
}

auto_update(){
  installed || { log "尚未安装,跳过"; return 0; }
  local rc=0
  has_vless  && { upgrade_core xray    || rc=1; }
  has_sb     && { upgrade_core singbox || rc=1; }
  return $rc
}

enable_autoupdate(){
  [[ -x /usr/local/bin/kv ]] || install_self
  [[ -x /usr/local/bin/kv ]] || { err "没有 kv 命令,无法开启自动升级(先生成 kv)"; return 1; }
  cat >/etc/systemd/system/xa-update.service <<EOF
[Unit]
Description=xa-menu auto update (Xray / sing-box, latest pre-release)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/kv autoupdate
EOF
  cat >/etc/systemd/system/xa-update.timer <<EOF
[Unit]
Description=Weekly xa-menu core auto update

[Timer]
OnCalendar=Sun *-*-* 04:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now xa-update.timer >/dev/null 2>&1
  info "已开启每周自动升级(每周日 04:00 左右,升级到最新 pre-release,失败自动回滚)"
}

disable_autoupdate(){
  systemctl disable --now xa-update.timer >/dev/null 2>&1
  info "已关闭自动升级"
}

menu_auto(){
  need_installed || return
  local st="关闭"
  systemctl is-enabled --quiet xa-update.timer 2>/dev/null && st="开启"
  echo "每周自动升级: $st  (每周日 04:00 左右, 升级 Xray / sing-box 到最新 pre-release, 失败自动回滚)"
  [[ $st == 开启 ]] && systemctl list-timers xa-update.timer --no-pager 2>/dev/null | head -n 3
  echo "1) 开启   2) 关闭   3) 立即检查并升级一次   4) 查看升级日志"
  case "$(ask "请选择: ")" in
    1) enable_autoupdate ;;
    2) disable_autoupdate ;;
    3) auto_update ;;
    4) journalctl -u xa-update -n 40 --no-pager ;;
  esac
}

gen_reality(){
  local out; out=$("$XRAY_BIN" x25519)
  REALITY_PRIV=$(echo "$out" | awk -F': *' '/[Pp]rivate/{print $2; exit}')
  REALITY_PUB=$(echo "$out"  | awk -F': *' '/[Pp]ublic/{print $2; exit}')
  [[ -n $REALITY_PRIV && -n $REALITY_PUB ]] || { err "生成 Reality 密钥失败"; return 1; }
}

# VLESS Encryption (ML-KEM / X25519 混合, 需要 Xray >= 25.x 的 vlessenc 命令)
gen_enc(){
  local out
  out=$("$XRAY_BIN" vlessenc 2>/dev/null) || { err "当前 Xray 不支持 vlessenc,请先菜单 7 更新内核"; return 1; }
  # 输出里第一组为 X25519(链接较短),第二组为 ML-KEM-768(后量子,链接很长),这里取第一组
  VLESS_DEC=$(echo "$out" | grep '"decryption"' | head -n1 | cut -d'"' -f4)
  VLESS_ENC=$(echo "$out" | grep '"encryption"' | head -n1 | cut -d'"' -f4)
  [[ -n $VLESS_DEC && -n $VLESS_ENC ]] || { err "解析 vlessenc 输出失败:"; echo "$out"; return 1; }
}

gen_cert(){
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -keyout "$KEY" -out "$CERT" -subj "/CN=${ANYTLS_SNI:-${HY2_SNI:-www.bing.com}}" >/dev/null 2>&1
  chmod 600 "$KEY"
}

# ---------------------------------------------------------------- WARP
warp_register(){
  info "向 Cloudflare 注册 WARP 账号..."
  local tmp priv pub resp cid
  tmp=$(mktemp)
  openssl genpkey -algorithm X25519 -outform DER -out "$tmp" 2>/dev/null || { err "openssl 不支持 X25519"; rm -f "$tmp"; return 1; }
  priv=$(tail -c 32 "$tmp" | base64)
  pub=$(openssl pkey -inform DER -in "$tmp" -pubout -outform DER 2>/dev/null | tail -c 32 | base64)
  rm -f "$tmp"
  resp=$(curl -fsS --max-time 20 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
    -H "Content-Type: application/json" -H "User-Agent: okhttp/3.12.1" -H "CF-Client-Version: a-6.10-2158" \
    -d "{\"key\":\"${pub}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"model\":\"PC\",\"serial_number\":\"\",\"locale\":\"en_US\"}" 2>/dev/null)
  [[ -z $resp ]] && { err "WARP 注册请求失败(IP 可能被限制,可用手动导入)"; return 1; }
  # 不用 jq: 先压成一行, 再用 grep 取字段
  #   v4/v6: 接口地址 (peers.endpoint 里的 v4 带 ":端口", v6 带 "[", 不会被下面的正则匹配到)
  resp=$(printf '%s' "$resp" | tr -d '\n\r ')
  cid=$(printf '%s' "$resp"      | grep -oE '"client_id":"[^"]*"'      | head -n1 | cut -d'"' -f4)
  WARP_V4=$(printf '%s' "$resp"  | grep -oE '"v4":"[0-9.]+"'           | head -n1 | cut -d'"' -f4)
  WARP_V6=$(printf '%s' "$resp"  | grep -oE '"v6":"[0-9a-fA-F:]+"'     | head -n1 | cut -d'"' -f4)
  WARP_PUB=$(printf '%s' "$resp" | grep -oE '"public_key":"[^"]*"'     | head -n1 | cut -d'"' -f4)
  [[ -z $WARP_PUB ]] && WARP_PUB="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
  if [[ -z $cid || -z $WARP_V4 || -z $WARP_V6 ]]; then err "WARP 注册响应异常"; return 1; fi
  WARP_RESERVED=$(printf '%s' "$cid" | base64 -d 2>/dev/null | od -An -tu1 | xargs | tr ' ' ',')
  WARP_PRIV=$priv
  info "WARP 注册成功: v4=$WARP_V4"
}

warp_manual(){
  WARP_PRIV=$(ask "WireGuard PrivateKey: ")
  WARP_V4=$(ask "Interface IPv4 (如 172.16.0.2): " "172.16.0.2")
  WARP_V6=$(ask "Interface IPv6 (如 2606:4700:...:xxxx): ")
  WARP_RESERVED=$(ask "Reserved (如 12,34,56): " "0,0,0")
  WARP_PUB=$(ask "Peer PublicKey (回车默认官方): " "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=")
  [[ -n $WARP_PRIV && -n $WARP_V6 ]] || { err "参数不完整"; return 1; }
}

# ---------------------------------------------------------------- 配置生成
write_xray(){
  local dec=none warp_ob="" rules="" dom="" d
  [[ ${ENC_ON:-0} == 1 && -n $VLESS_DEC ]] && dec=$VLESS_DEC
  if [[ $WARP_MODE != off ]]; then
    # noKernelTun: 新版 Xray 的 wireguard 出站默认尝试内核 TUN(创建 wg0 网卡), 容器型 VPS(OpenVZ/LXC)
    # 或没有 NET_ADMIN 权限时会报 "failed to add address to wg0: operation not supported"。强制用用户态实现。
    warp_ob=$(cat <<EOF
,
    {"tag": "warp", "protocol": "wireguard", "settings": {
      "secretKey": "$WARP_PRIV",
      "address": ["$WARP_V4/32", "$WARP_V6/128"],
      "peers": [{"publicKey": "$WARP_PUB", "allowedIPs": ["0.0.0.0/0", "::/0"], "endpoint": "162.159.192.1:2408"}],
      "mtu": 1280, "reserved": [$WARP_RESERVED], "domainStrategy": "ForceIP",
      "noKernelTun": true}}
EOF
)
    if [[ $WARP_MODE == global ]]; then
      rules=',
    {"type": "field", "network": "tcp,udp", "outboundTag": "warp"}'
    else
      for d in "${SPLIT_DOMAINS[@]}"; do dom+="\"domain:$d\","; done
      dom=${dom%,}
      rules=",
    {\"type\": \"field\", \"domain\": [$dom], \"outboundTag\": \"warp\"}"
    fi
  fi
  cat >"$XRAY_CFG" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "vless-xhttp-reality",
    "listen": "0.0.0.0",
    "port": $XHTTP_PORT,
    "protocol": "vless",
    "settings": {"clients": [{"id": "$UUID"}], "decryption": "$dec"},
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "xhttpSettings": {"path": "$XHTTP_PATH", "mode": "auto"},
      "realitySettings": {
        "show": false,
        "dest": "$REALITY_SNI:443",
        "serverNames": ["$REALITY_SNI"],
        "privateKey": "$REALITY_PRIV",
        "shortIds": ["$SHORT_ID"]
      }
    },
    "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}
  }],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom"},
    {"tag": "block", "protocol": "blackhole"}$warp_ob
  ],
  "routing": {"domainStrategy": "AsIs", "rules": [
    {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"}$rules
  ]}
}
EOF
}

write_singbox(){
  local ep="[]" rules='{"action": "sniff"}' final="direct" sdom="" d inbounds="" obfs=""
  if [[ $WARP_MODE != off ]]; then
    ep=$(cat <<EOF
[{"type": "wireguard", "tag": "warp", "system": false,
    "address": ["$WARP_V4/32", "$WARP_V6/128"],
    "private_key": "$WARP_PRIV", "mtu": 1280,
    "peers": [{"address": "162.159.192.1", "port": 2408, "public_key": "$WARP_PUB",
      "allowed_ips": ["0.0.0.0/0", "::/0"], "reserved": [$WARP_RESERVED]}]}]
EOF
)
    if [[ $WARP_MODE == global ]]; then
      final="warp"
    else
      for d in "${SPLIT_DOMAINS[@]}"; do sdom+="\"$d\","; done
      sdom=${sdom%,}
      rules+=", {\"domain_suffix\": [$sdom], \"action\": \"route\", \"outbound\": \"warp\"}"
    fi
  fi
  if has_anytls; then
    inbounds=$(cat <<EOF
{"type": "anytls", "tag": "anytls-in", "listen": "::", "listen_port": $ANYTLS_PORT,
    "users": [{"name": "xa", "password": "$ANYTLS_PASS"}],
    "tls": {"enabled": true, "server_name": "$ANYTLS_SNI", "certificate_path": "$CERT", "key_path": "$KEY"}}
EOF
)
  fi
  if has_hy2; then
    [[ -n $HY2_OBFS ]] && obfs="\"obfs\": {\"type\": \"salamander\", \"password\": \"$HY2_OBFS\"},"
    [[ -n $inbounds ]] && inbounds+=",
  "
    inbounds+=$(cat <<EOF
{"type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": $HY2_PORT,
    "users": [{"name": "xa", "password": "$HY2_PASS"}],
    $obfs
    "tls": {"enabled": true, "alpn": ["h3"], "server_name": "$HY2_SNI", "certificate_path": "$CERT", "key_path": "$KEY"}}
EOF
)
  fi
  if has_ws; then
    local tlsjson em=""
    if [[ $WS_CERT_MODE == file ]]; then
      tlsjson="{\"enabled\": true, \"server_name\": \"$WS_DOMAIN\", \"certificate_path\": \"$WS_CERT\", \"key_path\": \"$WS_KEY\"}"
    else
      # sing-box >= 1.14 使用 certificate_provider(旧的内联 tls.acme 已废弃); 只启用 HTTP-01 验证(需要 80 端口)
      [[ -n $WS_EMAIL ]] && em="\"email\": \"$WS_EMAIL\", "
      tlsjson="{\"enabled\": true, \"server_name\": \"$WS_DOMAIN\", \"certificate_provider\": {\"type\": \"acme\", \"domain\": [\"$WS_DOMAIN\"], ${em}\"data_directory\": \"$BASE/acme\", \"provider\": \"letsencrypt\", \"disable_tls_alpn_challenge\": true}}"
    fi
    [[ -n $inbounds ]] && inbounds+=",
  "
    inbounds+=$(cat <<EOF
{"type": "vless", "tag": "ws-in", "listen": "::", "listen_port": $WS_PORT,
    "users": [{"name": "xa", "uuid": "$UUID"}],
    "tls": $tlsjson,
    "transport": {"type": "ws", "path": "$WS_PATH"}}
EOF
)
  fi
  if has_argo; then
    [[ -n $inbounds ]] && inbounds+=",
  "
    inbounds+=$(cat <<EOF
{"type": "vless", "tag": "argo-in", "listen": "127.0.0.1", "listen_port": $ARGO_PORT,
    "users": [{"name": "xa", "uuid": "$UUID"}],
    "transport": {"type": "ws", "path": "$ARGO_PATH"}}
EOF
)
  fi
  cat >"$SB_CFG" <<EOF
{
  "log": {"level": "warn"},
  "dns": {"servers": [{"type": "local", "tag": "local"}]},
  "inbounds": [
  $inbounds
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "endpoints": $ep,
  "route": {"rules": [$rules], "final": "$final", "default_domain_resolver": "local"}
}
EOF
}

write_services(){
  # 小内存机器(<300MB)限制 Go 运行时内存, 减少被 OOM 杀的概率
  local envline=""
  if (( $(awk '/MemTotal/{print $2}' /proc/meminfo) < 300000 )); then
    envline=$'Environment=GOGC=50\nEnvironment=GOMEMLIMIT=45MiB'
  fi
  if has_vless; then
    cat >/etc/systemd/system/xa-xray.service <<EOF
[Unit]
Description=Xray (VLESS+XHTTP+Reality) - xa-menu
After=network-online.target
Wants=network-online.target

[Service]
${envline}
ExecStart=$XRAY_BIN run -c $XRAY_CFG
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  fi
  if has_sb; then
    cat >/etc/systemd/system/xa-singbox.service <<EOF
[Unit]
Description=sing-box (AnyTLS / Hysteria2 / VLESS-WS-TLS) - xa-menu
After=network-online.target
Wants=network-online.target

[Service]
${envline}
ExecStart=$SB_BIN run -c $SB_CFG
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  fi
  if has_argo; then
    local argo_exec argo_env="" cfp=""
    # http2(TCP 7844)兼容性最好; quic 走 UDP 7844, 部分 VPS/网络会限制; auto = 先 quic 失败再回退
    [[ ${ARGO_PROTO:-http2} != auto ]] && cfp=" --protocol ${ARGO_PROTO:-http2}"
    if [[ ${ARGO_MODE:-quick} == token ]]; then
      # 令牌放在 600 权限的环境文件里, 不出现在 unit 文件和进程参数中
      printf 'TUNNEL_TOKEN=%s\n' "$ARGO_TOKEN" >"$BASE/argo.env"; chmod 600 "$BASE/argo.env"
      argo_exec="$CF_BIN tunnel --no-autoupdate${cfp} run"
      argo_env="EnvironmentFile=$BASE/argo.env"
    else
      rm -f "$BASE/argo.env"
      argo_exec="$CF_BIN tunnel --no-autoupdate${cfp} --url http://127.0.0.1:$ARGO_PORT"
    fi
    cat >/etc/systemd/system/xa-argo.service <<EOF
[Unit]
Description=Cloudflare Tunnel (Argo) - xa-menu
After=network-online.target xa-singbox.service
Wants=network-online.target

[Service]
${argo_env}
ExecStart=$argo_exec
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  fi
  systemctl daemon-reload
  # shellcheck disable=SC2046
  systemctl enable $(svc_list) >/dev/null 2>&1
}

# 返回占用某端口的进程名(空格分隔); 系统没有 ss 命令时返回空(跳过检查)
port_listeners(){
  command -v ss >/dev/null 2>&1 || return 0
  local flag=-lnt; [[ ${2:-tcp} == udp ]] && flag=-lnu
  ss $flag -p 2>/dev/null | awk -v p="$1" 'NR>1 { n=split($4,a,":"); if (a[n]==p) print }' \
    | grep -oE '\("[^"]+"' | tr -d '("' | sort -u | tr '\n' ' '
}

# 条目格式: 名称|端口|tcp或udp|应该占用它的进程|是否内部端口(1=只监听本机, 可以自动换)
PORT_ITEMS=()
build_port_items(){
  PORT_ITEMS=()
  has_vless  && PORT_ITEMS+=("VLESS-XHTTP-Reality|${XHTTP_PORT:-}|tcp|xray|0")
  has_anytls && PORT_ITEMS+=("AnyTLS|${ANYTLS_PORT:-}|tcp|sing-box|0")
  has_hy2    && PORT_ITEMS+=("Hysteria2|${HY2_PORT:-}|udp|sing-box|0")
  has_ws     && PORT_ITEMS+=("VLESS-WS-TLS|${WS_PORT:-}|tcp|sing-box|0")
  has_argo   && PORT_ITEMS+=("Argo本地入站|${ARGO_PORT:-}|tcp|sing-box|1")
  return 0
}

# 第 idx 个条目的端口有没有冲突, 有则输出原因(没有冲突不输出)
port_conflict_reason(){
  local idx=$1 name port kind exp internal n2 p2 k2 i2 owners o foreign=""
  IFS='|' read -r name port kind exp internal <<<"${PORT_ITEMS[$idx]}"
  if [[ -z $port ]]; then echo "没有设置端口"; return 0; fi
  for ((i2=0; i2<${#PORT_ITEMS[@]}; i2++)); do
    (( i2 == idx )) && continue
    IFS='|' read -r n2 p2 k2 _ <<<"${PORT_ITEMS[$i2]}"
    if [[ $p2 == "$port" && $k2 == "$kind" ]]; then echo "与 $n2 使用了同一个端口"; return 0; fi
  done
  owners=$(port_listeners "$port" "$kind")
  for o in $owners; do [[ $o == "$exp" ]] || foreign+="$o "; done
  if [[ -n $foreign ]]; then echo "已被其他程序占用(${foreign% })"; fi
  return 0
}

reassign_argo_port(){
  local old=$1 why=$2 new
  new=$(rand_port ${XHTTP_PORT:-} ${ANYTLS_PORT:-} ${HY2_PORT:-} ${WS_PORT:-})
  ARGO_PORT=$new
  warn "Argo 本地端口 ${old:-空} $why, 已自动改为 $new"
  if [[ ${ARGO_MODE:-quick} == token ]]; then
    warn "固定隧道: 请到 Cloudflare 把该隧道 Public Hostname 的服务地址改为 http://localhost:$new"
  fi
  write_services   # 临时隧道的 --url 里带着端口, 需要重写服务文件
}

# 应用配置前检查所有入站端口。一个端口冲突会让整个 sing-box 起不来(所有协议一起失效), 所以必须事先发现:
#   内部端口(Argo)冲突 -> 自动换一个; 对外端口冲突 -> 明确报错并中止, 不去重启服务
fix_port_conflicts(){
  local i name port reason rc=0 internal
  build_port_items
  for ((i=0; i<${#PORT_ITEMS[@]}; i++)); do
    IFS='|' read -r name port _ _ internal <<<"${PORT_ITEMS[$i]}"
    [[ $internal == 1 ]] || continue
    reason=$(port_conflict_reason "$i")
    if [[ -n $reason ]]; then reassign_argo_port "$port" "$reason"; build_port_items; fi
  done
  for ((i=0; i<${#PORT_ITEMS[@]}; i++)); do
    IFS='|' read -r name port _ _ internal <<<"${PORT_ITEMS[$i]}"
    [[ $internal == 1 ]] && continue
    reason=$(port_conflict_reason "$i")
    if [[ -n $reason ]]; then err "$name 的端口 ${port:-空} $reason"; rc=1; fi
  done
  if (( rc )); then echo "  请用菜单 4 修改端口(输入 r 可重新随机)后重试"; fi
  return $rc
}

# 重启后检查服务是不是真的起来了(包括"起来又立刻退出、反复重启"的情况), 并显示失败原因
check_services(){
  local s bad=0 bad_this why
  for s in $(svc_list); do
    bad_this=0
    systemctl is-active --quiet "$s" || bad_this=1
    why=$(journalctl -u "$s" --since "$ARGO_SINCE" --no-pager -o cat 2>/dev/null | grep -aE "FATAL|Failed to start" | tail -n 2)
    [[ -n $why ]] && bad_this=1
    if (( bad_this )); then
      bad=1
      echo -e "  $s: ${R}启动失败 / 反复重启${N}"
      [[ -n $why ]] && echo "$why" | cut -c1-220 | sed 's/^/    原因: /'
      echo "    详情: journalctl -u $s -n 30 --no-pager"
    fi
  done
  return $bad
}

apply(){
  fix_port_conflicts || return 1
  save_state
  if has_vless; then
    write_xray
    if ! "$XRAY_BIN" run -test -c "$XRAY_CFG" >/dev/null 2>&1; then
      err "Xray 配置校验失败:"; "$XRAY_BIN" run -test -c "$XRAY_CFG"; return 1
    fi
    open_ports "$XHTTP_PORT"
  fi
  if has_sb; then
    write_singbox
    if ! "$SB_BIN" check -c "$SB_CFG"; then
      err "sing-box 配置校验失败"
      has_ws && [[ $WS_CERT_MODE == acme ]] && warn "自动申请证书需要 sing-box >= 1.14, 请先在菜单 7 更新内核"
      return 1
    fi
    has_anytls && open_ports "$ANYTLS_PORT"
    has_hy2    && open_ports "$HY2_PORT"
    if has_ws; then
      open_ports "$WS_PORT"
      [[ $WS_CERT_MODE == acme ]] && open_ports 80
    fi
  fi
  if has_argo && [[ ! -x $CF_BIN ]]; then err "找不到 $CF_BIN, 请在菜单 11 重新开启 Argo"; return 1; fi
  # 没选的协议: 停掉并取消开机自启(切换协议后重装时用到)
  has_vless  || systemctl disable --now xa-xray    >/dev/null 2>&1
  has_sb     || systemctl disable --now xa-singbox >/dev/null 2>&1
  has_argo   || systemctl disable --now xa-argo    >/dev/null 2>&1
  # shellcheck disable=SC2046
  ARGO_SINCE=$(date '+%Y-%m-%d %H:%M:%S')
  systemctl restart $(svc_list)
  sleep 3
  show_status
  if ! check_services; then
    err "服务没有正常启动, 上面已列出原因; 修复后请再执行一次菜单 6(重启)"
    return 1
  fi
  if has_ws; then ws_wait_cert; fi
  if has_argo; then argo_wait_domain; fi
  return 0   # 注意: 末尾不能写 "cond && cmd", 条件不成立时会让整个函数返回非零
}

# 自动申请证书模式: 等待 sing-box 通过 Let's Encrypt 拿到证书(只是提示, 不影响其他协议)
ws_wait_cert(){
  [[ $WS_CERT_MODE == acme ]] || return 0
  info "等待 Let's Encrypt 签发证书(最多约 40 秒)..."
  local i
  for i in $(seq 1 20); do
    if echo | timeout 5 openssl s_client -connect "127.0.0.1:$WS_PORT" -servername "$WS_DOMAIN" 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
      info "证书已就绪: $WS_DOMAIN"; return 0
    fi
    sleep 2
  done
  warn "证书暂未签发成功(不影响其他协议)。常见原因: 域名未解析到本机 / 80 端口被占用或被防火墙拦截"
  warn "查看原因: journalctl -u xa-singbox -n 40 --no-pager"
  return 0
}

# ---------------------------------------------------------------- 展示
show_status(){
  local s
  for s in $(svc_list); do
    if systemctl is-active --quiet $s; then echo -e "  $s: ${G}运行中${N}"
    else echo -e "  $s: ${R}未运行${N}  (journalctl -u $s -n 30 --no-pager)"; fi
  done
}

show_info(){
  need_installed || return
  get_ip
  local host=$SERVER_IP penc enc=none label="VLESS + XHTTP + Reality"
  [[ $host == *:* ]] && host="[$host]"
  penc=${XHTTP_PATH//\//%2F}
  if [[ ${ENC_ON:-0} == 1 && -n $VLESS_ENC ]]; then enc=$VLESS_ENC; label="VLESS + XHTTP + Reality + Encryption"; fi
  echo
  echo -e "${C}=========== 节点信息 ===========${N}"
  echo "服务器: $SERVER_IP    WARP 模式: $WARP_MODE"
  echo
  if has_vless; then
  echo -e "${G}[1] ${label}${N}  (端口 $XHTTP_PORT)"
  echo "vless://${UUID}@${host}:${XHTTP_PORT}?encryption=${enc}&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=xhttp&path=${penc}&mode=auto#XHTTP-Reality-ENC"
  echo
  fi
  if has_anytls; then
  echo -e "${G}[2] AnyTLS${N}  (端口 $ANYTLS_PORT, 自签证书, 客户端需开启跳过证书验证)"
  echo "anytls://${ANYTLS_PASS}@${host}:${ANYTLS_PORT}?sni=${ANYTLS_SNI}&insecure=1#AnyTLS"
  echo
  echo "-- Mihomo/Clash.Meta 的 AnyTLS 片段 --"
  cat <<EOF
- name: AnyTLS
  type: anytls
  server: $SERVER_IP
  port: $ANYTLS_PORT
  password: $ANYTLS_PASS
  client-fingerprint: chrome
  udp: true
  sni: $ANYTLS_SNI
  skip-cert-verify: true
EOF
  echo
  fi
  if has_hy2; then
  local hobfs=""
  [[ -n $HY2_OBFS ]] && hobfs="&obfs=salamander&obfs-password=${HY2_OBFS}"
  echo -e "${G}[3] Hysteria2${N}  (UDP 端口 $HY2_PORT, 自签证书, 客户端需开启跳过证书验证$([[ -n $HY2_OBFS ]] && echo ', 已启用 salamander 混淆'))"
  echo "hysteria2://${HY2_PASS}@${host}:${HY2_PORT}?sni=${HY2_SNI}&insecure=1&alpn=h3${hobfs}#Hysteria2"
  echo
  echo "-- Mihomo/Clash.Meta 的 Hysteria2 片段 --"
  cat <<EOF
- name: Hysteria2
  type: hysteria2
  server: $SERVER_IP
  port: $HY2_PORT
  password: $HY2_PASS
  alpn: [h3]
  sni: $HY2_SNI
  skip-cert-verify: true
EOF
  [[ -n $HY2_OBFS ]] && printf '  obfs: salamander\n  obfs-password: %s\n' "$HY2_OBFS"
  echo
  fi
  if has_ws; then
  local wpath=${WS_PATH//\//%2F}
  echo -e "${G}[4] VLESS + WS + TLS${N}  (端口 $WS_PORT, 域名 $WS_DOMAIN$([[ $WS_CERT_MODE == acme ]] && echo ', 自动签发 Let'"'"'s Encrypt 证书'))"
  echo "vless://${UUID}@${WS_DOMAIN}:${WS_PORT}?encryption=none&security=tls&sni=${WS_DOMAIN}&fp=chrome&alpn=http%2F1.1&type=ws&host=${WS_DOMAIN}&path=${wpath}#VLESS-WS-TLS"
  echo
  echo "-- Mihomo/Clash.Meta 的 VLESS-WS-TLS 片段 --"
  cat <<EOF
- name: VLESS-WS-TLS
  type: vless
  server: $WS_DOMAIN
  port: $WS_PORT
  uuid: $UUID
  udp: true
  tls: true
  servername: $WS_DOMAIN
  client-fingerprint: chrome
  network: ws
  ws-opts:
    path: $WS_PATH
    headers:
      Host: $WS_DOMAIN
EOF
  [[ $WS_CERT_MODE == acme ]] && echo "(首次签发证书要几十秒, 进度: journalctl -u xa-singbox -f)"
  echo
  fi
  if has_argo; then
  argo_refresh_domain
  local apath=${ARGO_PATH//\//%2F}
  if [[ -z $ARGO_DOMAIN ]]; then
    echo -e "${G}[5] Argo 隧道 (VLESS-WS)${N}  域名尚未就绪: 稍后再执行 kv info, 或 journalctl -u xa-argo -n 40 --no-pager"
  else
    echo -e "${G}[5] Argo 隧道 (VLESS + WS + TLS, 经 Cloudflare)${N}  域名 $ARGO_DOMAIN$([[ ${ARGO_MODE:-quick} == quick ]] && echo ' (临时域名, 服务重启后会变)')"
    echo "vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&fp=chrome&type=ws&host=${ARGO_DOMAIN}&path=${apath}#Argo-VLESS-WS"
    echo "提示: 连不上时先在服务器执行 kv argocheck 自检; 国内网络直连 Cloudflare 默认 IP 常不通, 可把客户端「地址」改成优选 IP/域名, 并保持 SNI、Host 为 $ARGO_DOMAIN"
    if [[ ${ARGO_MODE:-quick} == token ]]; then
      echo -e "${Y}本地回源端口: $ARGO_PORT${N}  固定隧道: Cloudflare 里「$ARGO_DOMAIN」的 Public Hostname 服务必须是 HTTP + localhost:$ARGO_PORT (不一致会 502; 菜单 11 -> 9 可自动核对)"
    else
      echo "本地回源端口: $ARGO_PORT (临时隧道已自动对应, 无需在 Cloudflare 配置)"
    fi
  fi
  echo
  fi
  has_vless && [[ ${ENC_ON:-0} == 1 ]] && echo "提示: VLESS Encryption 需要客户端内核为 Xray >= 25.x(v2rayN 较新版本);不支持的客户端请在菜单 9 关闭 enc"
  echo "客户端: v2rayN / NekoBox / Shadowrocket / Hiddify / sing-box>=1.12 / mihomo"
  echo -e "${C}================================${N}"
}

# ---------------------------------------------------------------- 菜单动作
script_version_of(){ grep -m1 -E '^SCRIPT_VERSION="' "$1" 2>/dev/null | cut -d'"' -f2; }

# 校验一份脚本能不能用: 是脚本、是本脚本、语法正确、能运行 help
validate_script(){
  local f=$1
  [[ $(head -c2 "$f" 2>/dev/null) == "#!" ]] || { err "不是脚本文件"; return 1; }
  grep -q '^SCRIPT_VERSION="' "$f" || { err "不是本脚本(缺少版本标记)"; return 1; }
  bash -n "$f" 2>/dev/null || { err "语法检查未通过"; return 1; }
  bash "$f" help >/dev/null 2>&1 || { err "试运行 help 失败"; return 1; }
}

# 原子替换(mv): 正在运行的旧脚本不受影响
install_kv_file(){ install -m755 "$1" "$SELF.new" && mv -f "$SELF.new" "$SELF"; }

backup_kv(){
  [[ -f $SELF ]] || return 0
  local v; v=$(script_version_of "$SELF"); v=${v:-unknown}
  mkdir -p "$KV_BACKUPS"
  cp -f "$SELF" "$KV_BACKUPS/kv-${v}-$(date +%Y%m%d-%H%M%S)"
  # 只保留最近 5 份
  ls -1t "$KV_BACKUPS"/kv-* 2>/dev/null | tail -n +6 | xargs -r rm -f
}

self_update(){
  local url=${KV_URL:-$SCRIPT_URL} tmp new
  if [[ -z $url || $url == *YOUR_* ]]; then err "没有设置脚本地址 SCRIPT_URL"; return 1; fi
  tmp=$(mktemp)
  if ! curl -fsSL -H 'Cache-Control: no-cache' "${url}?_=$(date +%s)" -o "$tmp"; then
    err "下载失败: $url"; rm -f "$tmp"; return 1
  fi
  if ! validate_script "$tmp"; then
    err "远程脚本校验未通过, 已放弃更新(当前版本不变)"; rm -f "$tmp"; return 1
  fi
  new=$(script_version_of "$tmp")
  if [[ -f $SELF ]] && cmp -s "$tmp" "$SELF"; then
    info "已是最新版本: ${new:-$SCRIPT_VERSION}"; rm -f "$tmp"; return 0
  fi
  echo "当前版本: $SCRIPT_VERSION    远程版本: ${new:-未知}"
  [[ $(ask "更新到远程版本? [Y/n]: " y) =~ ^[Yy]$ ]] || { rm -f "$tmp"; return 0; }
  backup_kv
  install_kv_file "$tmp" || { err "写入 $SELF 失败"; rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  info "已更新为 ${new:-最新版}。旧版本已备份, 有问题可在菜单 13 回滚。请重新运行 kv 使新版本生效"
}

self_rollback(){
  local files=() f i=0 sel tmp
  mapfile -t files < <(ls -1t "$KV_BACKUPS"/kv-* 2>/dev/null)
  (( ${#files[@]} )) || { err "没有可回滚的备份"; return 1; }
  echo "可回滚的备份(新 -> 旧):"
  for f in "${files[@]}"; do i=$((i+1)); echo "  $i) $(basename "$f")   (版本 $(script_version_of "$f"))"; done
  sel=$(ask "选择要回滚到的序号 [1]: " 1)
  if ! [[ $sel =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#files[@]} )); then err "序号无效"; return 1; fi
  f=${files[$((sel-1))]}
  validate_script "$f" || { err "该备份校验未通过, 不回滚"; return 1; }
  tmp=$(mktemp); cp -f "$f" "$tmp"          # 先复制出来, 避免备份轮转时把它删掉
  backup_kv                                  # 当前版本也备份, 方便再切回去
  install_kv_file "$tmp" || { err "写入 $SELF 失败"; rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  info "已回滚到 $(basename "$f")。请重新运行 kv 使其生效"
}

menu_self(){
  echo "脚本当前版本: $SCRIPT_VERSION    更新地址: ${KV_URL:-$SCRIPT_URL}"
  echo "1) 检查并更新到最新   2) 回滚到备份版本   3) 查看备份列表"
  case "$(ask "请选择 [1]: " 1)" in
    1) self_update ;;
    2) self_rollback ;;
    3) ls -lt "$KV_BACKUPS" 2>/dev/null | tail -n +2 || echo "(没有备份)" ;;
  esac
}

# ---------------------------------------------------------------- Argo 隧道 (Cloudflare Tunnel)
# 原理: sing-box 在本机 127.0.0.1 开一个不带 TLS 的 VLESS+WS 入站, cloudflared 主动连到 Cloudflare 并把
# 公网域名回源到这个本地端口。客户端走 Cloudflare 的 443 + TLS, 服务器不需要开放入站端口。
cf_latest_tag(){
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases.atom" 2>/dev/null \
    | grep -oE '/releases/tag/[0-9][0-9A-Za-z._-]*' | sed 's#.*/tag/##' | awk '!s[$0]++' | sort -Vr | head -n1
}

install_cloudflared(){
  info "下载 cloudflared (Cloudflare Tunnel 客户端)..."
  local tmp tag a=amd64; tmp=$(mk_tmp)
  [[ ${SB_ARCH:-amd64} == arm64 ]] && a=arm64
  tag=$(cf_latest_tag)
  [[ -n $tag ]] || { err "获取 cloudflared 版本失败(GitHub 访问受限?)"; rm -rf "$tmp"; return 1; }
  info "cloudflared 目标版本: $tag"
  curl -fsSL -o "$tmp/cf" "https://github.com/cloudflare/cloudflared/releases/download/${tag}/cloudflared-linux-${a}" \
    || { err "cloudflared 下载失败"; rm -rf "$tmp"; return 1; }
  chmod +x "$tmp/cf"
  "$tmp/cf" --version >/dev/null 2>&1 || { err "cloudflared 无法运行(架构不符?)"; rm -rf "$tmp"; return 1; }
  install -m755 "$tmp/cf" "$CF_BIN"; rm -rf "$tmp"
  "$CF_BIN" --version | head -n1
}

# 临时隧道: 从 xa-argo 的日志里取 Cloudflare 分配的随机域名 (排除 api.trycloudflare.com)
argo_wait_domain(){
  [[ ${ARGO_MODE:-quick} == quick ]] || return 0
  info "等待 Cloudflare 分配临时域名(最多约 40 秒)..."
  local i d
  for i in $(seq 1 20); do
    d=$(journalctl -u xa-argo --since "$ARGO_SINCE" --no-pager -o cat 2>/dev/null \
        | grep -oE '[a-z0-9-]+\.trycloudflare\.com' | grep -v '^api\.' | tail -n1)
    if [[ -n $d ]]; then ARGO_DOMAIN=$d; save_state; info "临时域名: $ARGO_DOMAIN"; return 0; fi
    sleep 2
  done
  ARGO_DOMAIN=""; save_state
  warn "暂未获取到临时域名。稍后执行 kv info 再看, 或: journalctl -u xa-argo -n 40 --no-pager"
}

argo_enable(){
  local mode=$1 memmb d t
  memmb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  if (( memmb < 300 )); then
    warn "本机内存仅约 ${memmb}MB。Argo 会多跑一个 cloudflared 进程(约 30-50MB), 小内存机器可能不稳"
    [[ $(ask "仍要继续? [y/N]: " n) =~ ^[Yy]$ ]] || return 0
  fi
  [[ -n $UUID ]] || UUID=$(cat /proc/sys/kernel/random/uuid)
  [[ -n $ARGO_PORT ]] || ARGO_PORT=$(rand_port ${XHTTP_PORT:-} ${ANYTLS_PORT:-} ${HY2_PORT:-} ${WS_PORT:-})
  [[ -n $ARGO_PATH ]] || ARGO_PATH="/$(rand_str 8)"
  if [[ $mode == token ]]; then
    local pp
    echo "本地回源端口: Cloudflare 隧道里该域名的服务地址端口必须与它一致, 否则回源失败(502)。"
    echo "  已经在 Cloudflare 里配好端口的话, 这里填同样的数字; 还没配置的话直接回车, 再按下面的提示去 Cloudflare 填这个端口。"
    while true; do
      pp=$(ask "本地回源端口 [回车=$ARGO_PORT]: " "$ARGO_PORT")
      if valid_port "$pp" && [[ " ${XHTTP_PORT:-} ${ANYTLS_PORT:-} ${WS_PORT:-} " != *" $pp "* ]]; then break; fi
      warn "端口无效, 或与其他协议冲突"
    done
    ARGO_PORT=$pp
    echo "固定隧道需要先在 Cloudflare 控制台准备(Zero Trust -> Networks -> Tunnels):"
    echo "  1) 创建一条隧道(Cloudflared 类型), 复制安装命令里的 Token (一长串 eyJ 开头的字符)"
    echo "  2) 给该隧道添加 Public Hostname: 域名填你自己的, 服务类型 HTTP, URL 填: localhost:$ARGO_PORT"
    while true; do
      d=$(ask "你在 Cloudflare 里配置的域名 [${ARGO_DOMAIN:-例如 argo.example.com}]: " "${ARGO_DOMAIN:-}")
      d=${d,,}; valid_domain "$d" && break; warn "域名格式不正确"
    done
    while true; do
      t=$(ask "粘贴 Tunnel Token: " "")
      [[ $t =~ ^[A-Za-z0-9+/=_-]{60,}$ ]] && break; warn "Token 格式不正确(应是 60 位以上的长字符串)"
    done
    ARGO_MODE=token; ARGO_DOMAIN=$d; ARGO_TOKEN=$t
  else
    ARGO_MODE=quick; ARGO_DOMAIN=""; ARGO_TOKEN=""
  fi
  if [[ ! -x $SB_BIN ]]; then install_singbox || return 1; fi
  if [[ ! -x $CF_BIN ]]; then install_cloudflared || return 1; fi
  has_argo || { if [[ -n $PROTO ]]; then PROTO+=",argo"; else PROTO="argo"; fi; }
  write_services
  if apply; then
    show_info
    if [[ $mode == token ]]; then
      echo
      info "正在核对 Cloudflare 隧道里配置的回源端口(最多等 30 秒)..."
      argo_sync_port wait
    fi
  fi
  return 0
}

argo_disable(){
  local newp
  [[ $(ask "关闭并移除 Argo 隧道? [y/N]: " n) =~ ^[Yy]$ ]] || return 0
  newp=$(echo ",$PROTO," | sed 's/,argo,/,/g; s/^,//; s/,$//')
  [[ -n $newp ]] || { err "Argo 是目前唯一启用的协议, 关闭后没有可用协议。请先在菜单 1 安装其他协议"; return 1; }
  PROTO=$newp
  systemctl disable --now xa-argo >/dev/null 2>&1
  rm -f /etc/systemd/system/xa-argo.service "$BASE/argo.env" "$CF_BIN"
  systemctl daemon-reload
  ARGO_DOMAIN=""; ARGO_TOKEN=""
  apply && info "Argo 已关闭并移除"
}

# 临时隧道: cloudflared 每次(重新)启动都会换一个新域名。服务器重启、cloudflared 崩溃重启后,
# 状态里保存的域名就过期了, 旧链接会失效。这里从日志取最近一次分配的域名, 与保存的不一致就更新并提醒。
argo_refresh_domain(){
  [[ ${ARGO_MODE:-quick} == quick ]] || return 0
  local d
  d=$(journalctl -u xa-argo -n 3000 --no-pager -o cat 2>/dev/null | grep -oE '[a-z0-9-]+\.trycloudflare\.com' | grep -v '^api\.' | tail -n1)
  [[ -n $d ]] || return 0
  if [[ $d != "${ARGO_DOMAIN:-}" ]]; then
    warn "临时域名已变化: ${ARGO_DOMAIN:-无} -> $d (cloudflared 重启过, 旧的节点链接已失效, 请重新导入下面的新链接)"
    ARGO_DOMAIN=$d
    save_state
  fi
  return 0
}

diag_ok(){ echo -e "  ${G}[通过]${N} $*"; }
diag_ng(){ echo -e "  ${R}[异常]${N} $*"; DIAG_BAD=$((DIAG_BAD+1)); }

# 逐段检查 Argo: 本地入站 -> cloudflared -> 服务器到 Cloudflare -> 隧道日志 -> 经 Cloudflare 的端到端握手
argo_diag(){
  has_argo || { err "Argo 未启用"; return 1; }
  DIAG_BAD=0
  argo_refresh_domain
  local c nr reg logs h=region1.v2.argotunnel.com
  local up=(-H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==')

  echo "== 服务端期望的节点参数(请和客户端节点逐项对照) =="
  echo "  地址: 任意 Cloudflare 优选 IP / 域名 (不换也可以直接填 ${ARGO_DOMAIN:-隧道域名})    端口: 443    TLS: 开    传输: ws"
  echo "  SNI: ${ARGO_DOMAIN:-隧道域名}    Host: ${ARGO_DOMAIN:-隧道域名}    路径: $ARGO_PATH    UUID: $UUID"
  echo "  注意: 换成优选 IP 后, SNI 和 Host 必须仍是「本机」的隧道域名, 路径和 UUID 也是本机的; 多台机器各不相同, 不能混用"
  echo "  本地回源端口: $ARGO_PORT  (固定隧道: Cloudflare 里该域名的服务地址必须是 http://localhost:$ARGO_PORT)"
  echo "== 1/6 本地: sing-box 与 Argo 入站 =="
  if systemctl is-active --quiet xa-singbox; then diag_ok "xa-singbox 运行中"
  else diag_ng "xa-singbox 未运行: journalctl -u xa-singbox -n 30 --no-pager"; fi
  if (exec 3<>"/dev/tcp/127.0.0.1/$ARGO_PORT") 2>/dev/null; then diag_ok "本地入站 127.0.0.1:$ARGO_PORT 在监听"
  else diag_ng "127.0.0.1:$ARGO_PORT 没有监听(入站没起来)"; fi
  c=$(curl -s -o /dev/null -m 6 -w '%{http_code}' --http1.1 "${up[@]}" "http://127.0.0.1:${ARGO_PORT}${ARGO_PATH}" 2>/dev/null)
  case $c in
    101) diag_ok "本地 WebSocket 握手成功(HTTP 101), 路径 $ARGO_PATH 正确" ;;
    404) diag_ng "本地返回 404: 入站路径与配置不一致(应为 $ARGO_PATH)" ;;
    000|"") diag_ng "本地 WebSocket 握手连接失败" ;;
    *)   diag_ng "本地返回 HTTP $c(预期 101)" ;;
  esac

  echo "== 2/6 cloudflared 服务 =="
  if systemctl is-active --quiet xa-argo; then diag_ok "xa-argo 运行中(隧道协议: ${ARGO_PROTO:-http2}, 模式: ${ARGO_MODE:-quick})"
  else diag_ng "xa-argo 未运行: journalctl -u xa-argo -n 30 --no-pager"; fi
  nr=$(systemctl show -p NRestarts --value xa-argo 2>/dev/null)
  if [[ -n $nr && $nr != 0 ]]; then diag_ng "xa-argo 已自动重启 $nr 次(隧道反复断开或启动失败)"; fi

  echo "== 3/6 服务器到 Cloudflare 的连通性 =="
  if getent hosts "$h" >/dev/null 2>&1; then diag_ok "DNS 能解析 $h"
  else diag_ng "无法解析 $h(服务器 DNS 有问题, 可检查 /etc/resolv.conf)"; fi
  if timeout 6 bash -c "exec 3<>/dev/tcp/$h/7844" 2>/dev/null; then diag_ok "TCP 7844 可连(http2 隧道使用)"
  else diag_ng "TCP 7844 连不上: 出站被封或线路问题, 隧道无法建立"; fi
  if [[ ${ARGO_MODE:-quick} == quick ]]; then
    c=$(curl -s -o /dev/null -m 8 -w '%{http_code}' https://api.trycloudflare.com/ 2>/dev/null)
    if [[ -n $c && $c != 000 ]]; then diag_ok "能访问 api.trycloudflare.com(临时隧道申请域名用)"
    else diag_ng "无法访问 api.trycloudflare.com: 临时隧道申请不到域名, cloudflared 会反复退出重启"; fi
  fi

  echo "== 4/6 隧道日志 =="
  logs=$(journalctl -u xa-argo -n 300 --no-pager -o cat 2>/dev/null)
  reg=$(echo "$logs" | grep -c "Registered tunnel connection")
  if (( reg > 0 )); then diag_ok "隧道已向 Cloudflare 注册(Registered tunnel connection: $reg 次)"
  else diag_ng "日志里没有 Registered tunnel connection: 隧道没有连上 Cloudflare"; fi
  echo "$logs" | grep -E " (ERR|WRN) " | tail -n 5 | cut -c1-200 | sed 's/^/    最近日志: /'
  if [[ ${ARGO_MODE:-quick} == token ]]; then
    c=$(argo_cf_port)
    if [[ -n $c ]]; then
      if [[ $c == "$ARGO_PORT" ]]; then diag_ok "Cloudflare 隧道回源端口 $c 与本地入站端口一致"
      else diag_ng "Cloudflare 隧道把 $ARGO_DOMAIN 回源到端口 $c, 与本地入站端口 $ARGO_PORT 不一致(回源失败, 返回 502): 菜单 11 -> 9 一键同步"; fi
    else
      echo "    (日志里没有读到 Cloudflare 隧道的回源配置; 请在控制台核对: $ARGO_DOMAIN 的服务应为 http://localhost:$ARGO_PORT)"
    fi
  fi

  echo "== 5/6 域名 =="
  if [[ -z $ARGO_DOMAIN ]]; then diag_ng "还没有域名(临时隧道没拿到域名, 通常是上面第 3 步有失败项)"
  else diag_ok "域名: $ARGO_DOMAIN"; fi

  echo "== 6/6 经 Cloudflare 的端到端握手(在服务器上模拟客户端) =="
  if [[ -n $ARGO_DOMAIN ]]; then
    c=$(curl -s -o /dev/null -m 12 -w '%{http_code}' --http1.1 "${up[@]}" "https://${ARGO_DOMAIN}${ARGO_PATH}" 2>/dev/null)
    case $c in
      101) diag_ok "WebSocket 握手成功(HTTP 101): 隧道和源站都正常" ;;
      530|1033) diag_ng "Cloudflare 返回 $c(错误 1033): 认为隧道没有连上, 看第 2、3、4 步" ;;
      502|520|521|522|523|524|525|526) diag_ng "Cloudflare 返回 $c: 隧道在线, 但 Cloudflare 访问不到本地源站。固定隧道请检查 Public Hostname 的服务是否为 HTTP 类型、地址 localhost:$ARGO_PORT" ;;
      404) diag_ng "Cloudflare 返回 404: 主机名或路径不匹配。固定隧道请确认已给该隧道添加了域名 $ARGO_DOMAIN 的 Public Hostname" ;;
      000|"") diag_ng "服务器访问不到 $ARGO_DOMAIN(DNS 或网络问题)" ;;
      *) diag_ng "返回 HTTP $c(预期 101)" ;;
    esac
  else
    diag_ng "没有域名, 跳过"
  fi

  echo
  if (( DIAG_BAD == 0 )); then
    echo -e "${G}服务器端全部正常。${N}如果客户端仍然连不上, 问题在「客户端到 Cloudflare」这一段:"
    echo "  1) 国内网络直连 Cloudflare 默认 IP 常常很慢或不通: 把客户端里的「地址」换成优选的 Cloudflare IP 或域名, 保持 SNI 与 Host 仍为 $ARGO_DOMAIN"
    echo "  2) 临时隧道(trycloudflare.com)的域名在部分地区本身会被干扰, 可改用固定隧道 + 自己的域名"
    echo "  3) 客户端核对: 端口 443、开启 TLS、传输 ws、路径 $ARGO_PATH、Host 与 SNI 都是 $ARGO_DOMAIN、UUID 一致 (ALPN 填什么都不影响, 我实测过)"
    echo "  4) 在你电脑的 PowerShell 里自测(应出现 HTTP/1.1 101; 出现 101 说明线路和隧道都没问题, 问题在客户端节点配置):"
    echo "     curl.exe -v --http1.1 -H \"Connection: Upgrade\" -H \"Upgrade: websocket\" -H \"Sec-WebSocket-Version: 13\" -H \"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\" https://$ARGO_DOMAIN$ARGO_PATH"
  else
    echo -e "${R}发现 $DIAG_BAD 项异常${N}, 请按上面的提示逐项处理; 处理不了请把本次完整输出贴出来"
  fi
  return 0
}

# 判断 IPv4 是否属于 Cloudflare 公布的网段(用于提示"域名开了橙云"; 网段为经验值, 仅作提示)
cf_ip(){
  local ip=$1 n cidr net bits mask ni
  [[ $ip =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  n=$(( (BASH_REMATCH[1]<<24) + (BASH_REMATCH[2]<<16) + (BASH_REMATCH[3]<<8) + BASH_REMATCH[4] ))
  for cidr in 173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 \
              190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 \
              104.24.0.0/14 172.64.0.0/13 131.0.72.0/22; do
    net=${cidr%/*}; bits=${cidr#*/}
    [[ $net =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || continue
    ni=$(( (BASH_REMATCH[1]<<24) + (BASH_REMATCH[2]<<16) + (BASH_REMATCH[3]<<8) + BASH_REMATCH[4] ))
    mask=$(( (0xFFFFFFFF << (32-bits)) & 0xFFFFFFFF ))
    if (( (n & mask) == ni )); then return 0; fi
  done
  return 1
}

# VLESS-WS-TLS 自检: 本地入站 -> 域名解析 -> 证书 -> 本地 TLS+WS 握手, 并给出客户端侧的自测命令
ws_diag(){
  has_ws || { err "VLESS-WS-TLS 未安装"; return 1; }
  DIAG_BAD=0
  local c ips ip cf=0 certinfo logs okports=" 443 2053 2083 2087 2096 8443 "
  local up=(-H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==')

  echo "== 服务端期望的参数(请和客户端节点逐项对照) =="
  echo "  地址 / SNI / Host: $WS_DOMAIN    端口: $WS_PORT    TLS: 开    传输: ws    路径: $WS_PATH"
  echo "  UUID: $UUID    ALPN: 不填或 http/1.1 (实测填 h2、h3 不影响, 不是连不上的原因)    证书方式: $WS_CERT_MODE"

  echo "== 1/4 本地: sing-box 与入站 =="
  if systemctl is-active --quiet xa-singbox; then diag_ok "xa-singbox 运行中"
  else diag_ng "xa-singbox 未运行: journalctl -u xa-singbox -n 40 --no-pager"; fi
  if (exec 3<>"/dev/tcp/127.0.0.1/$WS_PORT") 2>/dev/null; then diag_ok "入站端口 $WS_PORT 在监听"
  else diag_ng "端口 $WS_PORT 没有监听(sing-box 没起来或配置没生效)"; fi

  echo "== 2/4 域名解析 =="
  get_ip
  ips=$(getent ahostsv4 "$WS_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  if [[ -z $ips ]]; then
    diag_ng "域名 $WS_DOMAIN 没有 A 记录解析: 请在 DNS 里添加 A 记录指向 $SERVER_IP"
  else
    for ip in $ips; do cf_ip "$ip" && cf=1; done
    if (( cf )); then
      diag_ng "域名解析到 Cloudflare 的 IP ($ips): 已开启橙云代理, 客户端实际连的是 Cloudflare, 不是你的服务器"
      if [[ $okports == *" $WS_PORT "* ]]; then
        echo "    当前端口 $WS_PORT 是 Cloudflare 支持代理的端口。此时请在 Cloudflare 的 SSL/TLS 里设为 Full(strict) 或使用源证书; 自动申请证书(HTTP-01)在橙云下可能失败"
      else
        echo "    而且 Cloudflare 只代理 443/2053/2083/2087/2096/8443, 当前端口 $WS_PORT 不在其中, 客户端一定连不上。解决: 把 DNS 记录改成灰云(仅 DNS), 或把端口改成上述端口(菜单 4)"
      fi
    elif [[ $ips == *"$SERVER_IP"* ]]; then
      diag_ok "域名解析到本机 IP $SERVER_IP"
    else
      diag_ng "域名解析到 [ $ips], 与本机 IP $SERVER_IP 不一致"
    fi
  fi

  echo "== 3/4 证书 =="
  certinfo=$(echo | timeout 8 openssl s_client -connect "127.0.0.1:$WS_PORT" -servername "$WS_DOMAIN" 2>/dev/null | openssl x509 -noout -subject -issuer -enddate 2>/dev/null)
  if [[ -z $certinfo ]]; then
    diag_ng "拿不到证书(TLS 握手失败)"
    if [[ $WS_CERT_MODE == acme ]]; then
      echo "    自动申请证书还没成功。常见原因: 域名没解析到本机 / 80 端口被占用或被防火墙拦截 / 域名开了橙云。最近相关日志:"
      logs=$(journalctl -u xa-singbox -n 300 --no-pager -o cat 2>/dev/null | grep -iE "acme|certificate|challenge|obtain|letsencrypt" | tail -n 6 | cut -c1-200)
      if [[ -n $logs ]]; then echo "$logs" | sed 's/^/      /'; else echo "      (日志里没有 ACME 相关记录)"; fi
    fi
  else
    diag_ok "已拿到证书"
    echo "$certinfo" | sed 's/^/      /'
    if [[ $WS_CERT_MODE == acme ]] && [[ $(echo "$certinfo" | grep -m1 '^subject=' | sed 's/^subject=//') == $(echo "$certinfo" | grep -m1 '^issuer=' | sed 's/^issuer=//') ]]; then
      diag_ng "证书是自签名的, 不是 Let's Encrypt 签发的(客户端会校验失败)"
    fi
  fi

  echo "== 4/4 本地 TLS + WebSocket 握手(模拟客户端, 跳过证书校验) =="
  c=$(curl -sk -o /dev/null -m 8 -w '%{http_code}' --http1.1 --resolve "${WS_DOMAIN}:${WS_PORT}:127.0.0.1" "${up[@]}" "https://${WS_DOMAIN}:${WS_PORT}${WS_PATH}" 2>/dev/null)
  case $c in
    101) diag_ok "握手成功(HTTP 101): 服务端协议配置正确" ;;
    404) diag_ng "返回 404: 路径不匹配(服务端路径应为 $WS_PATH)" ;;
    000|"") diag_ng "TLS 握手失败或连接不上(看第 3 步)" ;;
    *) diag_ng "返回 HTTP $c(预期 101)" ;;
  esac

  echo
  if (( DIAG_BAD == 0 )); then
    echo -e "${G}服务器端全部正常。${N}如果客户端仍连不上, 请在你电脑的 PowerShell 里执行下面两条, 把输出贴给我:"
  else
    echo -e "${R}发现 $DIAG_BAD 项异常${N}, 请先处理上面的异常项。处理后可在你电脑的 PowerShell 里用下面两条自测:"
  fi
  echo "  Test-NetConnection $WS_DOMAIN -Port $WS_PORT"
  echo "  curl.exe -v --http1.1 -H \"Connection: Upgrade\" -H \"Upgrade: websocket\" -H \"Sec-WebSocket-Version: 13\" -H \"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\" https://$WS_DOMAIN:$WS_PORT$WS_PATH"
  echo "  第一条应显示 TcpTestSucceeded : True; 第二条应出现 HTTP/1.1 101。"
  echo "  两条都通 => 线路和服务器都没问题, 问题在客户端节点配置; 第一条不通 => 线路/端口被拦; 第二条证书报错 => 看第 3 步。"
  return 0
}

# 固定隧道的回源地址是在 Cloudflare 控制台里配置的, 脚本的本地入站端口必须与之一致, 否则回源失败(502)。
# cloudflared 连上后会在日志里记录从 Cloudflare 收到的配置(Updated to new configuration), 这里从中读出该域名的服务端口。
# 读不到(隧道没连上、日志格式不同)时返回 1, 由调用方提示用户手动核对。
argo_cf_port(){
  [[ -n ${ARGO_DOMAIN:-} ]] || return 1
  local line svc port
  line=$(journalctl -u xa-argo -n 800 --no-pager -o cat 2>/dev/null | grep 'Updated to new configuration' | tail -n1)
  [[ -n $line ]] || return 1
  svc=$(echo "$line" | sed 's/\\//g; s/},{/\n/g' | grep -F "\"hostname\":\"${ARGO_DOMAIN}\"" | grep -oE '"service":"[^"]*"' | head -n1 | cut -d'"' -f4)
  [[ -n $svc ]] || return 1
  port=$(echo "$svc" | sed -nE 's#^[a-z]+://[^:/]+:([0-9]+).*#\1#p')
  if [[ -z $port ]]; then case $svc in https://*) port=443 ;; http://*) port=80 ;; esac; fi
  [[ -n $port ]] || return 1
  echo "$port"
}

# 核对并同步端口。参数 wait: 隧道刚启动时最多等 30 秒让它连上并记录配置
argo_sync_port(){
  has_argo || { err "Argo 未启用"; return 1; }
  if [[ ${ARGO_MODE:-quick} != token ]]; then
    info "临时隧道的回源端口由脚本自动对应(本地端口 $ARGO_PORT), 不需要同步"; return 0
  fi
  local cp="" i
  for i in $(seq 1 10); do
    cp=$(argo_cf_port) && break
    cp=""
    [[ ${1:-} == wait ]] || break
    sleep 3
  done
  if [[ -z $cp ]]; then
    warn "读不到 Cloudflare 隧道里配置的端口(隧道可能还没连上, 或日志格式与预期不同)"
    echo "  请到 Cloudflare 控制台核对: 域名 $ARGO_DOMAIN 的 Public Hostname 服务应为 HTTP + localhost:$ARGO_PORT"
    echo "  如果控制台里已经是别的端口, 就用菜单 11 -> 8 把本地端口设成同一个数字"
    return 1
  fi
  if [[ $cp == "$ARGO_PORT" ]]; then
    info "一致: 本地入站端口 $ARGO_PORT 与 Cloudflare 隧道里配置的端口相同"; return 0
  fi
  warn "不一致: Cloudflare 隧道把 $ARGO_DOMAIN 回源到端口 $cp, 而脚本的本地入站端口是 $ARGO_PORT (回源会失败, 返回 502)"
  if [[ " ${XHTTP_PORT:-} ${ANYTLS_PORT:-} ${WS_PORT:-} " == *" $cp "* ]]; then
    err "端口 $cp 已被本机其他协议使用, 无法改用。请到 Cloudflare 把服务地址改成 http://localhost:$ARGO_PORT"
    return 1
  fi
  if [[ ! $(ask "把脚本的本地端口改成 $cp (与 Cloudflare 一致)? [Y/n]: " y) =~ ^[Yy]$ ]]; then
    echo "  那就请到 Cloudflare 把服务地址改成 http://localhost:$ARGO_PORT"; return 0
  fi
  ARGO_PORT=$cp
  write_services
  apply && show_info
}

argo_port(){
  has_argo || { err "Argo 未启用"; return 1; }
  local p
  p=$(ask "Argo 本地端口(只监听 127.0.0.1) [当前 $ARGO_PORT, 输入 r 随机]: " "$ARGO_PORT")
  [[ $p == r ]] && p=$(rand_port ${XHTTP_PORT:-} ${ANYTLS_PORT:-} ${HY2_PORT:-} ${WS_PORT:-})
  valid_port "$p" || { err "端口无效"; return 1; }
  if [[ " ${XHTTP_PORT:-} ${ANYTLS_PORT:-} ${WS_PORT:-} " == *" $p "* ]]; then err "该端口已被其他协议使用"; return 1; fi
  ARGO_PORT=$p
  if [[ ${ARGO_MODE:-quick} == token ]]; then
    warn "固定隧道: 请到 Cloudflare 把该隧道 Public Hostname 的服务地址改为 http://localhost:$p"
  fi
  write_services
  apply && show_info
}

argo_proto(){
  has_argo || { err "Argo 未启用"; return 1; }
  echo "当前隧道协议: ${ARGO_PROTO:-http2}"
  echo "  1) http2  走 TCP 7844, 兼容性最好(默认)"
  echo "  2) quic   走 UDP 7844, 部分网络更快, 但常被 VPS / 运营商限制"
  echo "  3) auto   先 quic, 失败再回退 http2"
  case "$(ask "请选择 [回车保持不变]: " 0)" in
    1) ARGO_PROTO=http2 ;;
    2) ARGO_PROTO=quic ;;
    3) ARGO_PROTO=auto ;;
    *) return 0 ;;
  esac
  write_services
  save_state
  ARGO_SINCE=$(date '+%Y-%m-%d %H:%M:%S')
  systemctl restart xa-argo
  argo_wait_domain
  show_info
}

menu_argo(){
  need_installed || return
  local st="未启用"
  if has_argo; then st="已启用($([[ ${ARGO_MODE:-quick} == quick ]] && echo 临时隧道 || echo 固定隧道))"; fi
  echo "Argo 隧道 (Cloudflare Tunnel): $st"
  if has_argo; then
    echo "域名: ${ARGO_DOMAIN:-尚未获取}    本地回源端口: ${ARGO_PORT:-未设置}"
    if [[ ${ARGO_MODE:-quick} == token ]]; then echo "  固定隧道: Cloudflare 里该域名的服务地址必须是 http://localhost:${ARGO_PORT}"; fi
  fi
  echo "原理: 服务器主动连接 Cloudflare, 客户端经 Cloudflare 回源; 服务器 IP 或端口被封时仍可能可用, 不需要开放入站端口"
  echo "代价: 多跑一个 cloudflared 进程(约 30-50MB 内存), 流量绕路 Cloudflare, 速度和稳定性取决于线路"
  echo "  1) 开启临时隧道 (免账号, 随机 trycloudflare.com 域名, 重启后会变, 适合应急)"
  echo "  2) 开启固定隧道 (需要 Cloudflare 账号 + 域名 + Tunnel Token)"
  echo "  3) 重启隧道 / 重新获取临时域名"
  echo "  4) 关闭并移除 Argo"
  echo "  5) 查看状态 / 日志"
  echo "  6) 自检诊断 (逐段检查: 本地入站 / 隧道 / 连通性 / 端到端)"
  echo "  7) 切换隧道协议 (http2 / quic / auto), 当前: ${ARGO_PROTO:-http2}"
  echo "  8) 修改 Argo 本地端口 (当前: ${ARGO_PORT:-未设置}, 端口冲突时用)"
  echo "  9) 核对 / 同步 Cloudflare 隧道里配置的回源端口 (固定隧道; 不一致会 502)"
  case "$(ask "请选择 [5]: " 5)" in
    1) argo_enable quick ;;
    2) argo_enable token ;;
    3) if has_argo; then
         ARGO_SINCE=$(date '+%Y-%m-%d %H:%M:%S'); systemctl restart xa-argo; argo_wait_domain; show_info
       else err "Argo 未启用"; fi ;;
    4) if has_argo; then argo_disable; else err "Argo 未启用"; fi ;;
    5) if has_argo; then
         systemctl status xa-argo --no-pager | head -n 12
         journalctl -u xa-argo -n 15 --no-pager
         echo "域名: ${ARGO_DOMAIN:-尚未获取}"
       else info "Argo 未启用"; fi ;;
    6) argo_diag ;;
    7) argo_proto ;;
    8) argo_port ;;
    9) argo_sync_port ;;
  esac
}

show_kv_help(){
  echo -e "${C}-------------- 快捷命令说明 --------------${N}"
  cat <<HELP
  kv             打开管理菜单(安装/改UUID/WARP/端口/更新/卸载)
  kv info        查看节点链接
  kv uuid        修改 UUID
  kv warp        设置 WARP 模式(关闭/全局/分流)
  kv restart     重启服务
  kv update      更新 Xray / sing-box 内核(最新 pre-release)
  kv autoupdate  检查并升级内核(自动升级定时器调用的就是它)
  kv argo        管理 Argo 隧道 (Cloudflare Tunnel)
  kv argocheck   Argo 隧道自检诊断 (逐段定位哪里不通)
  kv wscheck     VLESS-WS-TLS 自检诊断 (域名 / 证书 / 握手)
  kv bbr         BBR 拥塞控制 (开启 / 关闭 / 状态)
  kv selfupdate  更新 kv 脚本本身 (旧版本自动备份)
  kv rollback    回滚 kv 脚本到之前的版本
  kv uninstall   卸载
HELP
  echo -e "${C}------------------------------------------${N}"
}

# 询问 VLESS-WS-TLS 的域名和证书方式(安装时和菜单 14 共用)
ask_ws(){
  local d m res
  while true; do
    d=$(ask "VLESS-WS-TLS 域名 [${WS_DOMAIN:-例如 ws.example.com}]: " "${WS_DOMAIN:-}")
    d=${d,,}
    valid_domain "$d" && break
    warn "域名格式不正确,例如 ws.example.com"
  done
  WS_DOMAIN=$d
  get_ip
  res=$(getent ahosts "$WS_DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
  if [[ -z $res ]]; then
    warn "域名 $WS_DOMAIN 暂时没有解析记录, 自动申请证书会失败。请先在 DNS 里添加 A 记录指向 $SERVER_IP"
  elif [[ $res != *"$SERVER_IP"* ]]; then
    warn "域名解析到 [ $res], 与本机 IP $SERVER_IP 不一致(套了 CDN 属正常; 但自动申请证书需要域名直接解析到本机)"
  fi
  echo "证书方式:"
  echo "  1) 自动申请 Let's Encrypt (sing-box 内置 ACME; 需要 80 端口空闲, 域名直接解析到本机, 不能开 CDN 橙云)"
  echo "  2) 使用已有证书文件 (如 Cloudflare 源证书 / acme.sh 签发的证书)"
  m=$(ask "请选择 [1]: " 1)
  if [[ $m == 2 ]]; then
    WS_CERT_MODE=file
    while true; do
      WS_CERT=$(ask "证书文件路径(fullchain / crt) [${WS_CERT:-}]: " "${WS_CERT:-}")
      WS_KEY=$(ask "私钥文件路径 [${WS_KEY:-}]: " "${WS_KEY:-}")
      [[ -r $WS_CERT && -r $WS_KEY ]] && break
      warn "证书或私钥文件不存在 / 不可读,请重新输入"
    done
  else
    WS_CERT_MODE=acme
    WS_EMAIL=$(ask "邮箱(证书到期提醒用, 可留空) [${WS_EMAIL:-}]: " "${WS_EMAIL:-}")
    if command -v ss >/dev/null && ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$'; then
      warn "检测到本机 80 端口已被占用(可能是 nginx / apache), 自动申请会失败, 建议改选 2"
    fi
  fi
}

menu_ws(){
  need_installed || return
  has_ws || { err "当前没有安装 VLESS-WS-TLS,请在菜单 1 重装并勾选 4"; return; }
  echo "1) 修改域名 / 证书设置   2) 自检诊断 (连不上时先做这个)"
  case "$(ask "请选择 [2]: " 2)" in
    1) ask_ws; apply && show_info ;;
    2) ws_diag ;;
  esac
}

do_install(){
  show_kv_help
  install_deps
  enable_bbr
  mkdir -p "$BASE"
  load_state

  local memmb defsel sel
  memmb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  defsel="1,2,3"; (( memmb < 300 )) && defsel="1"
  echo "安装哪些协议 (本机内存约 ${memmb}MB), 可多选, 如 1,2,3:"
  echo "  1) VLESS-XHTTP-Reality-ENC   (Xray 进程)"
  echo "  2) AnyTLS                    (sing-box 进程)"
  echo "  3) Hysteria2 (UDP)           (sing-box 进程)"
  echo "  4) VLESS-WS-TLS              (sing-box 进程, 需要一个已解析到本机的域名)"
  echo "  说明: 2、3、4 共用同一个 sing-box 进程; 选 1 会额外多跑一个 Xray 进程"
  (( memmb < 300 )) && warn "内存小于 300MB,建议少选(默认只装 1),同时跑多个进程容易被系统杀掉"
  sel=$(ask "请选择 [$defsel]: " "$defsel")
  PROTO=""
  [[ $sel == *1* ]] && PROTO+="vless,"
  [[ $sel == *2* ]] && PROTO+="anytls,"
  [[ $sel == *3* ]] && PROTO+="hy2,"
  [[ $sel == *4* ]] && PROTO+="ws,"
  PROTO=${PROTO%,}
  if [[ -z $PROTO ]]; then
    if (( memmb < 300 )); then PROTO="vless"; else PROTO="vless,anytls,hy2"; fi
  fi
  has_hy2 && tune_udp

  local v
  if has_vless || has_ws; then
  while true; do
    v=$(ask "自定义 UUID (回车随机生成): ")
    if [[ -z $v ]]; then UUID=$(cat /proc/sys/kernel/random/uuid); break; fi
    valid_uuid "$v" && { UUID=${v,,}; break; } || warn "UUID 格式不正确"
  done
  fi
  local used=""
  if has_vless; then
    XHTTP_PORT=$(ask_port "VLESS-XHTTP-Reality 端口" "$used"); used+=" $XHTTP_PORT"
    REALITY_SNI=$(ask "Reality 伪装域名(需支持TLS1.3/H2) [www.microsoft.com]: " "www.microsoft.com")
    [[ $(ask "启用 VLESS Encryption (enc, 抗量子加密) [Y/n]: " y) =~ ^[Yy]$ ]] && ENC_ON=1 || ENC_ON=0
  fi
  if has_anytls; then
    ANYTLS_PORT=$(ask_port "AnyTLS 端口" "$used"); used+=" $ANYTLS_PORT"
    ANYTLS_SNI=$(ask "AnyTLS 证书 SNI [www.bing.com]: " "www.bing.com")
  fi
  if has_hy2; then
    HY2_PORT=$(ask_port "Hysteria2 端口(UDP)" "$used"); used+=" $HY2_PORT"
    HY2_SNI=$(ask "Hysteria2 SNI [${ANYTLS_SNI:-www.bing.com}]: " "${ANYTLS_SNI:-www.bing.com}")
    if [[ $(ask "为 Hysteria2 启用 salamander 混淆(更抗 UDP 识别, 客户端需支持) [y/N]: " n) =~ ^[Yy]$ ]]; then
      HY2_OBFS=$(rand_str 16)
    else
      HY2_OBFS=""
    fi
  fi
  if has_ws; then
    WS_PORT=$(ask_port "VLESS-WS-TLS 端口(套 CDN 请填 443/2053/2083/2087/2096/8443)" "$used"); used+=" $WS_PORT"
    ask_ws
  fi
  local AUTO_UPD
  AUTO_UPD=$(ask "开启每周自动升级内核到最新 pre-release [Y/n]: " y)

  echo "WARP 模式: 1) 关闭  2) 全局走WARP  3) 分流(OpenAI/Netflix等走WARP)"
  case "$(ask "请选择 [1]: " 1)" in
    2) WARP_MODE=global ;; 3) WARP_MODE=split ;; *) WARP_MODE=off ;;
  esac

  has_vless  && { install_xray    || return 1; }
  has_sb     && { install_singbox || return 1; }

  if has_vless; then
    XHTTP_PATH="/$(rand_str 8)"
    SHORT_ID=$(openssl rand -hex 8)
    UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
    gen_reality || return 1
    if [[ $ENC_ON == 1 ]]; then gen_enc || { warn "enc 生成失败,已关闭 enc"; ENC_ON=0; }; fi
  fi
  has_anytls && ANYTLS_PASS=$(rand_str 16)
  has_hy2    && HY2_PASS=$(rand_str 16)
  has_ws     && WS_PATH="/$(rand_str 8)"
  has_selfcert && gen_cert

  if [[ $WARP_MODE != off ]]; then
    if ! warp_register; then
      warn "自动注册失败,改为手动导入? (n 则关闭 WARP)"
      [[ $(ask "手动导入 [y/N]: " n) =~ ^[Yy]$ ]] && warp_manual || WARP_MODE=off
      [[ -z $WARP_PRIV ]] && WARP_MODE=off
    fi
  fi

  write_services
  install_self
  [[ $AUTO_UPD =~ ^[Yy]$ ]] && enable_autoupdate
  if apply; then
    show_info
    echo -e "${G}安装完成。以后在任意目录输入 ${Y}kv${G} 即可管理。${N}"
    show_kv_help
  else
    err "安装未完成,请根据上面的错误处理后,重新运行脚本选 1 重装"
    return 1
  fi
}

menu_uuid(){
  need_installed || return
  has_vless || has_ws || { err "当前没有安装使用 UUID 的协议(VLESS),没有 UUID 可改"; return; }
  local v
  v=$(ask "新 UUID (回车随机生成): ")
  if [[ -z $v ]]; then v=$(cat /proc/sys/kernel/random/uuid)
  elif ! valid_uuid "$v"; then err "UUID 格式不正确"; return; fi
  UUID=${v,,}
  apply && show_info
}

menu_warp(){
  need_installed || return
  echo "当前 WARP 模式: $WARP_MODE"
  echo "1) 关闭   2) 全局   3) 分流   4) 重新注册新账号   5) 手动导入参数(WARP+/ZeroTrust)"
  case "$(ask "请选择: ")" in
    1) WARP_MODE=off ;;
    2) WARP_MODE=global ;;
    3) WARP_MODE=split ;;
    4) warp_register || return ;;
    5) warp_manual   || return ;;
    *) return ;;
  esac
  if [[ $WARP_MODE != off && -z $WARP_PRIV ]]; then
    warp_register || { WARP_MODE=off; err "已回退为关闭 WARP"; }
  fi
  apply && show_info
}

menu_port(){
  need_installed || return
  local p ch=0 old
  echo "端口输入 r 表示重新随机(20001-32767),回车保持不变"
  if has_vless; then
    p=$(ask "VLESS 端口 [$XHTTP_PORT]: " "$XHTTP_PORT")
    [[ $p == r ]] && p=$(rand_port ${ANYTLS_PORT:-} ${HY2_PORT:-} ${WS_PORT:-})
    valid_port "$p" && [[ " ${ANYTLS_PORT:-} ${HY2_PORT:-} ${WS_PORT:-} " != *" $p "* ]] && XHTTP_PORT=$p
    REALITY_SNI=$(ask "Reality 伪装域名 [$REALITY_SNI]: " "$REALITY_SNI")
  fi
  if has_anytls; then
    p=$(ask "AnyTLS 端口 [$ANYTLS_PORT]: " "$ANYTLS_PORT")
    [[ $p == r ]] && p=$(rand_port ${XHTTP_PORT:-} ${HY2_PORT:-} ${WS_PORT:-})
    valid_port "$p" && [[ " ${XHTTP_PORT:-} ${HY2_PORT:-} ${WS_PORT:-} " != *" $p "* ]] && ANYTLS_PORT=$p
    old=$ANYTLS_SNI; ANYTLS_SNI=$(ask "AnyTLS SNI [$ANYTLS_SNI]: " "$ANYTLS_SNI")
    [[ $old != "$ANYTLS_SNI" ]] && ch=1
  fi
  if has_hy2; then
    p=$(ask "Hysteria2 端口(UDP) [$HY2_PORT]: " "$HY2_PORT")
    [[ $p == r ]] && p=$(rand_port ${XHTTP_PORT:-} ${ANYTLS_PORT:-} ${WS_PORT:-})
    valid_port "$p" && [[ " ${XHTTP_PORT:-} ${ANYTLS_PORT:-} ${WS_PORT:-} " != *" $p "* ]] && HY2_PORT=$p
    old=$HY2_SNI; HY2_SNI=$(ask "Hysteria2 SNI [$HY2_SNI]: " "$HY2_SNI")
    [[ $old != "$HY2_SNI" ]] && ch=1
    echo "Hysteria2 salamander 混淆: 当前$([[ -n $HY2_OBFS ]] && echo 开启 || echo 关闭)   1) 保持  2) 开启(重新生成密码)  3) 关闭"
    case "$(ask "请选择 [1]: " 1)" in
      2) HY2_OBFS=$(rand_str 16) ;;
      3) HY2_OBFS="" ;;
    esac
  fi
  if has_ws; then
    p=$(ask "VLESS-WS-TLS 端口 [$WS_PORT]: " "$WS_PORT")
    [[ $p == r ]] && p=$(rand_port ${XHTTP_PORT:-} ${ANYTLS_PORT:-} ${HY2_PORT:-})
    valid_port "$p" && [[ " ${XHTTP_PORT:-} ${ANYTLS_PORT:-} ${HY2_PORT:-} " != *" $p "* ]] && WS_PORT=$p
  fi
  (( ch )) && has_selfcert && gen_cert
  apply && show_info
}

menu_enc(){
  need_installed || return
  has_vless || { err "当前没有安装 VLESS 协议,没有 VLESS Encryption"; return; }
  echo "当前 VLESS Encryption: $([[ ${ENC_ON:-0} == 1 ]] && echo 开启 || echo 关闭)"
  echo "1) 开启(重新生成密钥)   2) 关闭   3) 重新生成密钥"
  case "$(ask "请选择: ")" in
    1|3) gen_enc || return; ENC_ON=1 ;;
    2) ENC_ON=0 ;;
    *) return ;;
  esac
  apply && show_info
}

do_update(){
  need_installed || return
  has_vless  && { install_xray        || return 1; }
  has_sb     && { install_singbox     || return 1; }
  has_argo   && { install_cloudflared || return 1; }
  apply
}

do_uninstall(){
  [[ $(ask "确认卸载并删除所有配置? [y/N]: " n) =~ ^[Yy]$ ]] || return
  systemctl disable --now xa-xray xa-singbox xa-argo xa-update.timer >/dev/null 2>&1
  rm -f /etc/systemd/system/xa-xray.service /etc/systemd/system/xa-singbox.service \
        /etc/systemd/system/xa-update.service /etc/systemd/system/xa-update.timer \
        /etc/systemd/system/xa-argo.service
  systemctl daemon-reload
  rm -rf "$BASE" "$XRAY_BIN" "$XRAY_BIN.bak" "$SB_BIN" "$SB_BIN.bak" "$CF_BIN" /usr/local/bin/kv /usr/local/bin/xa /etc/sysctl.d/99-xa-bbr.conf /etc/sysctl.d/99-xa-udp.conf
  info "已卸载"
  exit 0
}

install_self(){
  local url=${KV_URL:-$SCRIPT_URL}
  # 一键(管道)运行时脚本无法复制自己, 需要知道它的 GitHub raw 地址
  if [[ ( -z $url || $url == *YOUR_* ) && ! -f $0 ]]; then
    warn "要生成 kv 命令,需要本脚本的 GitHub raw 地址"
    echo "  例: https://raw.githubusercontent.com/你的用户名/你的仓库名/main/install.sh"
    url=$(ask "请输入地址(留空跳过): " "")
  fi
  if [[ -n $url && $url != *YOUR_* ]]; then
    if curl -fsSL "$url" -o /usr/local/bin/kv 2>/dev/null && [[ $(head -c2 /usr/local/bin/kv) == "#!" ]]; then
      :
    else
      rm -f /usr/local/bin/kv
      warn "下载脚本失败,请检查地址: $url"
    fi
  elif [[ -f $0 ]]; then
    cp -f "$0" /usr/local/bin/kv
  else
    warn "已跳过 kv 命令。稍后可手动生成: curl -fsSL <脚本raw地址> -o /usr/local/bin/kv && chmod +x /usr/local/bin/kv"
  fi
  chmod +x /usr/local/bin/kv 2>/dev/null || true
  rm -f /usr/local/bin/xa   # 清理旧版命令名
}

menu(){
  while true; do
    load_state
    echo
    echo -e "${C}====== VLESS-XHTTP-Reality-ENC / AnyTLS / Hysteria2 / VLESS-WS-TLS 管理 ======${N}"
    echo -e "快捷命令: ${G}kv${N}  (任意目录输入 kv 即可再次打开本菜单)"
    if installed; then echo "状态:"; show_status; echo "WARP: $WARP_MODE"; else echo "状态: 未安装"; fi
    cat <<EOF
  1) 安装 / 重装
  2) 修改 UUID
  3) 设置 WARP 模式
  4) 修改端口 / SNI
  5) 查看节点信息
  6) 重启服务
  7) 更新内核 (Xray / sing-box)
  8) 卸载
  9) VLESS Encryption 开关 / 重新生成密钥
  10) 每周自动升级内核 (开关 / 立即升级 / 日志)
  11) Argo 隧道 (Cloudflare Tunnel, 直连被封时用)
  12) BBR 拥塞控制 (开启 / 关闭 / 状态)
  13) 更新脚本 (kv 自身, 可回滚)
  14) VLESS-WS-TLS 域名 / 证书设置 / 自检
  0) 退出
EOF
    case "$(ask "请选择: ")" in
      1) do_install ;;
      2) menu_uuid ;;
      3) menu_warp ;;
      4) menu_port ;;
      5) show_info ;;
      6) need_installed && apply ;;
      7) do_update ;;
      8) do_uninstall ;;
      9) menu_enc ;;
      10) menu_auto ;;
      11) menu_argo ;;
      12) menu_bbr ;;
      13) menu_self ;;
      14) menu_ws ;;
      0) exit 0 ;;
      *) warn "无效选项" ;;
    esac
  done
}

# ---------------------------------------------------------------- 入口
need_root
check_env
mkdir -p "$BASE"
load_state
case "${1:-}" in
  install)   do_install ;;
  uuid)      menu_uuid ;;
  warp)      menu_warp ;;
  info)      show_info ;;
  restart)   need_installed && apply ;;
  update)    do_update ;;
  autoupdate) auto_update ;;
  argo)      menu_argo ;;
  argocheck) argo_diag ;;
  wscheck)   ws_diag ;;
  bbr)       menu_bbr ;;
  selfupdate) self_update ;;
  rollback)  self_rollback ;;
  uninstall) do_uninstall ;;
  help|-h)   show_kv_help ;;
  *)         menu ;;
esac
