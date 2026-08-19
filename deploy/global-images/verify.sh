#!/usr/bin/env bash
# Kiểm tra khô: không khởi động container nào, chỉ kiểm tra môi trường đã sẵn sàng chưa.
#
# Cách dùng:
#   ./verify.sh               # kiểm tra toàn bộ (bao gồm kiểm tra trước đường truyền LLM)
#   ./verify.sh --skip-llm    # bỏ qua kiểm tra LLM (môi trường offline hoặc không muốn gửi request ra ngoài)
#
# Các mục kiểm tra:
#   1. Lệnh docker khả dụng
#   2. File .env tồn tại
#   3. Mọi biến bắt buộc trong .env đã điền (khác REPLACE_ME và không rỗng)
#   4. Ba image đã có sẵn trên máy chưa (chưa có không tính lỗi, chỉ warn)
#   5. Cổng đích có bị chiếm không
#   6. Đường truyền LLM upstream (nhóm memory + nhóm proxy, kiểm tra riêng từng nhóm)
#      - protocol openai: GET {base}/models, không tốn token
#      - protocol anthropic: POST {base}/v1/messages max_tokens=1, tốn ≤ 10 token
#      - nếu container đã chạy, chạy thêm docker exec từ trong container (xác minh container → LLM kết nối được)
#
# Toàn bộ qua → exit 0; có lỗi → exit 1; chỉ warn → exit 0

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

SKIP_LLM=0
for arg in "$@"; do
  case "$arg" in
    --skip-llm) SKIP_LLM=1 ;;
    --help|-h)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *) warn "Tham số không xác định: ${arg} (bỏ qua)" ;;
  esac
done

ERRORS=0
WARNS=0
CURL=/usr/bin/curl

# ─── Hàm kiểm tra đường truyền LLM ─────────────────────────────────
# check_llm_openai <label> <base_url> <api_key> <model>
#   Tương thích OpenAI: GET {base}/models chỉ xác minh auth+URL, không tốn token.
#   base_url cho phép có hoặc không có /v1; ở đây làm chuẩn hóa.
check_llm_openai() {
  local label="$1" base="$2" key="$3" model="$4"
  # Chuẩn hóa: bỏ / ở cuối, bỏ hậu tố /messages hoặc /chat/completions
  base="${base%/}"
  base="${base%/messages}"
  base="${base%/chat/completions}"
  local url="${base}/models"
  local code body_file=/tmp/llm-check.$$
  code=$("$CURL" -sS --max-time 10 -o "$body_file" -w "%{http_code}" \
    -H "Authorization: Bearer $key" \
    "$url" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    # Thử phân tích model có nằm trong danh sách không (so khớp lỏng, không khớp chỉ warn)
    if grep -q "\"$model\"" "$body_file" 2>/dev/null; then
      ok "$label đường truyền OpenAI protocol OK（$model có trong danh sách /models）"
    else
      ok "$label đường truyền OpenAI protocol OK（${model} không được liệt kê trong /models，nghiệp vụ vẫn có thể dùng được）"
    fi
    rm -f "$body_file"
    return 0
  elif [[ "$code" == "401" || "$code" == "403" ]]; then
    echo "${C_RED}[error]${C_RST} $label API key không hợp lệ (HTTP ${code}): $url" >&2
    head -c 200 "$body_file" >&2; echo >&2
    rm -f "$body_file"
    return 1
  elif [[ "$code" == "404" ]]; then
    # Một số nhà cung cấp không có endpoint /models, chuyển sang kiểu anthropic hoặc bỏ qua: warn không error
    warn "$label GET /models 404 —— nhà cung cấp này có thể không có endpoint này, chuyển sang kiểm tra theo protocol anthropic"
    check_llm_anthropic "$label" "$base" "$key" "$model"
    rm -f "$body_file"
    return $?
  else
    warn "$label không truy cập được ${url} (HTTP=${code}) $(head -c 100 "$body_file" 2>/dev/null)"
    rm -f "$body_file"
    return 1
  fi
}

# check_llm_anthropic <label> <base_url> <api_key> <model>
#   Anthropic: POST {base}/v1/messages gửi max_tokens=1, tốn ≤ 10 token nhưng xác minh được đồng thời URL/auth/model.
check_llm_anthropic() {
  local label="$1" base="$2" key="$3" model="$4"
  base="${base%/}"
  # Chuẩn hóa: nếu đã chứa /messages thì dùng thẳng; ngược lại ghép /v1/messages
  local url
  if [[ "$base" == */messages ]]; then
    url="$base"
  elif [[ "$base" == */v1 ]]; then
    url="${base}/messages"
  else
    url="${base}/v1/messages"
  fi
  local code body_file=/tmp/llm-check.$$
  code=$("$CURL" -sS --max-time 15 -o "$body_file" -w "%{http_code}" \
    -X POST -H "Content-Type: application/json" \
    -H "x-api-key: $key" \
    -H "Authorization: Bearer $key" \
    -H "anthropic-version: 2023-06-01" \
    -d "{\"model\":\"$model\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" \
    "$url" 2>/dev/null || echo "000")
  case "$code" in
    200)
      ok "$label đường truyền Anthropic protocol OK (model $model đã phản hồi)"
      rm -f "$body_file"; return 0 ;;
    401|403)
      echo "${C_RED}[error]${C_RST} $label API key không hợp lệ (HTTP ${code}): $url" >&2
      head -c 200 "$body_file" >&2; echo >&2
      rm -f "$body_file"; return 1 ;;
    404)
      echo "${C_RED}[error]${C_RST} $label URL không tồn tại (HTTP 404): $url —— kiểm tra BASE_URL" >&2
      rm -f "$body_file"; return 1 ;;
    400)
      # 400 thường gặp khi tên model không tồn tại hoặc kiểm tra body thất bại
      if grep -qE "model.*not.*found|invalid.*model|model_not_found" "$body_file" 2>/dev/null; then
        echo "${C_RED}[error]${C_RST} $label tên model '$model' không hợp lệ (HTTP 400)" >&2
        rm -f "$body_file"; return 1
      fi
      warn "$label HTTP 400 (có thể do sai định dạng tham số, không phải lỗi đường truyền): $(head -c 150 "$body_file")"
      rm -f "$body_file"; return 0 ;;
    *)
      warn "$label không truy cập được ${url} (HTTP=${code}) $(head -c 100 "$body_file" 2>/dev/null)"
      rm -f "$body_file"; return 1 ;;
  esac
}

