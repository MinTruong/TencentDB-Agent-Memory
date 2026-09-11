#!/usr/bin/env bash
# Khởi động riêng memory-hub (image gộp panel + knowledge, cổng 8125 + 8424).
#
# Phụ thuộc: memory cần chạy trước (knowledge trong memory-hub gọi memory để embed/RAG).
# Nếu container memory chưa tồn tại, script này sẽ warn nhưng vẫn tiếp tục (khi LLM_MODE=proxy
# memory-hub tự khởi động được, chỉ là knowledge gọi memory lần đầu sẽ fail).
#
# Cách dùng:
#   ./start-memory-hub.sh
#
# Cần các tham số LLM sau (ghi trong .env):
#   MEMORY_LLM_BASE_URL / MEMORY_LLM_API_KEY / MEMORY_LLM_MODEL

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_env
require_vars \
  MEMORY_HUB_IMAGE PANEL_PORT KNOWLEDGE_PORT PANEL_VOLUME \
  MEMORY_LLM_BASE_URL MEMORY_LLM_API_KEY MEMORY_LLM_MODEL \
  KNOWLEDGE_PUBLIC_BASE_URL

# Thông tin quản trị gateway khớp với memory-core (mặc định local, chỉ dùng trải nghiệm local)
MEMORY_CORE_GATEWAY_API_KEY="${MEMORY_CORE_GATEWAY_API_KEY:-local}"

# Base URL hiển thị trong thẻ "Địa chỉ kết nối client" của Panel UI (để CodeBuddy / ClaudeCode copy).
# Deploy local open source core và proxy chạy riêng, client cần kết nối tới proxy, không phải core/gateway.
#
# Mặc định dò địa chỉ host có thể truy cập từ bên ngoài theo thứ tự:
#   1) trên Linux `hostname -I` IPv4 đầu tiên khác 127 (LAN IP)
#   2) trên macOS các card mạng thường gặp (en0 / en1) IPv4
#   3) cả hai bước trên fail → localhost (chỉ dùng được trên cùng máy; dùng khác máy cần người dùng
#      đặt tường minh MEMORY_HUB_PROXY_PUBLIC_URL)
#
# Nếu đã đặt biến env MEMORY_HUB_PROXY_PUBLIC_URL thì hoàn toàn theo giá trị bạn cho.
# Đặt tường minh là chuỗi rỗng thì frontend Panel về hành vi cũ là fallback về gateway_endpoint.
# Địa chỉ Panel backend → Kernel chuyển tiếp luôn đi theo REMOTE_INSTANCE_URL, không bị ảnh hưởng bởi biến này.
detect_host_ip() {
  local ip=""
  # Linux
  if command -v hostname >/dev/null 2>&1; then
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^[0-9]+\./ && $0 !~ /^127\./ && $0 !~ /^169\.254\./' | head -n1)
    [[ -n "$ip" ]] && { echo "$ip"; return; }
  fi
  # macOS
  if command -v ipconfig >/dev/null 2>&1; then
    for iface in en0 en1 en2; do
      ip=$(ipconfig getifaddr "$iface" 2>/dev/null)
      [[ -n "$ip" ]] && { echo "$ip"; return; }
    done
  fi
  # Phương án dự phòng: ip route (khi Linux không có hostname -I)
  if command -v ip >/dev/null 2>&1; then
    ip=$(ip -4 route get 1 2>/dev/null | awk '/src/ {for (i=1;i<=NF;i++) if ($i=="src") print $(i+1); exit}')
    [[ -n "$ip" ]] && { echo "$ip"; return; }
  fi
  echo "localhost"
}

if [[ -z "${MEMORY_HUB_PROXY_PUBLIC_URL+x}" ]]; then
  # Chưa đặt → dùng IP dò được + PROXY_PORT ghép giá trị mặc định
  _host_ip=$(detect_host_ip)
  MEMORY_HUB_PROXY_PUBLIC_URL="http://${_host_ip}:${PROXY_PORT:-8096}"
  info "Tự dò địa chỉ host: MEMORY_HUB_PROXY_PUBLIC_URL=$MEMORY_HUB_PROXY_PUBLIC_URL"
  info "  (muốn ghi đè, đặt tường minh MEMORY_HUB_PROXY_PUBLIC_URL=http://<your-ip>:${PROXY_PORT:-8096} trong .env)"
fi

CONTAINER=tdai-memory-hub
NETWORK=tdai-memory-stack

if ! $DOCKER network inspect "$NETWORK" >/dev/null 2>&1; then
  info "Tạo docker network $NETWORK"
  $DOCKER network create "$NETWORK" >/dev/null
fi

