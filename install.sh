#!/usr/bin/env bash
# =====================================================================
#  xa-menu : VLESS + XHTTP + Reality + Encryption (Xray)  +  AnyTLS (sing-box)
#  功能: 每周自动升级内核(pre-release, 失败回滚) / 自定义 UUID / WARP 模式(关闭|全局|分流) / 端口与SNI / 节点链接
#  系统: Debian / Ubuntu / CentOS / Rocky / Alma (systemd, amd64/arm64)
#
#  一键安装:
#    bash <(curl -fsSL https://raw.githubusercontent.com/kevin701709/VPS-node/main/install.sh)
#  安装后直接输入:  kv   (快捷管理命令)
# =====================================================================
set -u

# 上传 GitHub 后改成你自己的地址(用于把脚本保存为 kv 命令)
SCRIPT_URL="https://raw.githubusercontent.com/kevin701709/VPS-node/main/install.sh"

BASE=/etc/xa-menu
STATE=$BASE/state.env
XRAY_BIN=/usr/local/bin/xray
SB_BIN=/usr/local/bin/sing-box
XRAY_CFG=$BASE/xray.json
SB_CFG=$BASE/sing-box.json
CERT=$BASE/anytls.crt
KEY=$BASE/anytls.key

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

# 随机端口: 20001-32767(避开系统临时端口段 32768+),跳过已占用端口和 $1
rand_port(){
  local p i
  for i in $(seq 1 50); do
    p=$(shuf -i 20001-32767 -n1)
    [[ $p == "${1:-}" ]] && continue
    ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${p}$" || { echo "$p"; return; }
  done
  echo $((20001 + RANDOM % 12767))
}