# check_llm_group <label> <base_url> <api_key> <model> <protocol>
check_llm_group() {
  local label="$1" base="$2" key="$3" model="$4" proto="${5:-openai}"
  info "Kiểm tra đường truyền $label (protocol=${proto}, base=${base}, model=${model})..."
  case "$proto" in
    anthropic) check_llm_anthropic "$label" "$base" "$key" "$model" ;;
    *)         check_llm_openai    "$label" "$base" "$key" "$model" ;;
  esac
}

# Xác minh curl từ trong container (tùy chọn, chỉ làm khi container đã chạy)
check_llm_from_container() {
  local container="$1" label="$2" base="$3" key="$4" model="$5" proto="${6:-openai}"
  if ! $DOCKER ps --format '{{.Names}}' | grep -qx "$container"; then
    return 0  # container chưa chạy, bỏ qua (không phải lỗi)
  fi
  info "  ↳ Thử gọi lại $label từ bên trong container $container..."
  # Trọng tâm là "kết nối mạng có tới được không": chỉ cần nhận được bất kỳ mã HTTP nào là thông; 000 mới tính là không tới được.
  # Lỗi auth đã báo ở phía host rồi, trong container không báo error lại nữa.
  local url code
  case "$proto" in
    anthropic)
      base="${base%/}"; [[ "$base" == */messages ]] || base="${base}/v1/messages"
      url="$base"
      code=$($DOCKER exec "$container" curl -sS -o /dev/null --max-time 15 \
         -w "%{http_code}" -X POST -H "Content-Type: application/json" \
         -H "x-api-key: $key" -H "anthropic-version: 2023-06-01" \
         -d "{\"model\":\"$model\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" \
         "$url" 2>/dev/null || echo "000")
      ;;
    *)
      base="${base%/}"; base="${base%/v1}"
      url="${base}/v1/models"
      code=$($DOCKER exec "$container" curl -sS -o /dev/null --max-time 10 \
         -w "%{http_code}" -H "Authorization: Bearer $key" "$url" 2>/dev/null || echo "000")
      ;;
  esac
  if [[ "$code" == "000" ]]; then
    warn "  container ${container} không truy cập được ${url} (cô lập mạng / lỗi DNS)"
    WARNS=$((WARNS+1))
  else
    ok "  container ${container} → $label kết nối mạng tới được (HTTP ${code})"
  fi
}

# 1. docker
if command -v "$DOCKER" >/dev/null 2>&1 || [[ -x "$DOCKER" ]]; then
  ok "docker khả dụng: $DOCKER"
else
  ERRORS=$((ERRORS+1))
  echo "${C_RED}[error]${C_RST} docker không khả dụng" >&2
fi

# 2. .env
if [[ ! -f "$ENV_FILE" ]]; then
  ERRORS=$((ERRORS+1))
  echo "${C_RED}[error]${C_RST} $ENV_FILE không tồn tại. Chạy: cp .env.example .env" >&2
