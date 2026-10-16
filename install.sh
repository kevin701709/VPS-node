#!/usr/bin/env bash
# =====================================================================
#  xa-menu : VLESS + XHTTP + Reality + Encryption (Xray)  +  AnyTLS (sing-box)
#  功能: 自定义 UUID / WARP 模式(关闭|全局|分流) / 端口与SNI / 节点链接
#  系统: Debian / Ubuntu / CentOS / Rocky / Alma (systemd, amd64/arm64)
#
#  一键安装:
#    bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_NAME/YOUR_REPO/main/install.sh)
#  安装后直接输入:  kv   (快捷管理命令)
# =====================================================================
set -u

# 上传 GitHub 后改成你自己的地址(用于把脚本保存为 kv 命令)
SCRIPT_URL="https://raw.githubusercontent.com/YOUR_NAME/YOUR_REPO/main/install.sh"

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

install_deps(){
  info "安装依赖..."
  local pk="curl jq unzip openssl ca-certificates tar"
  if command -v apt-get >/dev/null; then
    apt-get update -y >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y $pk >/dev/null 2>&1
  elif command -v dnf >/dev/null; then
    dnf install -y $pk >/dev/null 2>&1
  elif command -v yum >/dev/null; then
    yum install -y epel-release >/dev/null 2>&1; yum install -y $pk >/dev/null 2>&1
  else
    err "未识别的包管理器"; exit 1
  fi
  for c in curl jq unzip openssl tar; do
    command -v $c >/dev/null || { err "依赖 $c 安装失败"; exit 1; }
  done
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
  ENC_ON=0; VLESS_DEC=; VLESS_ENC=
  ANYTLS_PORT=; ANYTLS_PASS=; ANYTLS_SNI=; WARP_MODE=off; WARP_PRIV=; WARP_PUB=
  WARP_V4=; WARP_V6=; WARP_RESERVED=
  # shellcheck disable=SC1090
  [[ -f $STATE ]] && source "$STATE"
}

installed(){ [[ -f $STATE && -x $XRAY_BIN && -x $SB_BIN ]]; }
need_installed(){ installed || { err "尚未安装,请先选择 1 安装"; return 1; }; }

# ---------------------------------------------------------------- 内核
install_xray(){
  info "下载 Xray-core (最新版, 含 pre-release)..."
  local tmp tag url; tmp=$(mktemp -d)
  # 1) GitHub API: 列表按时间倒序且包含 pre-release (不用 /latest, 它只指向旧的稳定版)
  tag=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=10" 2>/dev/null \
        | jq -r '[.[] | select(.draft==false)][0].tag_name // empty' 2>/dev/null)
  # 2) API 被限流时: 用 releases.atom 订阅源 (同样含 pre-release, 不限流)
  if [[ -z $tag ]]; then
    tag=$(curl -fsSL "https://github.com/XTLS/Xray-core/releases.atom" 2>/dev/null \
          | grep -oE '/releases/tag/v[0-9][0-9A-Za-z._-]*' | head -n1 | sed 's#.*/tag/##')
  fi
  if [[ -n $tag ]]; then
    info "Xray 目标版本: $tag"
    url="https://github.com/XTLS/Xray-core/releases/download/${tag}/Xray-linux-${XR_ARCH}.zip"
  else
    warn "获取最新版本号失败,回退到稳定版 latest(版本可能较旧)"
    url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${XR_ARCH}.zip"
  fi
  curl -fsSL -o "$tmp/x.zip" "$url" || { err "Xray 下载失败: $url"; rm -rf "$tmp"; return 1; }
  unzip -qo "$tmp/x.zip" -d "$tmp" && install -m755 "$tmp/xray" "$XRAY_BIN"
  rm -rf "$tmp"
  "$XRAY_BIN" version | head -n1
}

