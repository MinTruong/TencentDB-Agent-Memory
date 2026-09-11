#!/usr/bin/env bash
# Khởi động riêng memory-core (kernel gateway, cổng 8420), lần đầu tự động init-admin +
# lưu user_key sinh ra vào .admin-key để proxy / claude-code dùng.
#
# Cách dùng:
#   ./start-memory-core.sh
#
# Dữ liệu lưu vào named volume (mặc định tdai-memory-core-data, có thể đổi MEMORY_CORE_VOLUME trong .env).
# Chạy lại sẽ xóa container cũ rồi khởi động mới, dữ liệu volume giữ lại —— admin user_key cũng giữ lại.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_env
require_vars MEMORY_CORE_IMAGE MEMORY_CORE_PORT MEMORY_CORE_VOLUME

# ── Thông tin quản trị nội bộ Gateway ────────────────────────────
# Dùng ${VAR-default} (không phải :-default): cho phép trong .env đặt chuỗi rỗng để tắt Bearer gate.
#
# Hiện tại Bearer gate của memory-core và auth của proxy có **xung đột đã biết**: proxy gọi
# /v3/meta/auth/verify không kèm Bearer (thiếu ở source, xem MemoryProxy/src/auth.ts),
# nên khi proxy bật auth thì bắt buộc để trống MEMORY_CORE_GATEWAY_API_KEY. Mặc định đã để trống.
MEMORY_CORE_GATEWAY_API_KEY="${MEMORY_CORE_GATEWAY_API_KEY-}"
MEMORY_CORE_ADMIN_USERNAME="${MEMORY_CORE_ADMIN_USERNAME:-admin}"

# Vị trí lưu user_key admin (phía host; sau khi xóa dữ liệu volume cần xóa luôn file này)
ADMIN_KEY_FILE="${MEMORY_CORE_ADMIN_KEY_FILE:-$SCRIPT_DIR/.admin-key}"

if [[ -n "$MEMORY_CORE_GATEWAY_API_KEY" ]]; then
  warn "MEMORY_CORE_GATEWAY_API_KEY không rỗng —— sessionInit/auth của proxy hiện sẽ fail vì thiếu Bearer."
  warn "Để trải nghiệm local, hãy để trống MEMORY_CORE_GATEWAY_API_KEY trong .env."
fi

CONTAINER=tdai-memory-core
NETWORK=tdai-memory-stack

# Tạo network dùng chung (idempotent)
if ! $DOCKER network inspect "$NETWORK" >/dev/null 2>&1; then
  info "Tạo docker network $NETWORK"
  $DOCKER network create "$NETWORK" >/dev/null
fi

pull_image "$MEMORY_CORE_IMAGE"
rm_container_if_exists "$CONTAINER"

# ── Sinh gateway config.yaml, mount vào container /data/config/tdai-gateway.yaml ──
# Image mặc định không có config, memory-core dùng mặc định lúc biên dịch (skill / knowledge module tắt).
# Từ MEMORY_LLM_* trong .env sinh ra một config tối thiểu standalone+skill.
CORE_CONFIG_DIR="${MEMORY_CORE_CONFIG_DIR:-$SCRIPT_DIR/.memory-core-config}"
mkdir -p "$CORE_CONFIG_DIR"
CORE_CONFIG_FILE="$CORE_CONFIG_DIR/tdai-gateway.yaml"
info "Sinh gateway config → $CORE_CONFIG_FILE"
cat > "$CORE_CONFIG_FILE" <<YAML
# Do start-memory-core.sh tự sinh —— bị ghi đè mỗi lần khởi động, đừng sửa tay.
deployMode: standalone
stateBackend: local

server:
  port: 8420
  host: 0.0.0.0

data:
  baseDir: /data/tdai-memory

llm:
  baseUrl: "${MEMORY_LLM_BASE_URL:-}"
  apiKey: "${MEMORY_LLM_API_KEY:-}"
  model: "${MEMORY_LLM_MODEL:-}"
  maxTokens: 32000
  timeoutMs: 300000

