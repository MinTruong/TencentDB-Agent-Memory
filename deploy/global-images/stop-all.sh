#!/usr/bin/env bash
# Dừng và xóa bộ ba container.
#
# Cách dùng:
#   ./stop-all.sh              # dừng container, giữ volume (dữ liệu giữ lại)
#   ./stop-all.sh --purge      # dừng container + xóa volume + xóa network (dọn sạch hoàn toàn)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
source "$SCRIPT_DIR/_lib.sh"

PURGE=0
if [[ "${1:-}" == "--purge" ]]; then
  PURGE=1
fi

# Cho phép chạy cả khi .env không tồn tại (dùng tên volume mặc định để bù)
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE"; set +a
fi
MEMORY_CORE_VOLUME="${MEMORY_CORE_VOLUME:-tdai-memory-core-data}"
PANEL_VOLUME="${PANEL_VOLUME:-tdai-panel-data}"

for c in tdai-proxy tdai-memory-hub tdai-memory-core; do
  if $DOCKER ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
    info "Dừng và xóa $c"
    $DOCKER rm -f "$c" >/dev/null
  else
    info "$c không chạy, bỏ qua"
  fi
done

if (( PURGE == 1 )); then
  warn "--purge đã bật: xóa volume + network + file admin key"
  for v in "$MEMORY_CORE_VOLUME" "$PANEL_VOLUME"; do
    if $DOCKER volume inspect "$v" >/dev/null 2>&1; then
      $DOCKER volume rm "$v" >/dev/null && ok "Đã xóa volume $v" || warn "Xóa volume $v thất bại"
    fi
  done
  if $DOCKER network inspect tdai-memory-stack >/dev/null 2>&1; then
    $DOCKER network rm tdai-memory-stack >/dev/null && ok "Đã xóa network tdai-memory-stack" || true
  fi
  # admin key gắn chặt với volume; purge volume phải xóa key song song, nếu không lần khởi động sau
  # sẽ đọc key cũ nhưng volume mới → kiểm tra auth thất bại.
  ADMIN_KEY_FILE="${MEMORY_CORE_ADMIN_KEY_FILE:-$SCRIPT_DIR/.admin-key}"
  if [[ -f "$ADMIN_KEY_FILE" ]]; then
    rm -f "$ADMIN_KEY_FILE" && ok "Đã xóa file admin key $ADMIN_KEY_FILE"
  fi
  # Tiện thể dọn config do proxy / memory-core sinh ra
  PROXY_CFG_DIR="${PROXY_CONFIG_DIR:-$SCRIPT_DIR/.proxy-config}"
  if [[ -d "$PROXY_CFG_DIR" ]]; then
    rm -rf "$PROXY_CFG_DIR" && ok "Đã xóa thư mục proxy config $PROXY_CFG_DIR"
  fi
  CORE_CFG_DIR="${MEMORY_CORE_CONFIG_DIR:-$SCRIPT_DIR/.memory-core-config}"
  if [[ -d "$CORE_CFG_DIR" ]]; then
    rm -rf "$CORE_CFG_DIR" && ok "Đã xóa thư mục memory-core config $CORE_CFG_DIR"
  fi
fi

ok "Hoàn tất."