install_singbox(){
  info "下载 sing-box..."
  local tmp ver; tmp=$(mktemp -d)
  ver=$(curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r '.tag_name // empty' | sed 's/^v//')
  [[ -z $ver ]] && { err "获取 sing-box 版本失败(GitHub API 受限?)"; return 1; }
  curl -fsSL -o "$tmp/sb.tgz" "https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${SB_ARCH}.tar.gz" \
    || { err "sing-box 下载失败"; rm -rf "$tmp"; return 1; }
  tar -xzf "$tmp/sb.tgz" -C "$tmp" && install -m755 "$tmp"/sing-box-*/sing-box "$SB_BIN"
  rm -rf "$tmp"
  "$SB_BIN" version | head -n1
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
  openssl genpkey -algorithm X25519 -outform DER -out "$tmp" 2>/dev/null || { err "openssl 不支持 X25519"; return 1; }
  priv=$(tail -c 32 "$tmp" | base64)
  pub=$(openssl pkey -inform DER -in "$tmp" -pubout -outform DER 2>/dev/null | tail -c 32 | base64)
  rm -f "$tmp"
  resp=$(curl -fsS --max-time 20 -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
    -H "Content-Type: application/json" -H "User-Agent: okhttp/3.12.1" -H "CF-Client-Version: a-6.10-2158" \
    -d "{\"key\":\"${pub}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"model\":\"PC\",\"serial_number\":\"\",\"locale\":\"en_US\"}" 2>/dev/null)
  [[ -z $resp ]] && { err "WARP 注册请求失败(IP 可能被限制,可用手动导入)"; return 1; }
  cid=$(jq -r '.config.client_id // empty' <<<"$resp")
  WARP_V4=$(jq -r '.config.interface.addresses.v4 // empty' <<<"$resp")
  WARP_V6=$(jq -r '.config.interface.addresses.v6 // empty' <<<"$resp")
  WARP_PUB=$(jq -r '.config.peers[0].public_key // empty' <<<"$resp")
  [[ -z $WARP_PUB ]] && WARP_PUB="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
  if [[ -z $cid || -z $WARP_V4 ]]; then err "WARP 注册响应异常"; return 1; fi
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
  local warp='[]' rules='[]' dom dec=none
  [[ ${ENC_ON:-0} == 1 && -n $VLESS_DEC ]] && dec=$VLESS_DEC
  dom=$(printf '%s\n' "${SPLIT_DOMAINS[@]}" | jq -R '"domain:"+.' | jq -s .)
  if [[ $WARP_MODE != off ]]; then
    warp=$(jq -n --arg k "$WARP_PRIV" --arg v4 "$WARP_V4/32" --arg v6 "$WARP_V6/128" \
      --arg pk "$WARP_PUB" --argjson res "[$WARP_RESERVED]" '[{
        tag:"warp",protocol:"wireguard",
        settings:{secretKey:$k,address:[$v4,$v6],
          peers:[{publicKey:$pk,allowedIPs:["0.0.0.0/0","::/0"],endpoint:"162.159.192.1:2408"}],
          mtu:1280,reserved:$res,domainStrategy:"ForceIP"}}]')
    if [[ $WARP_MODE == global ]]; then
      rules='[{"type":"field","network":"tcp,udp","outboundTag":"warp"}]'
    else
      rules=$(jq -n --argjson d "$dom" '[{type:"field",domain:$d,outboundTag:"warp"}]')
    fi
  fi
  jq -n --arg uuid "$UUID" --argjson port "$XHTTP_PORT" --arg path "$XHTTP_PATH" \
    --arg sni "$REALITY_SNI" --arg priv "$REALITY_PRIV" --arg sid "$SHORT_ID" --arg dec "$dec" \
    --argjson warp "$warp" --argjson rules "$rules" '{
    log:{loglevel:"warning"},
    inbounds:[{
      tag:"vless-xhttp-reality",listen:"0.0.0.0",port:$port,protocol:"vless",
      settings:{clients:[{id:$uuid}],decryption:$dec},
      streamSettings:{network:"xhttp",security:"reality",
        xhttpSettings:{path:$path,mode:"auto"},
        realitySettings:{show:false,dest:($sni+":443"),serverNames:[$sni],privateKey:$priv,shortIds:[$sid]}},
      sniffing:{enabled:true,destOverride:["http","tls","quic"]}}],
    outbounds:([{tag:"direct",protocol:"freedom"},{tag:"block",protocol:"blackhole"}] + $warp),
    routing:{domainStrategy:"AsIs",
      rules:([{type:"field",protocol:["bittorrent"],outboundTag:"block"}] + $rules)}
  }' >"$XRAY_CFG"
}

