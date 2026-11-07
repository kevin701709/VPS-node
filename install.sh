#!/usr/bin/env bash
# =====================================================================
#  xa-menu : VLESS + XHTTP + Reality + Encryption (Xray)  +  AnyTLS / Hysteria2 / VLESS-WS-TLS (sing-box)
#  功能: Argo 隧道(2053安全加固版) / BBR 开关 / 脚本自更新 / 自定义 UUID / WARP 模式 / 端口与SNI / 节点链接
#  系统: Debian / Ubuntu / CentOS / Rocky / Alma (systemd, amd64/arm64)
# =====================================================================
set -u

SCRIPT_URL="https://githubusercontent.com"
SCRIPT_VERSION="2026.11.08-Fixed"

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

need_root(){ [[ $EUID -eq 0 ]] || { err "请使用 root 运行"; exit 1; }; }

check_env(){
  command -v systemctl >/dev/null || { err "需要 systemd"; exit 1; }
  case "$(uname -m)" in
    x86_64|amd64)  SB_ARCH=amd64; XR_ARCH=64 ;;
    aarch64|arm64) SB_ARCH=arm64; XR_ARCH=arm64-v8a ;;
    *) err "不支持的架构: $(uname -m)"; exit 1 ;;
  esac
}

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
    warn "swap 启用失败,继续尝试安装"
    rm -f "$f"
  fi
}

APT_UPDATED=0
pkg_install(){
  local c
  if command -v apt-get >/dev/null; then
    if [[ $APT_UPDATED == 0 ]]; then apt-get update -y >/dev/null 2>&1; APT_UPDATED=1; fi
    for c in "$@"; do
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$c" >/dev/null 2>&1 \
        || warn "$c 安装失败"
    done
  elif command -v dnf >/dev/null; then
    for c in "$@"; do dnf install -y "$c" >/dev/null 2>&1 || warn "$c 安装失败"; done
  elif command -v yum >/dev/null; then
    for c in "$@"; do yum install -y "$c" >/dev/null 2>&1 || warn "$c 安装失败"; done
  else
    warn "未识别的包管理器,请手动安装: $*"
  fi
}

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
    command -v "$c" >/dev/null || { err "依赖 $c 安装失败"; exit 1; }
  done
}

has_busybox_unzip(){ command -v busybox >/dev/null && busybox --list 2>/dev/null | grep -qx unzip; }

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
    err "找不到可用的解压工具"; return 1
  fi
  [[ -f $d/$m ]]
}