get_ip(){
  SERVER_IP=$(curl -s4m5 https://api.ipify.org || curl -s4m5 https://ip.sb)
  [[ -z $SERVER_IP ]] && SERVER_IP=$(curl -s6m5 https://api64.ipify.org)
  [[ -z $SERVER_IP ]] && SERVER_IP="YOUR_SERVER_IP"
}

enable_bbr(){
  cat >/etc/sysctl.d/99-xa-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl --system >/dev/null 2>&1
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
  ANYTLS_PORT=; ANYTLS_PASS=; ANYTLS_SNI=; WARP_MODE=off; WARP_PRIV=; WARP_PUB=
  WARP_V4=; WARP_V6=; WARP_RESERVED=
  # shellcheck disable=SC1090
  [[ -f $STATE ]] && source "$STATE"
}

# PROTO: both=两个协议都装 / vless=仅 VLESS-XHTTP-Reality-ENC(Xray) / anytls=仅 AnyTLS(sing-box)
has_vless(){  [[ ${PROTO:-both} != anytls ]]; }
has_anytls(){ [[ ${PROTO:-both} != vless ]]; }
svc_list(){ has_vless && echo xa-xray; has_anytls && echo xa-singbox; }

installed(){
  [[ -f $STATE ]] || return 1
  if has_vless;  then [[ -x $XRAY_BIN ]] || return 1; fi
  if has_anytls; then [[ -x $SB_BIN ]]   || return 1; fi
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
  has_anytls && { upgrade_core singbox || rc=1; }
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
    -keyout "$KEY" -out "$CERT" -subj "/CN=${ANYTLS_SNI}" >/dev/null 2>&1
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
  local ep="[]" rules='{"action": "sniff"}' final="direct" sdom="" d
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
  cat >"$SB_CFG" <<EOF
{
  "log": {"level": "warn"},
  "dns": {"servers": [{"type": "local", "tag": "local"}]},
  "inbounds": [{
    "type": "anytls", "tag": "anytls-in", "listen": "::", "listen_port": $ANYTLS_PORT,
    "users": [{"name": "xa", "password": "$ANYTLS_PASS"}],
    "tls": {"enabled": true, "server_name": "$ANYTLS_SNI", "certificate_path": "$CERT", "key_path": "$KEY"}
  }],
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
  if has_anytls; then
    cat >/etc/systemd/system/xa-singbox.service <<EOF
[Unit]
Description=sing-box (AnyTLS) - xa-menu
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
  systemctl daemon-reload
  # shellcheck disable=SC2046
  systemctl enable $(svc_list) >/dev/null 2>&1
}

apply(){
  save_state
  if has_vless; then
    write_xray
    if ! "$XRAY_BIN" run -test -c "$XRAY_CFG" >/dev/null 2>&1; then
      err "Xray 配置校验失败:"; "$XRAY_BIN" run -test -c "$XRAY_CFG"; return 1
    fi
    open_ports "$XHTTP_PORT"
  fi
  if has_anytls; then
    write_singbox
    if ! "$SB_BIN" check -c "$SB_CFG"; then err "sing-box 配置校验失败"; return 1; fi
    open_ports "$ANYTLS_PORT"
  fi
  # 没选的协议: 停掉并取消开机自启(切换协议后重装时用到)
  has_vless  || systemctl disable --now xa-xray    >/dev/null 2>&1
  has_anytls || systemctl disable --now xa-singbox >/dev/null 2>&1
  # shellcheck disable=SC2046
  systemctl restart $(svc_list)
  sleep 1
  show_status
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
  has_vless && [[ ${ENC_ON:-0} == 1 ]] && echo "提示: VLESS Encryption 需要客户端内核为 Xray >= 25.x(v2rayN 较新版本);不支持的客户端请在菜单 9 关闭 enc"
  echo "客户端: v2rayN / NekoBox / Shadowrocket / Hiddify / sing-box>=1.12 / mihomo"
  echo -e "${C}================================${N}"
}

# ---------------------------------------------------------------- 菜单动作
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
  kv uninstall   卸载
HELP
  echo -e "${C}------------------------------------------${N}"
}

do_install(){
  show_kv_help
  install_deps
  enable_bbr
  mkdir -p "$BASE"
  load_state

  local memmb defp
  memmb=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  defp=1; (( memmb < 300 )) && defp=2
  echo "安装哪些协议 (本机内存约 ${memmb}MB):"
  echo "  1) 两个都装: VLESS-XHTTP-Reality-ENC(Xray) + AnyTLS(sing-box)"
  echo "  2) 仅 VLESS-XHTTP-Reality-ENC (只跑 Xray, 最省内存)"
  echo "  3) 仅 AnyTLS (只跑 sing-box)"
  (( memmb < 300 )) && warn "内存小于 300MB,推荐只装一个协议(选 2),两个同时跑容易被系统杀掉"
  case "$(ask "请选择 [$defp]: " "$defp")" in
    2) PROTO=vless ;; 3) PROTO=anytls ;; *) PROTO=both ;;
  esac

  local v
  if has_vless; then
  while true; do
    v=$(ask "自定义 UUID (回车随机生成): ")
    if [[ -z $v ]]; then UUID=$(cat /proc/sys/kernel/random/uuid); break; fi
    valid_uuid "$v" && { UUID=${v,,}; break; } || warn "UUID 格式不正确"
  done
  fi
  local dp
  dp=$(rand_port)
  if has_vless; then
  while true; do
    XHTTP_PORT=$(ask "VLESS-XHTTP-Reality 端口 [回车随机: $dp]: " "$dp"); valid_port "$XHTTP_PORT" && break
    warn "端口无效"
  done
  REALITY_SNI=$(ask "Reality 伪装域名(需支持TLS1.3/H2) [www.microsoft.com]: " "www.microsoft.com")
  [[ $(ask "启用 VLESS Encryption (enc, 抗量子加密) [Y/n]: " y) =~ ^[Yy]$ ]] && ENC_ON=1 || ENC_ON=0
  dp=$(rand_port "$XHTTP_PORT")
  fi
  if has_anytls; then
  while true; do
    ANYTLS_PORT=$(ask "AnyTLS 端口 [回车随机: $dp]: " "$dp"); valid_port "$ANYTLS_PORT" && [[ $ANYTLS_PORT != "${XHTTP_PORT:-}" ]] && break
    warn "端口无效或与 VLESS 端口冲突"
  done
  ANYTLS_SNI=$(ask "AnyTLS 证书 SNI [www.bing.com]: " "www.bing.com")
  fi
  local AUTO_UPD
  AUTO_UPD=$(ask "开启每周自动升级内核到最新 pre-release [Y/n]: " y)

  echo "WARP 模式: 1) 关闭  2) 全局走WARP  3) 分流(OpenAI/Netflix等走WARP)"
  case "$(ask "请选择 [1]: " 1)" in
    2) WARP_MODE=global ;; 3) WARP_MODE=split ;; *) WARP_MODE=off ;;
  esac

  has_vless  && { install_xray    || return 1; }
  has_anytls && { install_singbox || return 1; }

  if has_vless; then
    XHTTP_PATH="/$(rand_str 8)"
    SHORT_ID=$(openssl rand -hex 8)
    UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
    gen_reality || return 1
    if [[ $ENC_ON == 1 ]]; then gen_enc || { warn "enc 生成失败,已关闭 enc"; ENC_ON=0; }; fi
  fi
  if has_anytls; then
    ANYTLS_PASS=$(rand_str 16)
    gen_cert
  fi

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
  has_vless || { err "当前仅安装了 AnyTLS,没有 UUID 可改"; return; }
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
  local p
  echo "端口输入 r 表示重新随机(20001-32767),回车保持不变"
  if has_vless; then
    p=$(ask "VLESS 端口 [$XHTTP_PORT]: " "$XHTTP_PORT")
    [[ $p == r ]] && p=$(rand_port "${ANYTLS_PORT:-}")
    valid_port "$p" && XHTTP_PORT=$p
    REALITY_SNI=$(ask "Reality 伪装域名 [$REALITY_SNI]: " "$REALITY_SNI")
  fi
  if has_anytls; then
    p=$(ask "AnyTLS 端口 [$ANYTLS_PORT]: " "$ANYTLS_PORT")
    [[ $p == r ]] && p=$(rand_port "${XHTTP_PORT:-}")
    valid_port "$p" && [[ $p != "${XHTTP_PORT:-}" ]] && ANYTLS_PORT=$p
    p=$(ask "AnyTLS SNI [$ANYTLS_SNI]: " "$ANYTLS_SNI")
    if [[ $p != "$ANYTLS_SNI" ]]; then ANYTLS_SNI=$p; gen_cert; fi
  fi
  apply && show_info
}