write_singbox(){
  local ep='[]' rules='[{"action":"sniff"}]' final="direct" sdom
  sdom=$(printf '%s\n' "${SPLIT_DOMAINS[@]}" | jq -R . | jq -s .)
  if [[ $WARP_MODE != off ]]; then
    ep=$(jq -n --arg k "$WARP_PRIV" --arg v4 "$WARP_V4/32" --arg v6 "$WARP_V6/128" \
      --arg pk "$WARP_PUB" --argjson res "[$WARP_RESERVED]" '[{
        type:"wireguard",tag:"warp",system:false,address:[$v4,$v6],private_key:$k,mtu:1280,
        peers:[{address:"162.159.192.1",port:2408,public_key:$pk,allowed_ips:["0.0.0.0/0","::/0"],reserved:$res}]}]')
    if [[ $WARP_MODE == global ]]; then
      final="warp"
    else
      rules=$(jq -n --argjson d "$sdom" '[{action:"sniff"},{domain_suffix:$d,action:"route",outbound:"warp"}]')
    fi
  fi
  jq -n --argjson port "$ANYTLS_PORT" --arg pass "$ANYTLS_PASS" --arg sni "$ANYTLS_SNI" \
    --arg crt "$CERT" --arg key "$KEY" --argjson ep "$ep" --argjson rules "$rules" --arg final "$final" '{
    log:{level:"warn"},
    dns:{servers:[{type:"local",tag:"local"}]},
    inbounds:[{type:"anytls",tag:"anytls-in",listen:"::",listen_port:$port,
      users:[{name:"xa",password:$pass}],
      tls:{enabled:true,server_name:$sni,certificate_path:$crt,key_path:$key}}],
    outbounds:[{type:"direct",tag:"direct"}],
    endpoints:$ep,
    route:{rules:$rules,final:$final,default_domain_resolver:"local"}
  }' >"$SB_CFG"
}

write_services(){
  cat >/etc/systemd/system/xa-xray.service <<EOF
[Unit]
Description=Xray (VLESS+XHTTP+Reality) - xa-menu
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$XRAY_BIN run -c $XRAY_CFG
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  cat >/etc/systemd/system/xa-singbox.service <<EOF
[Unit]
Description=sing-box (AnyTLS) - xa-menu
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$SB_BIN run -c $SB_CFG
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable xa-xray xa-singbox >/dev/null 2>&1
}

apply(){
  save_state
  write_xray; write_singbox
  if ! "$XRAY_BIN" run -test -c "$XRAY_CFG" >/dev/null 2>&1; then
    err "Xray 配置校验失败:"; "$XRAY_BIN" run -test -c "$XRAY_CFG"; return 1
  fi
  if ! "$SB_BIN" check -c "$SB_CFG"; then err "sing-box 配置校验失败"; return 1; fi
  open_ports "$XHTTP_PORT" "$ANYTLS_PORT"
  systemctl restart xa-xray xa-singbox
  sleep 1
  show_status
}

