#!/usr/bin/env bash
# Một lệnh khởi động bộ ba memory → memory-hub → proxy.
#
# Thứ tự: khởi động memory (kernel), chờ healthy; rồi memory-hub (panel + knowledge), chờ healthy;
# cuối cùng khởi động proxy. Bất kỳ bước nào thất bại đều dừng lại và in log container.
#
# Cách dùng:
#   ./start-all.sh            # máy đã có image thì dùng luôn
#   PULL=1 ./start-all.sh     # docker pull 3 image trước, nâng lên bản latest mới nhất
#
# Tiền đề: cp .env.example .env rồi điền đủ 2 nhóm tham số LLM (REPLACE_ME → giá trị thật).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_env

# Kiểm tra toàn bộ tham số bắt buộc trong 1 lần, tránh mo lên memory rồi mới phát hiện thiếu tham số proxy
require_vars \
  MEMORY_CORE_IMAGE MEMORY_HUB_IMAGE PROXY_IMAGE \
  MEMORY_CORE_PORT PANEL_PORT KNOWLEDGE_PORT PROXY_PORT \
  MEMORY_CORE_VOLUME PANEL_VOLUME \
  MEMORY_LLM_BASE_URL MEMORY_LLM_API_KEY MEMORY_LLM_MODEL \
  KNOWLEDGE_PUBLIC_BASE_URL \
  PROXY_UPSTREAM_URL PROXY_UPSTREAM_API_KEY PROXY_UPSTREAM_MODEL

info "═══ Bước 1/3: memory ═══════════════════════════════════════"
"$SCRIPT_DIR/start-memory-core.sh"

info "═══ Bước 2/3: memory-hub ═══════════════════════════════════"
"$SCRIPT_DIR/start-memory-hub.sh"

info "═══ Bước 3/3: proxy ════════════════════════════════════════"
# Mặc định mở full pipeline (auth + sessionInit + tdai inject).
# Người dùng có thể tắt bằng PROXY_FULL_STACK=0; hoặc override riêng từng công tắc trong .env.
PROXY_FULL_STACK="${PROXY_FULL_STACK:-1}" "$SCRIPT_DIR/start-proxy.sh"

ok "═══ Toàn bộ dịch vụ đã sẵn sàng ══════════════════════════════"
print_endpoints

# In lệnh dùng Claude Code / proxy
ADMIN_KEY_FILE="${MEMORY_CORE_ADMIN_KEY_FILE:-$SCRIPT_DIR/.admin-key}"
if [[ -s "$ADMIN_KEY_FILE" ]]; then
  ADMIN_KEY=$(cat "$ADMIN_KEY_FILE")
  UPSTREAM_MODEL="${PROXY_UPSTREAM_MODEL:-<your-model>}"
  echo ""
  echo "  ┌─ Dùng Claude Code qua proxy ───────────────────────────────────┐"
  echo "  │  export ANTHROPIC_BASE_URL=http://127.0.0.1:${PROXY_PORT}/claude-code/default"
  echo "  │  export ANTHROPIC_AUTH_TOKEN='${ADMIN_KEY}'"
  echo "  │  claude --model ${UPSTREAM_MODEL}"
  echo "  │"
  echo "  │  admin user_key được lưu tại: $ADMIN_KEY_FILE"
  echo "  └────────────────────────────────────────────────────────────────┘"
fi
echo ""
echo "  Xem log:    docker logs -f tdai-memory-core | tdai-memory-hub | tdai-proxy"
echo "  Dừng dịch vụ: ./stop-all.sh"
echo ""