memory:
  # promptMode: chat (mặc định, kịch bản chat/giảng dạy thông thường) | code (kịch bản dự án code,
  # LLM sẽ ưu tiên trích "đã sửa gì/phát hiện vấn đề gì/cách dùng tool", chat thường có thể trích ra 0 dòng)
  # Ghi đè bằng MEMORY_PROMPT_MODE trong .env.
  promptMode: ${MEMORY_PROMPT_MODE:-chat}
  capture: { enabled: true }
  extraction:
    enabled: true
    enableDedup: true
    maxMemoriesPerSession: 20
  persona:
    triggerEveryN: 50
    maxScenes: 15
  pipeline:
    everyNConversations: 5
    enableWarmup: true
    l1IdleTimeoutSeconds: 600
    l2DelayAfterL1Seconds: 90
    l2MinIntervalSeconds: 900
    l2MaxIntervalSeconds: 3600
  recall:
    enabled: true
    maxResults: 5
    scoreThreshold: 0.3
    strategy: hybrid
    timeoutMs: 5000
  storeBackend: sqlite
  embedding:
    provider: none

# ── Module Skill ──
skill:
  enabled: true
  routing:
    mode: bm25
    searchTopK: 20
  extraction:
    enabled: true
    maxIterations: 16
    queue:
      backend: local
      keyPrefix: tdai
      resultTtlSeconds: 86400
      lockTtlMs: 600000
      maxRetries: 2
      retryBackoffsMs: [5000, 15000]
  resources:
    maxResourceSizeBytes: 5000000
YAML

info "Khởi động memory-core (image=$MEMORY_CORE_IMAGE, port=$MEMORY_CORE_PORT)"
# --restart unless-stopped: Docker daemon đã enabled nên container tự lên lại sau khi
# server reboot. Dùng "unless-stopped" (không phải "always") để tôn trọng ý định dừng
# thủ công — container bị `docker stop` sẽ không tự khởi động lại ở lần boot kế tiếp.
$DOCKER run -d --name "$CONTAINER" \
  --restart unless-stopped \
  --network "$NETWORK" \
  --network-alias memory-core \
  -p "${MEMORY_CORE_PORT}:8420" \
  -v "${MEMORY_CORE_VOLUME}:/data/tdai-memory" \
  -v "$CORE_CONFIG_FILE:/data/config/tdai-gateway.yaml:ro" \
  -e TDAI_GATEWAY_PORT=8420 \
  -e TDAI_GATEWAY_HOST=0.0.0.0 \
  -e TDAI_GATEWAY_API_KEY="$MEMORY_CORE_GATEWAY_API_KEY" \
  -e TDAI_DATA_DIR=/data/tdai-memory \
  "$MEMORY_CORE_IMAGE" >/dev/null

wait_healthy "$CONTAINER" 90
ok "memory-core đã khởi động → http://localhost:${MEMORY_CORE_PORT}/"

# ── Vòng đời admin user ──────────────────────────────────────────
# Lần đầu: init-admin **truyền user_key ngẫu nhiên do ta sinh**, đọc lại từ response rồi lưu file.
# Khởi động lại mà đã init rồi (409): ưu tiên đọc .admin-key; nếu volume mới tạo nhưng .admin-key
#   là cũ thì không khôi phục được (volume/key phải đồng bộ; nhắc người dùng dọn dẹp).
#
# Endpoint init-admin tôn trọng user_key truyền vào (xem MemoryCore/src/metadata/store/sqlite-adapter.ts
# defaultKeyValue = input.default_key_value ?? generateUserKey()); chỉ cần volume rỗng
# và ta truyền key cố định là lấy được key ta chỉ định. Lần đầu script sinh một key 32 byte
# base32url ngẫu nhiên —— mỗi máy/mỗi lần purge đều là key độc lập, không trùng nhau.

generate_user_key() {
  # sk-mem-<32 chars A-Za-z0-9>, khớp định dạng metadata/utils/user-key.ts
  # Dùng openssl (di động được; tr lọc bỏ +/= trong base64 còn 32 ký tự)
  local raw
  if command -v openssl >/dev/null 2>&1; then
    raw=$(openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32)
  else
    # Phương án dự phòng: đọc đủ urandom để sau khi lọc vẫn >=32
    raw=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 32)
  fi
  echo "sk-mem-${raw}"
}