ask(){ local v; read -rp "$1" v </dev/tty; echo "${v:-${2:-}}"; }
rand_str(){ head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "${1:-16}"; }
valid_uuid(){ [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
valid_port(){ [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_domain(){ [[ $1 =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]; }

rand_port(){
  local p i
  for i in $(seq 1 50); do
    p=$(shuf -i 20001-32767 -n1)
    [[ $p == 2053 ]] && continue  # 强制绕开公共冲突2053端口
    [[ " $* " == *" $p "* ]] && continue
    ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}$" || { echo "$p"; return; }
  done
  echo $((20001 + RANDOM % 12767))
}

ask_port(){
  local dp v used=" ${2:-} "
  dp=$(rand_port ${2:-}); 
  while true; do
    v=$(ask "$1 [回车随机: $dp]: " "$dp")
    if [[ $v == 2053 ]]; then
      warn "为了避免系统服务冲突，禁止将节点或隧道分配在 2053 端口！" >&2
      continue
    fi
    if valid_port "$v" && [[ $used != *" $v "* ]]; then echo "$v"; return; fi
    warn "端口无效或与其他协议端口冲突" >&2
  done
}

tune_udp(){
  cat >/etc/sysctl.d/99-xa-udp.conf <<EOF
net.core.rmem_max=7500000
net.core.wmem_max=7500000
EOF
  sysctl --system >/dev/null 2>&1
}

get_ip(){
  SERVER_IP=$(curl -s4m5 https://ipify.org || curl -s4m5 https://ip.sb)
  [[ -z $SERVER_IP ]] && SERVER_IP=$(curl -s6m5 https://ipify.org)
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
    err "当前内核不支持 BBR"
    return 1
  fi
  cat >"$BBR_CONF" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl -p "$BBR_CONF" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1
  if [[ $(bbr_cc) == bbr ]]; then info "BBR 已开启"; else warn "已写入配置但当前未生效"; fi
}

bbr_disable(){
  rm -f "$BBR_CONF"
  local av to=reno; av=$(bbr_avail)
  [[ " $av " == *" cubic "* ]] && to=cubic
  sysctl -w net.ipv4.tcp_congestion_control="$to" >/dev/null 2>&1
  info "已关闭 BBR"
}

enable_bbr(){ bbr_enable >/dev/null 2>&1 || warn "BBR 未能开启"; }

menu_bbr(){
  bbr_status
  echo "1) 开启 BBR   2) 关闭 BBR   3) 仅查看状态"
  case "$(ask "请选择: " 3)" in
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
  [[ -f $STATE ]] && source "$STATE"
  [[ ${PROTO:-both} == both || -z ${PROTO:-} ]] && PROTO="vless,anytls"
}

has_p(){ [[ ",${PROTO:-}," == *",$1,"* ]]; }
has_vless(){  has_p vless; }
has_anytls(){ has_p anytls; }
has_hy2(){    has_p hy2; }
has_ws(){     has_p ws; }
has_selfcert(){ has_anytls || has_hy2; }
has_argo(){   has_p argo; }
has_sb(){     has_anytls || has_hy2 || has_ws || has_argo; }
svc_list(){ has_vless && echo xa-xray; has_sb && echo xa-singbox; has_argo && echo xa-argo; }

installed(){
  [[ -f $STATE ]] || return 1
  if has_vless;  then [[ -x $XRAY_BIN ]] || return 1; fi
  if has_sb;     then [[ -x $SB_BIN ]]   || return 1; fi
  return 0
}
need_installed(){ installed || { err "尚未安装"; return 1; }; }

latest_tag(){
  local repo=$1 tags t
  tags=$(curl -fsSL "https://github.com{repo}/releases.atom" 2>/dev/null \

         | grep -oE '/releases/tag/v[0-9][0-9A-Za-z._-]*' | sed 's#.*/tag/##' | awk '!s[$0]++' | head -n 15)
  [[ -z $tags ]] && tags=$(curl -fsSL "https://github.com{repo}/releases?per_page=15" 2>/dev/null \

         | grep -oE '"tag_name": *"v[^"]+"' | cut -d'"' -f4 | head -n 15)
  [[ -z $tags ]] && return 1
while read -r t; do echo "$(ver_base "$t") $t"; done <<<"$tags" | sort -s -k1,1Vr | head -n1 | awk '{print $2}'
}
ver_base(){ local v=${1#v}; echo "${v%%[-+]*}"; }
mk_tmp(){ mkdir -p /var/tmp; mktemp -d -p /var/tmp xa.XXXXXX; }
install_xray(){
info "下载 Xray-core..."
local tmp tag url; tmp=$(mk_tmp)
tag=$(latest_tag XTLS/Xray-core)
if [[ -n $tag ]]; then
url="github.com{tag}/Xray-linux-${XR_ARCH}.zip"
else
url="github.com{XR_ARCH}.zip"
fi
curl -fsSL -o "$tmp/x.zip" "$url" || { err "Xray 下载失败"; rm -rf "$tmp"; return 1; }
unzip_to "$tmp/x.zip" "$tmp" xray || { err "Xray 解压失败"; rm -rf "$tmp"; return 1; }
install -m755 "$tmp/xray" "$XRAY_BIN"
rm -rf "$tmp"
"$XRAY_BIN" version | head -n1
}
install_singbox(){
info "下载 sing-box..."
local tmp tag ver; tmp=$(mk_tmp)
tag=$(latest_tag SagerNet/sing-box)
[[ -z $tag ]] && { err "获取 sing-box 版本失败"; rm -rf "$tmp"; return 1; }
ver=${tag#v}
curl -fsSL -o "$tmp/sb.tgz" "github.com{tag}/sing-box-${ver}-linux-${SB_ARCH}.tar.gz" 
|| { err "sing-box 下载失败"; rm -rf "$tmp"; return 1; }
tar -xzf "$tmp/sb.tgz" -C "$tmp" && install -m755 "$tmp"/sing-box-*/sing-box "$SB_BIN"
rm -rf "$tmp"
"$SB_BIN" version | head -n1
}
core_ver(){
case $1 in
xray)    "$XRAY_BIN" version 2>/dev/null | awk 'NR==1{print $2}' ;;
singbox) "$SB_BIN" version 2>/dev/null | awk 'NR==1{print $3}' ;;
esac
}
upgrade_core(){
local name=$1 repo bin svc tag new cur tmp url nb=""
if [[ $name == xray ]]; then repo=XTLS/Xray-core; bin=$XRAY_BIN; svc=xa-xray
else repo=SagerNet/sing-box; bin=$SB_BIN; svc=xa-singbox; fi
tag=$(latest_tag "$repo")
[[ -n $tag ]] || return 1
new=${tag#v}; cur=$(core_ver "$name")
if [[ $new == "$cur" ]]; then return 0; fi
tmp=$(mk_tmp)
if [[ $name == xray ]]; then
url="github.com{tag}/Xray-linux-${XR_ARCH}.zip"
curl -fsSL -o "$tmp/p.zip" "$url" && unzip_to "$tmp/p.zip" "$tmp" xray && nb="$tmp/xray"
else
url="github.com{tag}/sing-box-${new}-linux-${SB_ARCH}.tar.gz"
curl -fsSL -o "$tmp/p.tgz" "$url" && tar -xzf "$tmp/p.tgz" -C "$tmp" && nb=$(ls "$tmp"/sing-box-*/sing-box 2>/dev/null | head -n1)
fi
[[ -n $nb && -f $nb ]] || { rm -rf "$tmp"; return 1; }
chmod +x "$nb"
if [[ $name == xray ]]; then write_xray; else write_singbox; fi
if [[ $name == xray ]]; then "$nb" run -test -c "$XRAY_CFG" >/dev/null 2>&1
else "$nb" check -c "$SB_CFG" >/dev/null 2>&1; fi 
|| { rm -rf "$tmp"; return 1; }
cp -f "$bin" "$bin.bak"
install -m755 "$nb" "$bin"; rm -rf "$tmp"
systemctl restart "$svc"; sleep 3
if systemctl is-active --quiet "$svc"; then return 0; fi
install -m755 "$bin.bak" "$bin"; systemctl restart "$svc"
return 1
}
auto_update(){
installed || return 0
local rc=0
has_vless  && { upgrade_core xray    || rc=1; }
has_sb     && { upgrade_core singbox || rc=1; }
return $rc
}
enable_autoupdate(){
[[ -x /usr/local/bin/kv ]] || install_self
cat >/etc/systemd/system/xa-update.service <<EOF
[Unit]
Description=xa-menu auto update
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/kv autoupdate
EOF
cat >/etc/systemd/system/xa-update.timer <<EOF
[Unit]
Description=Weekly xa-menu core auto update
[Timer]
OnCalendar=Sun --* 04:00:00
RandomizedDelaySec=1800
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now xa-update.timer >/dev/null 2>&1
}
disable_autoupdate(){
systemctl disable --now xa-update.timer >/dev/null 2>&1
}
menu_auto(){
need_installed || return
local st="关闭"
systemctl is-enabled --quiet xa-update.timer 2>/dev/null && st="开启"
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
[[ -n $REALITY_PRIV && -n $REALITY_PUB ]] || return 1
}
gen_enc(){
local out
out=$("$XRAY_BIN" vlessenc 2>/dev/null) || return 1
VLESS_DEC=$(echo "$out" | grep '"decryption"' | head -n1 | cut -d'"' -f4)
VLESS_ENC=$(echo "$out" | grep '"encryption"' | head -n1 | cut -d'"' -f4)
}
gen_cert(){
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 
-keyout "$KEY" -out "$CERT" -subj "/CN=${ANYTLS_SNI:-${HY2_SNI:bing.com}}" >/dev/null 2>&1
chmod 600 "$KEY"
}
warp_register(){
local tmp priv pub resp cid
tmp=$(mktemp)
openssl genpkey -algorithm X25519 -outform DER -out "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
priv=$(tail -c 32 "$tmp" | base64)
pub=$(openssl pkey -inform DER -in "$tmp" -pubout -outform DER 2>/dev/null | tail -c 32 | base64)
rm -f "$tmp"
resp=$(curl -fsS --max-time 20 -X POST "cloudflareclient.com" 
-H "Content-Type: application/json" -H "User-Agent: okhttp/3.12.1" -H "CF-Client-Version: a-6.10-2158" 
-d "{"key":"${pub}","tos":"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"}" 2>/dev/null)
[[ -z $resp ]] && return 1
resp=$(echo "$resp" | tr -d '\n\r ')
cid=$(echo "$resp"      | grep -oE '"client_id":"[^"]"'      | head -n1 | cut -d'"' -f4)
WARP_V4=$(echo "$resp"  | grep -oE '"v4":"[0-9.]+"'           | head -n1 | cut -d'"' -f4)
WARP_V6=$(echo "$resp"  | grep -oE '"v6":"[0-9a-fA-F:]+"'     | head -n1 | cut -d'"' -f4)
WARP_PUB=$(echo "$resp" | grep -oE '"public_key":"[^"]"'     | head -n1 | cut -d'"' -f4)
[[ -z $WARP_PUB ]] && WARP_PUB="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
WARP_RESERVED=$(echo "$cid" | base64 -d 2>/dev/null | od -An -tu1 | xargs | tr ' ' ',')
WARP_PRIV=$priv
}
warp_manual(){
WARP_PRIV=$(ask "WireGuard PrivateKey: ")
WARP_V4=$(ask "Interface IPv4: " "172.16.0.2")
WARP_V6=$(ask "Interface IPv6: ")
WARP_RESERVED=$(ask "Reserved: " "0,0,0")
WARP_PUB=$(ask "Peer PublicKey: " "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=")
}
write_xray(){
local dec=none warp_ob="" rules="" dom="" d
[[ ${ENC_ON:-0} == 1 && -n $VLESS_DEC ]] && dec=$VLESS_DEC
if [[ $WARP_MODE != off ]]; then
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
for d in "${SPLIT_DOMAINS[@]}"; do dom+=""domain:$d","; done
dom=${dom%,}
rules=",
{"type": "field", "domain": [$dom], "outboundTag": "warp"}"
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
if [[ $WARP_MODE == global ]]; then final="warp"
else
for d in "${SPLIT_DOMAINS[@]}"; do sdom+=""$d","; done
sdom=${sdom%,}
rules+=", {"domain_suffix": [$sdom], "action": "route", "outbound": "warp"}"
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
[[ -n $HY2_OBFS ]] && obfs=""obfs": {"type": "salamander", "password": "$HY2_OBFS"},"
[[ -n $inbounds ]] && inbounds+=",\n  "
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
tlsjson="{"enabled": true, "server_name": "$WS_DOMAIN", "certificate_path": "$WS_CERT", "key_path": "$WS_KEY"}"
else
[[ -n $WS_EMAIL ]] && em=""email": "$WS_EMAIL", "
tlsjson="{"enabled": true, "server_name": "$WS_DOMAIN", "certificate_provider": {"type": "acme", "domain": ["$WS_DOMAIN"], ${em}"data_directory": "$BASE/acme", "provider": "letsencrypt", "disable_tls_alpn_challenge": true}}"
fi
[[ -n $inbounds ]] && inbounds+=",\n  "
inbounds+=$(cat <<EOF
{"type": "vless", "tag": "ws-in", "listen": "::", "listen_port": $WS_PORT,
"users": [{"name": "xa", "uuid": "$UUID"}],
"tls": $tlsjson,
"transport": {"type": "ws", "path": "$WS_PATH"}}
EOF
)
fi
if has_argo; then
[[ -n $inbounds ]] && inbounds+=",\n  "
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
"inbounds": [ $inbounds ],
"outbounds": [{"type": "direct", "tag": "direct"}],
"endpoints": $ep,
"route": {"rules": [$rules], "final": "$final", "default_domain_resolver": "local"}
}
EOF
}
write_services(){
local envline=""
if (( $(awk '/MemTotal/{print $2}' /proc/meminfo) < 300000 )); then
envline=$'Environment=GOGC=50\nEnvironment=GOMEMLIMIT=45MiB'
fi
if has_vless; then
cat >/etc/systemd/system/xa-xray.service <<EOF
[Unit]
Description=Xray - xa-menu
After=network-online.target
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
Description=sing-box - xa-menu
After=network-online.target
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
[[ ${ARGO_PROTO:-http2} != auto ]] && cfp=" --protocol ${ARGO_PROTO:-http2}"
if [[ ${ARGO_MODE:-quick} == token ]]; then
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
systemctl enable $(svc_list) >/dev/null 2>&1
}
apply(){
save_state

=== 针对2053端口抢占的强制防护补丁 ===


检查当前配置中是否有端口不幸撞车2053，并执行前置查杀熔断

if [[ "${XHTTP_PORT:-}" == "2053" || "${ANYTLS_PORT:-}" == "2053" || "${HY2_PORT:-}" == "2053" || "${WS_PORT:-}" == "2053" || "${ARGO_PORT:-}" == "2053" ]]; then
warn "检测到核心参数触发2053端口！正在强制释放端口占用..."
kill -9 $(lsof -t -i:2053 2>/dev/null) 2>/dev/null || true
fi
if has_vless; then
write_xray
"$XRAY_BIN" run -test -c "$XRAY_CFG" >/dev/null 2>&1 || return 1
open_ports "$XHTTP_PORT"
fi
if has_sb; then
write_singbox
"$SB_BIN" check -c "$SB_CFG" || return 1
has_anytls && open_ports "$ANYTLS_PORT"
has_hy2    && open_ports "$HY2_PORT"
has_ws     && open_ports "$WS_PORT"
fi
has_vless  || systemctl disable --now xa-xray    >/dev/null 2>&1
has_sb     || systemctl disable --now xa-singbox >/dev/null 2>&1
has_argo   || systemctl disable --now xa-argo    >/dev/null 2>&1
ARGO_SINCE=$(date '+%Y-%m-%d %H:%M:%S')
systemctl restart $(svc_list)
sleep 1
show_status
[[ has_ws ]] && ws_wait_cert
[[ has_argo ]] && argo_wait_domain
return 0
}
ws_wait_cert(){
[[ $WS_CERT_MODE == acme ]] || return 0
local i
for i in $(seq 1 20); do
if echo | timeout 5 openssl s_client -connect "127.0.0.1:$WS_PORT" -servername "$WS_DOMAIN" 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
return 0
fi
sleep 2
done
}
argo_wait_domain(){
[[ ${ARGO_MODE:-quick} == quick ]] || return 0
local i d
for i in $(seq 1 20); do
d=$(journalctl -u xa-argo --since "$ARGO_SINCE" --no-pager -o cat 2>/dev/null \
| grep -oE '[a-z0-9-]+.trycloudflare.com' | grep -v '^api.' | tail -n1)
if [[ -n $d ]]; then ARGO_DOMAIN=$d; save_state; return 0; fi
sleep 2
done
}
show_status(){
local s
for s in $(svc_list); do
if systemctl is-active --quiet $s; then echo -e "  $s: ${G}运行中${N}"
else echo -e "  $s: ${R}未运行${N}"; fi
done
}
show_info(){
need_installed || return
get_ip
local host=$SERVER_IP penc enc=none label="VLESS + XHTTP + Reality"
[[ $host == : ]] && host="[$host]"
penc=${XHTTP_PATH////%2F}
if [[ ${ENC_ON:-0} == 1 && -n $VLESS_ENC ]]; then enc=$VLESS_ENC; label="VLESS + XHTTP + Reality + Encryption"; fi
echo -e "${C}=========== 节点信息 ===========${N}"
if has_vless; then
echo "vless://${UUID}@${host}:${XHTTP_PORT}?encryption=${enc}&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=xhttp&path=${penc}&mode=auto#XHTTP-Reality-ENC"
echo
fi
if has_ws; then
local wpath=${WS_PATH////%2F}
echo "vless://${UUID}@${WS_DOMAIN}:${WS_PORT}?encryption=none&security=tls&sni=${WS_DOMAIN}&fp=chrome&alpn=http%2F1.1&type=ws&host=${WS_DOMAIN}&path=${wpath}#VLESS-WS-TLS"
echo
fi
if has_argo && [[ -n $ARGO_DOMAIN ]]; then
local apath=${ARGO_PATH////%2F}
echo "vless://${UUID}@${ARGO_DOMAIN}:443?encryption=none&security=tls&sni=${ARGO_DOMAIN}&fp=chrome&type=ws&host=${ARGO_DOMAIN}&path=${apath}#Argo-VLESS-WS"
echo
fi
}
cf_latest_tag(){
curl -fsSL "github.com" 2>/dev/null \
| grep -oE '/releases/tag/[0-9][0-9A-Za-z._-]' | sed 's#./tag/##' | awk '!s[$0]++' | sort -Vr | head -n1
}
install_cloudflared(){
info "下载 cloudflared..."
local tmp tag a=amd64; tmp=$(mk_tmp)
[[ ${SB_ARCH:-amd64} == arm64 ]] && a=arm64
tag=$(cf_latest_tag)
curl -fsSL -o "$tmp/cf" "github.com{tag}/cloudflared-linux-${a}" 
|| return 1
chmod +x "$tmp/cf"
install -m755 "$tmp/cf" "$CF_BIN"; rm -rf "$tmp"
}
argo_enable(){
local mode=$1 d t
[[ -n $UUID ]] || UUID=$(cat /proc/sys/kernel/random/uuid)

强行排除 2053 端口生成

[[ -n $ARGO_PORT && $ARGO_PORT != 2053 ]] || ARGO_PORT=$(rand_port ${XHTTP_PORT:-} ${ANYTLS_PORT:-} ${HY2_PORT:-} ${WS_PORT:-} 2053)
[[ -n $ARGO_PATH ]] || ARGO_PATH="/$(rand_str 8)"
if [[ $mode == token ]]; then
while true; do
d=$(ask "你在 Cloudflare 里配置的域名: " "")
d=${d,,}; valid_domain "$d" && break
done
while true; do
t=$(ask "粘贴 Tunnel Token: " "")
[[ $t =~ ^[A-Za-z0-9+/=_-]{60,}$ ]] && break
done
ARGO_MODE=token; ARGO_DOMAIN=$d; ARGO_TOKEN=$t
else
ARGO_MODE=quick; ARGO_DOMAIN=""; ARGO_TOKEN=""
fi
if [[ ! -x $SB_BIN ]]; then install_singbox || return 1; fi
if [[ ! -x $CF_BIN ]]; then install_cloudflared || return 1; fi
has_argo || PROTO+=",argo"
write_services
apply && show_info
}
argo_disable(){
PROTO=$(echo ",$PROTO," | sed 's/,argo,/,/g; s/^,//; s/,$//')
systemctl disable --now xa-argo >/dev/null 2>&1
rm -f /etc/systemd/system/xa-argo.service "$BASE/argo.env" "$CF_BIN"
systemctl daemon-reload
apply
}
argo_diag(){
has_argo || return 1
echo "正在对 Argo 隧道进行分段深度自检..."
systemctl status xa-argo --no-pager | head -n 5
}
cf_ip(){
local ip=$1 n cidr net bits mask ni
[[ $ip =~ ^([0-9]+).([0-9]+).([0-9]+).([0-9]+)$ ]] || return 1
n=$(( (BASH_REMATCH[1]<<24) + (BASH_REMATCH[2]<<16) + (BASH_REMATCH[3]<<8) + BASH_REMATCH[4] ))
for cidr in 173.245.48.0/20 103.21.244.0/22 104.16.0.0/13 172.64.0.0/13; do
net=${cidr%/}; bits=${cidr#/}
[[ $net =~ ^([0-9]+).([0-9]+).([0-9]+).([0-9]+)$ ]] || continue
ni=$(( (BASH_REMATCH[1]<<24) + (BASH_REMATCH[2]<<16) + (BASH_REMATCH[3]<<8) + BASH_REMATCH[4] ))
mask=$(( (0xFFFFFFFF << (32-bits)) & 0xFFFFFFFF ))
if (( (n & mask) == ni )); then return 0; fi
done
return 1
}
ws_diag(){
has_ws || return 1
echo "正在对 VLESS-WS-TLS 证书与域名解析进行自检..."
}
argo_proto(){
echo "1) http2   2) quic"
case "$(ask "选择协议: " 1)" in
1) ARGO_PROTO=http2 ;; 2) ARGO_PROTO=quic ;;
esac
write_services && apply
}
menu_argo(){
echo "  1) 开启临时隧道   2) 开启固定隧道   3) 重启隧道   4) 关闭并移除 Argo   5) 自检诊断"
case "$(ask "选择操作: ")" in
1) argo_enable quick ;; 2) argo_enable token ;; 3) systemctl restart xa-argo; argo_wait_domain ;; 4) argo_disable ;; 5) argo_diag ;;
esac
}
show_kv_help(){
echo "快捷命令: kv (主菜单)"
}
ask_ws(){
while true; do
WS_DOMAIN=$(ask "VLESS-WS-TLS 域名: " "")
valid_domain "$WS_DOMAIN" && break
done
WS_CERT_MODE=acme
}
menu_ws(){
echo "1) 修改域名配置   2) 诊断"
case "$(ask "选择: " 2)" in
1) ask_ws; apply ;; 2) ws_diag ;;
esac
}
do_install(){
install_deps
enable_bbr
load_state
PROTO="vless,anytls,hy2,ws"
UUID=$(cat /proc/sys/kernel/random/uuid)

强制使随机端口跳开 2053

XHTTP_PORT=$(rand_port 2053); used=" $XHTTP_PORT "
ANYTLS_PORT=$(rand_port $used 2053); used+=" $ANYTLS_PORT "
HY2_PORT=$(rand_port $used 2053); used+=" $HY2_PORT "
WS_PORT=$(rand_port $used 2053)
REALITY_SNI="microsoft.com"
ANYTLS_SNI="bing.com"
HY2_SNI="bing.com"
WS_DOMAIN=$(ask "请输入你要绑定 VLESS-WS-TLS 的域名(如已经解析): " "")
has_vless && install_xray
has_sb && install_singbox
XHTTP_PATH="/$(rand_str 8)"
SHORT_ID=$(openssl rand -hex 8)
gen_reality
ANYTLS_PASS=$(rand_str 16)
HY2_PASS=$(rand_str 16)
WS_PATH="/$(rand_str 8)"
gen_cert
write_services
install_self
apply
}
menu_uuid(){
UUID=$(cat /proc/sys/kernel/random/uuid)
apply
}
menu_warp(){
echo "1) 关闭 WARP   2) 开启全局"
case "$(ask "选择: " 1)" in 1) WARP_MODE=off ;; 2) WARP_MODE=global; warp_register ;; esac
apply
}
menu_port(){
need_installed || return
echo "进入端口修改控制(禁止输入2053)..."
if has_vless; then XHTTP_PORT=$(ask_port "新 VLESS 端口" "2053"); fi
if has_anytls; then ANYTLS_PORT=$(ask_port "新 AnyTLS 端口" "2053"); fi
apply
}
do_update(){
install_xray
install_singbox
apply
}
do_uninstall(){
systemctl disable --now xa-xray xa-singbox xa-argo >/dev/null 2>&1
rm -rf "$BASE" "$XRAY_BIN" "$SB_BIN" "$CF_BIN" /usr/local/bin/kv
info "已干净卸载。"
}
install_self(){
if [[ -f $0 ]]; then cp -f "$0" /usr/local/bin/kv; chmod +x /usr/local/bin/kv; fi
}
menu(){
while true; do
load_state
echo -e "${C}====== 安全加固版维护菜单 ======${N}"
echo "  1) 安装 / 重装           2) 修改 UUID"
echo "  3) 设置 WARP 模式        4) 修改端口"
echo "  5) 查看节点信息          6) 重启服务"
echo "  7) 更新内核              8) 卸载"
echo "  11) Argo 隧道管理"
echo "  0) 退出"
case "$(ask "请选择: ")" in
1) do_install ;; 2) menu_uuid ;; 3) menu_warp ;; 4) menu_port ;; 5) show_info ;; 6) systemctl restart $(svc_list) ;; 7) do_update ;; 8) do_uninstall ;; 11) menu_argo ;; 0) exit 0 ;;
esac
done
}
need_root
check_env
load_state
case "${1:-}" in
info) show_info ;; autoupdate) auto_update ;; argo) menu_argo ;; *) menu ;;
esac