# Nhắc nhở khi memory chưa chạy, không chặn
if ! $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "tdai-memory-core"; then
  warn "container memory-core chưa chạy. memory-hub vẫn khởi động được, nhưng knowledge gọi memory sẽ fail."
  warn "Đề nghị chạy ./start-memory-core.sh trước rồi quay lại đây, hoặc chạy trực tiếp ./start-all.sh"
fi

pull_image "$MEMORY_HUB_IMAGE"
rm_container_if_exists "$CONTAINER"

# Knowledge bên trong gọi LLM qua upstream memory theo custom mode, trỏ thẳng tới MEMORY_LLM_*
# LLM_MODE=custom → không đi qua LLM proxy của memory, mà knowledge nối thẳng tới endpoint người dùng cấp
#
# SSH key mount: để Git clone được repo private qua SSH.
#   - Mount vào /home/node/.ssh (user `node` là user chạy service bên trong image).
#   - KHÔNG mount known_hosts (read-only sẽ khiến ssh không ghi được → warning mỗi lần clone);
#     thay vào đó trỏ UserKnownHostsFile vào file ghi được trong /home/node/.ssh.
info "Khởi động memory-hub (image=$MEMORY_HUB_IMAGE, panel=$PANEL_PORT knowledge=$KNOWLEDGE_PORT)"
# --restart unless-stopped: tự lên lại sau reboot (xem chú thích trong start-memory-core.sh).
# Lưu ý: restart chỉ chạy lại container cũ, KHÔNG chạy lại script này — nên openssh-client
# và /etc/gitconfig (cài bên dưới) vẫn còn nguyên vì nằm trong layer của container.
$DOCKER run -d --name "$CONTAINER" \
  --restart unless-stopped \
  --network "$NETWORK" \
  --network-alias memory-hub \
  --add-host=host.docker.internal:host-gateway \
  -p "${PANEL_PORT}:8125" \
  -p "${KNOWLEDGE_PORT}:8424" \
  -v "${PANEL_VOLUME}:/data/knowledge" \
  -v "$HOME/.ssh/id_rsa:/home/node/.ssh/id_rsa:ro" \
  -e GIT_SSH_COMMAND="ssh -i /home/node/.ssh/id_rsa -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/home/node/.ssh/known_hosts" \
  -e PANEL_PORT=8125 \
  -e KNOWLEDGE_PORT=8424 \
  -e KNOWLEDGE_PUBLIC_BASE_URL="$KNOWLEDGE_PUBLIC_BASE_URL" \
  -e REMOTE_INSTANCE_ID=default \
  -e REMOTE_INSTANCE_NAME=default \
  -e REMOTE_INSTANCE_URL="http://memory-core:8420" \
  -e REMOTE_INSTANCE_KEY="$MEMORY_CORE_GATEWAY_API_KEY" \
  -e REMOTE_INSTANCE_PROXY_URL="$MEMORY_HUB_PROXY_PUBLIC_URL" \
  -e LLM_MODE=custom \
  -e LLM_PROTOCOL="${MEMORY_LLM_PROTOCOL:-openai}" \
  -e LLM_API_KEY="$MEMORY_LLM_API_KEY" \
  -e LLM_BASE_URL="$MEMORY_LLM_BASE_URL" \
  -e LLM_MODEL="$MEMORY_LLM_MODEL" \
  -e KNOWLEDGE_LLM_BINDING_SYNC=0 \
  "$MEMORY_HUB_IMAGE" >/dev/null

wait_healthy "$CONTAINER" 120

# ── Hậu cấu hình trong container ─────────────────────────────────────────────
# 1) openssh-client: image gốc không có binary `ssh`, nên Git không clone được qua SSH.
docker exec "$CONTAINER" apt-get update -qq >/dev/null 2>&1 || true
docker exec "$CONTAINER" apt-get install -y openssh-client -qq >/dev/null 2>&1 || true

# 2) Git rewrite HTTPS → SSH.
#    Cho phép nhập URL dạng https://gitlab.com/... trên Panel UI nhưng Git sẽ clone
#    bằng SSH key đã mount. Đặt ở /etc/gitconfig (system level) để áp dụng cho MỌI
#    user/HOME trong container — kể cả process chạy bằng root mà không có HOME riêng.
docker exec "$CONTAINER" sh -c 'cat > /etc/gitconfig <<EOF
[url "git@gitlab.com:"]
	insteadOf = https://gitlab.com/
[url "git@gitlab.com:"]
	insteadOf = http://gitlab.com/
EOF' || true

ok "memory-hub đã khởi động"
ok "  Panel UI  → http://localhost:${PANEL_PORT}/"
ok "  KS Health → http://localhost:${KNOWLEDGE_PORT}/health"