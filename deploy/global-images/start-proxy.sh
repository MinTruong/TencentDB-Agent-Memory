#!/usr/bin/env bash
# Khởi động riêng proxy (context-proxy, cổng 8096).
#
# Upstream chuyển tiếp của proxy đi theo PROXY_UPSTREAM_URL (độc lập với MEMORY_LLM_* của nhóm memory).
# Proxy gọi memory:8420 để làm auth / skill / tdai memory inject; gọi memory-hub:8125
# làm control plane sessionInit. Có thể chạy proxy riêng nhưng các khả năng tương ứng sẽ bị giảm/tắt.
#
# Cách dùng:
#   ./start-proxy.sh
#
# Cần các tham số nhóm proxy sau (ghi trong .env):
#   PROXY_UPSTREAM_URL / PROXY_UPSTREAM_API_KEY / PROXY_UPSTREAM_MODEL

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

load_env
require_vars \
  PROXY_IMAGE PROXY_PORT \
  PROXY_UPSTREAM_URL PROXY_UPSTREAM_API_KEY PROXY_UPSTREAM_MODEL

# Thông tin quản trị gateway khớp với memory-core (mặc định local, chỉ dùng trải nghiệm local)
MEMORY_CORE_GATEWAY_API_KEY="${MEMORY_CORE_GATEWAY_API_KEY:-local}"

CONTAINER=tdai-proxy
NETWORK=tdai-memory-stack

if ! $DOCKER network inspect "$NETWORK" >/dev/null 2>&1; then
  info "Tạo docker network $NETWORK"
  $DOCKER network create "$NETWORK" >/dev/null
fi

# Kiểm tra phụ thuộc (không chặn, chỉ nhắc)
if ! $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "tdai-memory-core"; then
  warn "container memory-core chưa chạy, auth / tdai memory / skill inject của proxy sẽ đều bị giảm."
fi
if ! $DOCKER ps --format '{{.Names}}' 2>/dev/null | grep -qx "tdai-memory-hub"; then
  warn "container memory-hub chưa chạy, control plane sessionInit của proxy không tới được."
fi

pull_image "$PROXY_IMAGE"
rm_container_if_exists "$CONTAINER"

# Proxy chỉ đọc upstream URL / API key từ YAML (không nhận biến env PROXY_UPSTREAM_URL),
# nên ta từ .env sinh ra một config.yaml tối thiểu mount vào container /data/config.yaml.
# CMD của container đã là [--config /data/config.yaml].
CONFIG_DIR="${PROXY_CONFIG_DIR:-$SCRIPT_DIR/.proxy-config}"
mkdir -p "$CONFIG_DIR"
CONFIG_FILE="$CONFIG_DIR/config.yaml"

# ── Ba công tắc khả năng (mặc định tối thiểu dùng được; bật sẽ tự nối các phụ thuộc) ──
# PROXY_ENABLE_AUTH        : client dùng x-tdai-user-key đi kernel auth/verify → user_id
# PROXY_ENABLE_SESSION_INIT: lượt đầu hiện form chọn team/agent/task; phụ thuộc auth+tdai
# PROXY_ENABLE_TDAI        : inject L2/L3 memory + recall L1; phụ thuộc memory-core
#
# Công tắc tiện lợi PROXY_FULL_STACK=1 mở cả ba chỉ với một lệnh.
if [[ "${PROXY_FULL_STACK:-0}" == "1" ]]; then
  PROXY_ENABLE_AUTH=1
  PROXY_ENABLE_TDAI=1
  PROXY_ENABLE_SESSION_INIT=1
fi
PROXY_ENABLE_AUTH="${PROXY_ENABLE_AUTH:-0}"
PROXY_ENABLE_TDAI="${PROXY_ENABLE_TDAI:-0}"
PROXY_ENABLE_SESSION_INIT="${PROXY_ENABLE_SESSION_INIT:-0}"

# sessionInit phụ thuộc auth để lấy user_id; bật sessionInit thì tự bật thêm auth
if [[ "$PROXY_ENABLE_SESSION_INIT" == "1" && "$PROXY_ENABLE_AUTH" != "1" ]]; then
  warn "PROXY_ENABLE_SESSION_INIT=1 cần auth; tự động bật PROXY_ENABLE_AUTH"
  PROXY_ENABLE_AUTH=1
fi

bool() { [[ "$1" == "1" ]] && echo "true" || echo "false"; }

info "Sinh proxy config → $CONFIG_FILE  (auth=$(bool $PROXY_ENABLE_AUTH) session-init=$(bool $PROXY_ENABLE_SESSION_INIT) tdai=$(bool $PROXY_ENABLE_TDAI))"
cat > "$CONFIG_FILE" <<YAML
# Do start-proxy.sh tự sinh —— bị ghi đè mỗi lần khởi động, đừng sửa tay.
server:
  host: 0.0.0.0
  port: 8096
  forwardTimeoutMs: 600000

upstream:
  url: "${PROXY_UPSTREAM_URL}"
  apiKey: "${PROXY_UPSTREAM_API_KEY}"

log:
  file: ""
  level: info
  backend: console

# Kết nối kernel tdai (dùng cho injection / skill / auth)
tdai:
  enabled: $(bool $PROXY_ENABLE_TDAI)
  endpoint: "http://memory-core:8420"
  apiKey: "${MEMORY_CORE_GATEWAY_API_KEY}"
  serviceId: default
  memory:
    enabled: true
    inject: true
    writeL0: true
    recallL1: true
    injectL2L3: true

skill:
  endpoint: "http://memory-core:8420"
  serviceToken: "${MEMORY_CORE_GATEWAY_API_KEY}"

auth:
  enabled: $(bool $PROXY_ENABLE_AUTH)
  url: "http://memory-core:8420"
  timeoutMs: 5000

sessionInit:
  enabled: $(bool $PROXY_ENABLE_SESSION_INIT)
  maxRetries: 3
  injectAgentContext: true
  injectTaskContext: true
  headerAutoSelect:
    enabled: true
    teamHeader: "x-team-id"
    agentHeader: "x-agent-id"
    taskHeader: "x-task-id"
    onMismatch: "form"

costGuard:
  enabled: false

# Bật ba injector skill + knowledge + tdai-memory;
# knowledge phụ thuộc memory-hub đã chạy, nếu không hook bên trong sẽ giảm thành khối rỗng.
injection:
  enabled: true
  injectors:
    - skill
    - knowledge
    - tdai-memory

redis:
  enabled: false
YAML

info "Khởi động proxy (image=$PROXY_IMAGE, port=$PROXY_PORT)"
$DOCKER run -d --name "$CONTAINER" \
  --network "$NETWORK" \
  --network-alias proxy \
  --add-host=host.docker.internal:host-gateway \
  -p "${PROXY_PORT}:8096" \
  -v "$CONFIG_FILE:/data/config.yaml:ro" \
  "$PROXY_IMAGE" >/dev/null

wait_healthy "$CONTAINER" 90
ok "proxy đã khởi động → http://localhost:${PROXY_PORT}/"
ok "  Cách dùng: trỏ API base của coding agent tới http://localhost:${PROXY_PORT}"