else
  ok ".env tồn tại"
  set -a; source "$ENV_FILE"; set +a

  # 3. Các tham số bắt buộc
  MISSING=()
  for var in \
    MEMORY_CORE_IMAGE MEMORY_HUB_IMAGE PROXY_IMAGE \
    MEMORY_CORE_PORT PANEL_PORT KNOWLEDGE_PORT PROXY_PORT \
    MEMORY_CORE_VOLUME PANEL_VOLUME \
    MEMORY_LLM_BASE_URL MEMORY_LLM_API_KEY MEMORY_LLM_MODEL \
    KNOWLEDGE_PUBLIC_BASE_URL \
    PROXY_UPSTREAM_URL PROXY_UPSTREAM_API_KEY PROXY_UPSTREAM_MODEL; do
    val="${!var:-}"
    if [[ -z "$val" || "$val" == "REPLACE_ME" ]]; then
      MISSING+=("$var")
    fi
  done
  if (( ${#MISSING[@]} > 0 )); then
    ERRORS=$((ERRORS+1))
    echo "${C_RED}[error]${C_RST} Các tham số bắt buộc sau chưa được đặt: ${MISSING[*]}" >&2
  else
    ok "Mọi tham số bắt buộc đã được điền"
  fi

  # 4. Image đã có sẵn trên máy chưa
  for img_var in MEMORY_CORE_IMAGE MEMORY_HUB_IMAGE PROXY_IMAGE; do
    img="${!img_var:-}"
    if [[ -z "$img" ]]; then continue; fi
    if $DOCKER image inspect "$img" >/dev/null 2>&1; then
      ok "Image đã có trên máy: $img"
    else
      WARNS=$((WARNS+1))
      warn "Image chưa có trên máy, lúc khởi động sẽ pull: $img"
    fi
  done

  # 5. Cổng bị chiếm (chỉ nhắc nhở)
  for port_var in MEMORY_CORE_PORT PANEL_PORT KNOWLEDGE_PORT PROXY_PORT; do
    port="${!port_var:-}"
    if [[ -z "$port" ]]; then continue; fi
    if lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      WARNS=$((WARNS+1))
      warn "Cổng $port ($port_var) đã bị chiếm, trước khi khởi động hãy giải phóng hoặc đổi cổng trong .env"
    else
      ok "Cổng $port ($port_var) còn trống"
    fi
  done

  # 6. Đường truyền LLM (kiểm tra mặc định, --skip-llm để bỏ qua)
  if (( SKIP_LLM == 1 )); then
    info "Bỏ qua kiểm tra đường truyền LLM (--skip-llm)"
  elif (( ${#MISSING[@]} > 0 )); then
    warn "Bỏ qua kiểm tra đường truyền LLM (các tham số bắt buộc chưa điền đủ)"
  else
    echo ""
    info "═══ Kiểm tra đường truyền LLM ═══════════════════════════════════════"

    # nhóm memory
    if ! check_llm_group "nhóm memory" "$MEMORY_LLM_BASE_URL" "$MEMORY_LLM_API_KEY" \
         "$MEMORY_LLM_MODEL" "${MEMORY_LLM_PROTOCOL:-openai}"; then
      ERRORS=$((ERRORS+1))
    fi
    # container đã chạy thì xác minh thêm từ trong container
    check_llm_from_container tdai-memory-hub "nhóm memory (từ container)" \
      "$MEMORY_LLM_BASE_URL" "$MEMORY_LLM_API_KEY" "$MEMORY_LLM_MODEL" \
      "${MEMORY_LLM_PROTOCOL:-openai}"

    # nhóm proxy (nếu giá trị giống hệt nhóm memory, tức là người dùng điền cùng một bộ, chỉ kiểm tra 1 lần)
    if [[ "$PROXY_UPSTREAM_URL" == "$MEMORY_LLM_BASE_URL" && \
          "$PROXY_UPSTREAM_API_KEY" == "$MEMORY_LLM_API_KEY" && \
          "$PROXY_UPSTREAM_MODEL" == "$MEMORY_LLM_MODEL" ]]; then
      ok "nhóm proxy giống hệt nhóm memory, bỏ qua kiểm tra lặp lại"
    else
      # nhóm proxy mặc định theo protocol openai (khớp với config.yaml)
      if ! check_llm_group "nhóm proxy" "$PROXY_UPSTREAM_URL" "$PROXY_UPSTREAM_API_KEY" \
           "$PROXY_UPSTREAM_MODEL" openai; then
        ERRORS=$((ERRORS+1))
      fi
      check_llm_from_container tdai-proxy "nhóm proxy (từ container)" \
        "$PROXY_UPSTREAM_URL" "$PROXY_UPSTREAM_API_KEY" "$PROXY_UPSTREAM_MODEL" openai
    fi
  fi
fi

echo ""
if (( ERRORS > 0 )); then
  echo "${C_RED}✗ ${ERRORS} lỗi, ${WARNS} cảnh báo —— không thể khởi động${C_RST}" >&2
  exit 1
elif (( WARNS > 0 )); then
  echo "${C_YLW}⚠ ${WARNS} cảnh báo —— có thể khởi động, nhưng hãy chú ý các gợi ý ở trên${C_RST}"
  exit 0
else
  echo "${C_GRN}✓ Toàn bộ kiểm tra đã qua —— có thể chạy ./start-all.sh${C_RST}"
  exit 0
fi
