#!/usr/bin/env bash
# ============================================================
# 家教出行助手 · 国内服务器一键部署脚本
#
# 适用系统：Ubuntu 20.04+ / Debian 11+
# 使用方式：sudo bash server-setup.sh --public-ip <服务器公网IP> [--port 8080]
#
# 部署结构（前端是纯静态页面，接口同源代理，因此不存在跨域问题）：
#   nginx :8080 ──┬── /       静态文件  frontend/out
#                 └── /api/  ->  uvicorn  127.0.0.1:8000
#
# 生产环境不需要运行 Node 服务，Node 只在构建前端时用到。
#
# 脚本可以重复执行，用于更新代码或修改密钥。
# ============================================================

set -euo pipefail

APP_DIR="/opt/tutorassistant"
PACKAGE="/tmp/tutorassistant.tar.gz"
NGINX_PORT="8080"
API_PORT="8000"
PUBLIC_IP=""
REPO_URL=""

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[提示] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[错误] %s\033[0m\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --public-ip) PUBLIC_IP="${2:-}"; shift 2 ;;
    --port)      NGINX_PORT="${2:-}"; shift 2 ;;
    --repo)      REPO_URL="${2:-}"; shift 2 ;;
    -h|--help)   sed -n '2,16p' "$0"; exit 0 ;;
    *)           die "未知参数：$1" ;;
  esac
done

# ============================================================
# 0. 前置检查
# ============================================================

[[ $EUID -eq 0 ]] || die "请使用 root 运行：sudo bash $0 --public-ip <服务器公网IP>"

if [[ ! -t 0 ]]; then
  die "请在交互式终端中运行本脚本（需要手动输入密钥，不能用管道或重定向）"
fi

if [[ ! -r /etc/os-release ]]; then
  die "无法识别系统版本，本脚本仅支持 Ubuntu / Debian"
fi
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  ubuntu | debian) ;;
  *) warn "当前系统为 ${ID:-未知}，脚本按 Debian 系处理，若报错请改用 Ubuntu 22.04 / 24.04" ;;
esac

if [[ -z "$PUBLIC_IP" ]]; then
  log "未指定公网 IP，尝试自动探测"
  PUBLIC_IP="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$PUBLIC_IP" ]] || die "无法自动探测公网 IP，请用 --public-ip 手动指定"
fi

log "系统：${PRETTY_NAME:-$ID}    公网 IP：$PUBLIC_IP    对外端口：$NGINX_PORT"

# ============================================================
# 1. 安装系统依赖
# ============================================================

log "更新软件源并安装基础依赖（首次执行需要几分钟）"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip nginx curl ca-certificates gnupg

NODE_MAJOR="0"
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR="$(node -v | sed 's/^v//' | cut -d. -f1)"
fi

if [[ "$NODE_MAJOR" -lt 20 ]]; then
  log "安装 Node.js 22（Next.js 16 需要 Node 20 及以上）"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y -qq nodejs
fi

log "Node 版本：$(node -v)    Python 版本：$(python3 -V)"

# ============================================================
# 2. 小内存机器补 swap（构建前端时容易内存不足）
# ============================================================

MEM_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
SWAP_KB="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"

if [[ "$MEM_MB" -lt 3000 && "$SWAP_KB" -eq 0 ]]; then
  log "内存 ${MEM_MB}MB 且没有 swap，创建 2GB swap 防止构建前端时内存不足"
  if ! fallocate -l 2G /swapfile 2>/dev/null; then
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
  fi
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ============================================================
# 3. 放置代码
# ============================================================

log "准备代码目录 $APP_DIR"
mkdir -p "$APP_DIR"

if [[ -f "$PACKAGE" ]]; then
  log "解压代码包 $PACKAGE"
  tar -xzf "$PACKAGE" -C "$APP_DIR"
elif [[ -n "$REPO_URL" ]]; then
  log "从 Git 仓库拉取代码：$REPO_URL"
  command -v git >/dev/null 2>&1 || apt-get install -y -qq git
  rm -rf "$APP_DIR/.clone"
  git clone --depth 1 "$REPO_URL" "$APP_DIR/.clone"
  cp -a "$APP_DIR/.clone/frontend" "$APP_DIR/"
  cp -a "$APP_DIR/.clone/backend" "$APP_DIR/"
  rm -rf "$APP_DIR/.clone"