menu_enc(){
  need_installed || return
  has_vless || { err "当前仅安装了 AnyTLS,没有 VLESS Encryption"; return; }
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
  install_xray && install_singbox && apply
}

do_uninstall(){
  [[ $(ask "确认卸载并删除所有配置? [y/N]: " n) =~ ^[Yy]$ ]] || return
  systemctl disable --now xa-xray xa-singbox xa-update.timer >/dev/null 2>&1
  rm -f /etc/systemd/system/xa-xray.service /etc/systemd/system/xa-singbox.service \
        /etc/systemd/system/xa-update.service /etc/systemd/system/xa-update.timer
  systemctl daemon-reload
  rm -rf "$BASE" "$XRAY_BIN" "$XRAY_BIN.bak" "$SB_BIN" "$SB_BIN.bak" /usr/local/bin/kv /usr/local/bin/xa /etc/sysctl.d/99-xa-bbr.conf
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
    echo -e "${C}====== VLESS-XHTTP-Reality-ENC + AnyTLS 管理 ======${N}"
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
  0) 退出
EOF
    case "$(ask "请选择: ")" in
      1) do_install ;;
      2) menu_uuid ;;
      3) menu_warp ;;
      4) menu_port ;;
      5) show_info ;;
      6) need_installed && { systemctl restart $(svc_list); show_status; } ;;
      7) do_update ;;
      8) do_uninstall ;;
      9) menu_enc ;;
      10) menu_auto ;;
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
  restart)   need_installed && { systemctl restart $(svc_list); show_status; } ;;
  update)    do_update ;;
  autoupdate) auto_update ;;
  uninstall) do_uninstall ;;
  help|-h)   show_kv_help ;;
  *)         menu ;;
esac