# ---------------------------------------------------------------- 展示
show_status(){
  local s
  for s in xa-xray xa-singbox; do
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
  echo -e "${G}[1] ${label}${N}  (端口 $XHTTP_PORT)"
  echo "vless://${UUID}@${host}:${XHTTP_PORT}?encryption=${enc}&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${SHORT_ID}&type=xhttp&path=${penc}&mode=auto#XHTTP-Reality-ENC"
  echo
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
  [[ ${ENC_ON:-0} == 1 ]] && echo "提示: VLESS Encryption 需要客户端内核为 Xray >= 25.x(v2rayN 较新版本);不支持的客户端请在菜单 9 关闭 enc"
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
  kv update      更新 Xray / sing-box 内核
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

  local v
  while true; do
    v=$(ask "自定义 UUID (回车随机生成): ")
    if [[ -z $v ]]; then UUID=$(cat /proc/sys/kernel/random/uuid); break; fi
    valid_uuid "$v" && { UUID=${v,,}; break; } || warn "UUID 格式不正确"
  done
  local dp
  dp=$(rand_port)
  while true; do
    XHTTP_PORT=$(ask "VLESS-XHTTP-Reality 端口 [回车随机: $dp]: " "$dp"); valid_port "$XHTTP_PORT" && break
    warn "端口无效"
  done
  dp=$(rand_port "$XHTTP_PORT")
  while true; do
    ANYTLS_PORT=$(ask "AnyTLS 端口 [回车随机: $dp]: " "$dp"); valid_port "$ANYTLS_PORT" && [[ $ANYTLS_PORT != "$XHTTP_PORT" ]] && break
    warn "端口无效或与 VLESS 端口冲突"
  done
  REALITY_SNI=$(ask "Reality 伪装域名(需支持TLS1.3/H2) [www.microsoft.com]: " "www.microsoft.com")
  ANYTLS_SNI=$(ask "AnyTLS 证书 SNI [www.bing.com]: " "www.bing.com")

  [[ $(ask "启用 VLESS Encryption (enc, 抗量子加密) [Y/n]: " y) =~ ^[Yy]$ ]] && ENC_ON=1 || ENC_ON=0

  echo "WARP 模式: 1) 关闭  2) 全局走WARP  3) 分流(OpenAI/Netflix等走WARP)"
  case "$(ask "请选择 [1]: " 1)" in
    2) WARP_MODE=global ;; 3) WARP_MODE=split ;; *) WARP_MODE=off ;;
  esac

  install_xray    || return 1
  install_singbox || return 1

  XHTTP_PATH="/$(rand_str 8)"
  SHORT_ID=$(openssl rand -hex 8)
  ANYTLS_PASS=$(rand_str 16)
  gen_reality || return 1
  if [[ $ENC_ON == 1 ]]; then gen_enc || { warn "enc 生成失败,已关闭 enc"; ENC_ON=0; }; fi
  gen_cert

  if [[ $WARP_MODE != off ]]; then
    if ! warp_register; then
      warn "自动注册失败,改为手动导入? (n 则关闭 WARP)"
      [[ $(ask "手动导入 [y/N]: " n) =~ ^[Yy]$ ]] && warp_manual || WARP_MODE=off
      [[ -z $WARP_PRIV ]] && WARP_MODE=off
    fi
  fi

  write_services
  install_self
  apply && show_info
  echo -e "${G}安装完成。以后在任意目录输入 ${Y}kv${G} 即可管理。${N}"
  show_kv_help
}

menu_uuid(){
  need_installed || return
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
  p=$(ask "VLESS 端口 [$XHTTP_PORT]: " "$XHTTP_PORT")
  [[ $p == r ]] && p=$(rand_port "$ANYTLS_PORT")
  valid_port "$p" && XHTTP_PORT=$p
  p=$(ask "AnyTLS 端口 [$ANYTLS_PORT]: " "$ANYTLS_PORT")
  [[ $p == r ]] && p=$(rand_port "$XHTTP_PORT")
  valid_port "$p" && [[ $p != "$XHTTP_PORT" ]] && ANYTLS_PORT=$p
  REALITY_SNI=$(ask "Reality 伪装域名 [$REALITY_SNI]: " "$REALITY_SNI")
  p=$(ask "AnyTLS SNI [$ANYTLS_SNI]: " "$ANYTLS_SNI")
  if [[ $p != "$ANYTLS_SNI" ]]; then ANYTLS_SNI=$p; gen_cert; fi
  apply && show_info
}

menu_enc(){
  need_installed || return
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
  systemctl disable --now xa-xray xa-singbox >/dev/null 2>&1
  rm -f /etc/systemd/system/xa-xray.service /etc/systemd/system/xa-singbox.service
  systemctl daemon-reload
  rm -rf "$BASE" "$XRAY_BIN" "$SB_BIN" /usr/local/bin/kv /usr/local/bin/xa /etc/sysctl.d/99-xa-bbr.conf
  info "已卸载"
  exit 0
}

install_self(){
  if [[ -n ${SCRIPT_URL:-} && $SCRIPT_URL != *YOUR_* ]]; then
    curl -fsSL "$SCRIPT_URL" -o /usr/local/bin/kv 2>/dev/null
  elif [[ -f $0 ]]; then
    cp -f "$0" /usr/local/bin/kv
  else
    warn "SCRIPT_URL 未设置为你的 GitHub 地址,无法生成 kv 命令;请修改脚本顶部 SCRIPT_URL 后重新安装"
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
  0) 退出
EOF
    case "$(ask "请选择: ")" in
      1) do_install ;;
      2) menu_uuid ;;
      3) menu_warp ;;
      4) menu_port ;;
      5) show_info ;;
      6) need_installed && { systemctl restart xa-xray xa-singbox; show_status; } ;;
      7) do_update ;;
      8) do_uninstall ;;
      9) menu_enc ;;
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
  restart)   systemctl restart xa-xray xa-singbox; show_status ;;
  update)    do_update ;;
  uninstall) do_uninstall ;;
  help|-h)   show_kv_help ;;
  *)         menu ;;
esac
