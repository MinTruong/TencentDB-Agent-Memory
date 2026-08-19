#!/usr/bin/env bash
# Các hàm tiện ích dùng chung: load .env, kiểm tra tham số bắt buộc, chờ container healthy, dọn container cũ.
# Được các start-*.sh gọi qua `source _lib.sh`, không chạy độc lập.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

# Màu sắc
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'; C_BLU=$'\033[34m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""
fi

info() { echo "${C_BLU}[$(date +%H:%M:%S)]${C_RST} $*"; }
ok()   { echo "${C_GRN}[ok]${C_RST} $*"; }
warn() { echo "${C_YLW}[warn]${C_RST} $*" >&2; }
die()  { echo "${C_RED}[error]${C_RST} $*" >&2; exit 1; }

# Load .env (hướng dẫn khi chưa tạo)
load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    die ".env không tồn tại. Hãy chạy cp .env.example .env rồi điền các tham số LLM."
  fi
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

# Kiểm tra một nhóm biến bắt buộc; thiếu bất kỳ biến nào đều không khởi động, liệt kê toàn bộ biến thiếu trong 1 lần
require_vars() {
  local missing=()
  for var in "$@"; do
    local val="${!var:-}"
    if [[ -z "$val" || "$val" == "REPLACE_ME" ]]; then
      missing+=("$var")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    echo "${C_RED}[error]${C_RST} Các tham số bắt buộc sau trong .env chưa được đặt hoặc vẫn là REPLACE_ME:" >&2
    for v in "${missing[@]}"; do echo "  - $v" >&2; done
    echo "" >&2
    echo "  Sửa $ENV_FILE rồi thử lại." >&2
    exit 1
  fi
}

# Tìm lệnh docker khả dụng (tương thích Homebrew cài riêng + colima)
# Ưu tiên: docker trong PATH → Homebrew apple silicon → Homebrew intel → /usr/local
# Trong đường dẫn Homebrew Cellar, glob theo phiên bản, lấy mới nhất (sort -V), tránh hardcode phiên bản nhỏ.
find_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "docker"
    return
  fi
  local candidate
  for prefix in /opt/homebrew/Cellar/docker /usr/local/Cellar/docker; do
    if [[ -d "$prefix" ]]; then
      candidate=$(ls -1 "$prefix" 2>/dev/null | sort -V | tail -n1)
      if [[ -n "$candidate" && -x "$prefix/$candidate/bin/docker" ]]; then
        echo "$prefix/$candidate/bin/docker"
        return
      fi
    fi
  done
  for path in /opt/homebrew/bin/docker /usr/local/bin/docker; do
    if [[ -x "$path" ]]; then
      echo "$path"
      return
    fi
  done
  die "Không tìm thấy lệnh docker. Hãy cài Docker Desktop / OrbStack / colima + docker CLI."
}

DOCKER="$(find_docker)"

# Khi PULL=1 thì pull image bản mới nhất.
# Mặc định tắt: docker run sẽ tự pull khi máy chưa có image, nhưng nếu máy đã có image trùng tên :latest
# thì sẽ dùng lại, không tự biết bản mới trên remote — muốn nâng lên latest mới nhất thì dùng PULL=1.
pull_image() {
  local image="$1"
  [[ "${PULL:-0}" == "1" ]] || return 0
  info "Pull image $image"
  $DOCKER pull "$image" || die "Pull $image thất bại."
}

# Idempotent: xóa container cùng tên
rm_container_if_exists() {
  local name="$1"
  if $DOCKER ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
    info "Xóa container đã tồn tại $name"
    $DOCKER rm -f "$name" >/dev/null
  fi
}

# Chờ container vào trạng thái healthy (hoặc chờ running khi không có healthcheck)
wait_healthy() {
  local name="$1"
  local timeout="${2:-90}"    # giây
  local waited=0
  info "Đang chờ $name sẵn sàng (tối đa ${timeout}s)..."
  while (( waited < timeout )); do
    local status health
    status="$($DOCKER inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "missing")"
    health="$($DOCKER inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || echo "unknown")"

    if [[ "$status" != "running" ]]; then
      warn "${name} trạng thái ${status}, in log gần nhất:"
      $DOCKER logs --tail 30 "$name" 2>&1 || true
      die "${name} không chạy."
    fi

    case "$health" in
      healthy) ok "$name healthy"; return 0 ;;
      unhealthy)
        warn "${name} unhealthy, log:"
        $DOCKER logs --tail 30 "$name" 2>&1 || true
        die "${name} kiểm tra sức khỏe thất bại."
        ;;
      none)
        # Image không có healthcheck: container running thì coi như sẵn sàng
        ok "${name} running (không có healthcheck)"
        return 0
        ;;
    esac
    sleep 2
    waited=$((waited + 2))
  done
  warn "${name} chờ quá thời gian, log cuối:"
  $DOCKER logs --tail 30 "$name" 2>&1 || true
  die "${name} chưa sẵn sàng trong ${timeout}s."
}

# In bảng địa chỉ dịch vụ thống nhất
print_endpoints() {
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────┐"
  echo "  │ Địa chỉ dịch vụ                                        │"
  echo "  ├─────────────────────────────────────────────────────────┤"
  printf "  │ Panel UI       http://localhost:%-24s│\n" "${PANEL_PORT}/"
  printf "  │ Panel API      http://localhost:%-24s│\n" "${PANEL_PORT}/api/v1/"
  printf "  │ Knowledge API  http://localhost:%-24s│\n" "${KNOWLEDGE_PORT}/v3/"
  printf "  │ Knowledge Docs http://localhost:%-24s│\n" "${KNOWLEDGE_PORT}/docs"
  printf "  │ Memory Core     http://localhost:%-24s│\n" "${MEMORY_CORE_PORT}/"
  printf "  │ Proxy          http://localhost:%-24s│\n" "${PROXY_PORT}/"
  echo "  └─────────────────────────────────────────────────────────┘"
}