else
  die "找不到代码包 $PACKAGE，也没有通过 --repo 指定仓库地址"
fi

[[ -f "$APP_DIR/backend/main.py" ]] || die "代码结构异常：缺少 backend/main.py"
[[ -f "$APP_DIR/frontend/package.json" ]] || die "代码结构异常：缺少 frontend/package.json"

# ============================================================
# 4. 配置密钥
# ============================================================

ENV_FILE="$APP_DIR/backend/.env"

ask_key() {
  # $1 = 变量名，$2 = 提示说明
  local name="$1" hint="$2" current="" value=""

  if [[ -f "$ENV_FILE" ]]; then
    current="$(sed -n "s/^${name}=//p" "$ENV_FILE" | head -n 1)"
  fi

  if [[ -n "$current" ]]; then
    printf '%s 已配置，直接回车沿用，或粘贴新值：' "$name" >&2
    read -r value
    value="${value:-$current}"
  else
    while [[ -z "$value" ]]; do
      printf '请粘贴 %s（%s）：' "$name" "$hint" >&2
      read -r value
      value="${value//\"/}"
      value="${value//\'/}"
      [[ -n "$value" ]] || printf '\033[1;33m不能为空，请重新粘贴\033[0m\n' >&2
    done
  fi

  printf -v "$name" '%s' "$value"
  printf '  已接收 %s，长度 %s\n' "$name" "${#value}" >&2
}

log "配置后端密钥（密钥只写入服务器本地，不会上传到任何地方）"
ask_key DEEPSEEK_API_KEY '以 sk- 开头，DeepSeek 开放平台获取'
ask_key AMAP_KEY '32 位字符，必须是「Web 服务」类型的 Key'

cat > "$ENV_FILE" <<EOF
DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY
AMAP_KEY=$AMAP_KEY
ALLOW_ORIGINS=http://$PUBLIC_IP:$NGINX_PORT
EOF
chmod 600 "$ENV_FILE"
log "密钥已写入 $ENV_FILE"

# ============================================================
# 5. 后端依赖
# ============================================================

log "创建 Python 虚拟环境并安装后端依赖"
cd "$APP_DIR/backend"
[[ -d venv ]] || python3 -m venv venv
./venv/bin/pip install --quiet --upgrade pip
./venv/bin/pip install --quiet -r requirements.txt

# ============================================================
# 6. 构建前端
# ============================================================

log "安装前端依赖并构建（首次需要几分钟，请耐心等待）"
cd "$APP_DIR/frontend"

# 前端与接口走同一个地址，同源访问不存在跨域问题。
# 同时写入 .env.local 并导出环境变量，避免打包时带进来的本地配置覆盖服务器地址。
FRONTEND_API_BASE="http://$PUBLIC_IP:$NGINX_PORT"
printf 'NEXT_PUBLIC_API_BASE=%s\n' "$FRONTEND_API_BASE" > .env.local
export NEXT_PUBLIC_API_BASE="$FRONTEND_API_BASE"

npm ci --no-audit --no-fund || npm install --no-audit --no-fund
npm run build

[[ -f "$APP_DIR/frontend/out/index.html" ]] || die "前端构建失败：没有生成 frontend/out/index.html"

WEB_ROOT="$APP_DIR/frontend/out"

# ============================================================
# 7. 注册开机自启服务
# ============================================================

log "配置 systemd 服务（服务会随开机自动启动）"

cat > /etc/systemd/system/tutor-backend.service <<EOF
[Unit]
Description=Tutor Assistant backend (FastAPI)
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR/backend
ExecStart=$APP_DIR/backend/venv/bin/python -m uvicorn main:app --host 127.0.0.1 --port $API_PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 前端是静态文件，由 nginx 直接提供，不需要单独的服务。
# 如果之前用旧版本脚本部署过，这里把遗留的前端服务清理掉。
systemctl disable tutor-frontend >/dev/null 2>&1 || true
rm -f /etc/systemd/system/tutor-frontend.service