verify_user_key() {
  local key="$1"
  local code
  code=$(/usr/bin/curl -sS -o /dev/null -w "%{http_code}" --max-time 5 \
    -X POST -H "Content-Type: application/json" \
    -H "x-tdai-service-id: default" \
    ${MEMORY_CORE_GATEWAY_API_KEY:+-H "Authorization: Bearer ${MEMORY_CORE_GATEWAY_API_KEY}"} \
    "http://localhost:${MEMORY_CORE_PORT}/v3/meta/auth/verify" \
    -d "$(printf '{"user_key":"%s"}' "$key")" 2>/dev/null || echo "000")
  [[ "$code" == "200" ]]
}

info "Khởi tạo admin user (username=${MEMORY_CORE_ADMIN_USERNAME}, key lưu → $ADMIN_KEY_FILE)..."

# Sinh key ngẫu nhiên (dùng lần đầu init-admin; nếu đã có file thì dùng lại)
if [[ -s "$ADMIN_KEY_FILE" ]]; then
  ADMIN_KEY=$(cat "$ADMIN_KEY_FILE")
  info "  Dùng lại admin key đã lưu (.admin-key đã tồn tại)"
else
  ADMIN_KEY=$(generate_user_key)
fi

init_body=$(printf '{"username":"%s","user_key":"%s"}' \
  "$MEMORY_CORE_ADMIN_USERNAME" "$ADMIN_KEY")
init_resp=$(/usr/bin/curl -sS -o /tmp/init-admin.$$ -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" \
  ${MEMORY_CORE_GATEWAY_API_KEY:+-H "Authorization: Bearer ${MEMORY_CORE_GATEWAY_API_KEY}"} \
  -H "x-tdai-service-id: default" \
  "http://localhost:${MEMORY_CORE_PORT}/v3/internal/meta/user/init-admin" \
  -d "$init_body" 2>/dev/null || echo "000")

case "$init_resp" in
  200)
    ok "admin user đã được tạo"
    # Ghi key xuống đĩa (thắt chặt quyền file trên host)
    umask 077
    echo -n "$ADMIN_KEY" > "$ADMIN_KEY_FILE"
    ok "  admin user_key đã lưu vào $ADMIN_KEY_FILE"
    ;;
  409)
    if [[ -s "$ADMIN_KEY_FILE" ]]; then
      ok "admin user đã tồn tại (bỏ qua init-admin, dùng key trong $ADMIN_KEY_FILE)"
    else
      warn "admin user đã tồn tại, nhưng thiếu $ADMIN_KEY_FILE nên không khôi phục được user_key."
      warn "Phương án A: dọn volume rồi dựng lại —— ./stop-all.sh --purge && ./start-memory-core.sh"
      warn "Phương án B: tự tạo admin user_key mới (cần key cũ hoặc gateway apiKey)"
    fi
    ;;
  *)
    warn "init-admin trả về HTTP=${init_resp}, có thể cần tự kiểm tra thêm:"
    cat /tmp/init-admin.$$ 2>/dev/null; echo
    ;;
esac
rm -f /tmp/init-admin.$$

# ── Kiểm tra admin key khả dụng ─────────────────────────────────
if [[ -s "$ADMIN_KEY_FILE" ]]; then
  ADMIN_KEY=$(cat "$ADMIN_KEY_FILE")
  if verify_user_key "$ADMIN_KEY"; then
    # Chỉ in đầu cuối để che bớt: mask cả chuỗi, không để giá trị đầy đủ trong lịch sử terminal
    masked="${ADMIN_KEY:0:11}****${ADMIN_KEY: -4}"
    ok "admin user_key kiểm tra qua (auth/verify 200) —— $masked"
    ok "  key file: $ADMIN_KEY_FILE"
  else
    warn "admin user_key kiểm tra thất bại (auth/verify khác 200). Kiểm tra $ADMIN_KEY_FILE với volume có khớp không."
  fi
fi