systemctl daemon-reload
systemctl enable tutor-backend >/dev/null 2>&1 || true

# ============================================================
# 8. nginx：静态前端 + 接口反向代理
# ============================================================

log "配置 nginx，对外统一使用 $NGINX_PORT 端口"

cat > /etc/nginx/sites-available/tutor-assistant <<'NGINX_CONF'
server {
    listen __PORT__;
    server_name _;
    client_max_body_size 4m;

    root __WEB_ROOT__;
    index index.html;

    location /api/ {
        proxy_pass http://127.0.0.1:__API_PORT__;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
NGINX_CONF

sed -i "s|__PORT__|$NGINX_PORT|; s|__API_PORT__|$API_PORT|; s|__WEB_ROOT__|$WEB_ROOT|" \
  /etc/nginx/sites-available/tutor-assistant

ln -sf /etc/nginx/sites-available/tutor-assistant /etc/nginx/sites-enabled/tutor-assistant
# 移掉默认站点，避免 80 端口出现 nginx 欢迎页造成误解
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable nginx >/dev/null 2>&1 || true

# ============================================================
# 9. 启动服务
# ============================================================

log "启动 / 重启服务"
systemctl restart tutor-backend
systemctl restart nginx

# ============================================================
# 10. 防火墙
# ============================================================

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  log "检测到 ufw 已启用，放行 $NGINX_PORT 端口"
  ufw allow "$NGINX_PORT"/tcp >/dev/null 2>&1 || true
fi

# ============================================================
# 11. 自检
# ============================================================

log "等待服务就绪并自检"
OK_BACKEND="否"
OK_FRONTEND="否"
OK_PROXY="否"

for _ in $(seq 1 20); do
  if curl -fsS --max-time 3 "http://127.0.0.1:$API_PORT/" >/dev/null 2>&1; then
    OK_BACKEND="是"
    break
  fi
  sleep 2
done

# 通过 nginx 拿首页，并确认拿到的确实是应用的页面
for _ in $(seq 1 20); do
  if curl -fsS --max-time 3 "http://127.0.0.1:$NGINX_PORT/" 2>/dev/null | grep -q "家教出行助手"; then
    OK_FRONTEND="是"
    break
  fi
  sleep 2
done

# 验证 nginx 到后端的接口转发链路，同时确认密钥已生效
if curl -fsS --max-time 5 "http://127.0.0.1:$NGINX_PORT/api/health" >/dev/null 2>&1; then
  OK_PROXY="是"
fi

printf '  后端进程（127.0.0.1:%s）：%s\n' "$API_PORT" "$OK_BACKEND"
printf '  前端页面（nginx :%s）     ：%s\n' "$NGINX_PORT" "$OK_FRONTEND"
printf '  接口转发（/api/health）   ：%s\n' "$OK_PROXY"

if [[ "$OK_BACKEND" != "是" || "$OK_FRONTEND" != "是" || "$OK_PROXY" != "是" ]]; then
  warn "有检查项未通过，可用下面的命令定位问题："
  warn "  journalctl -u tutor-backend -n 50 --no-pager"
  warn "  nginx -t && journalctl -u nginx -n 50 --no-pager"
  warn "  curl -v http://127.0.0.1:$NGINX_PORT/api/health"
fi

# ============================================================
# 完成
# ============================================================

log "部署完成"

cat <<EOF

  访问地址：  http://$PUBLIC_IP:$NGINX_PORT
  把这个网址发给朋友和家长就能用了。

  常用命令：
    查看后端日志    journalctl -u tutor-backend -f
    重启后端        systemctl restart tutor-backend
    重载 nginx      systemctl reload nginx
    修改密钥        nano $ENV_FILE
                    systemctl restart tutor-backend
    检查服务状态    curl http://127.0.0.1:$NGINX_PORT/api/health

  ⚠️ 还有一步脚本改不了：去云厂商控制台的「防火墙 / 安全组」里
     放行 $NGINX_PORT 端口，否则外网访问不了。

EOF
