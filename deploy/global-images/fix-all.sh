#!/bin/bash
# fix-all.sh - Tự động sửa binding proxy

set -e

echo "=== 1. Kiểm tra config proxy ==="
docker exec tdai-proxy cat /data/config.yaml | grep -A12 "sessionInit:"

echo ""
echo "=== 2. Sửa config: bật headerAutoSelect ==="
docker exec tdai-proxy sed -i '/headerAutoSelect:/,/^[^ ]/ s/enabled: false/enabled: true/' /data/config.yaml

echo ""
echo "=== 3. Kiểm tra lại config ==="
docker exec tdai-proxy cat /data/config.yaml | grep -A12 "sessionInit:"

echo ""
echo "=== 4. Restart proxy ==="
docker stop tdai-proxy && docker rm tdai-proxy
cd ~/TencentDB-Agent-Memory/deploy/global-images
PROXY_ENABLE_AUTH=1 PROXY_ENABLE_SESSION_INIT=1 PROXY_ENABLE_TDAI=1 ./start-proxy.sh

echo ""
echo "=== 5. Chờ proxy sẵn sàng và kiểm tra binding ==="
sleep 5
docker logs tdai-proxy --tail 20 | grep -E "userId|session-init|headerAutoSelect"

echo ""
echo "=== HOÀN TẤT ==="
echo "Bây giờ hãy mở một terminal mới và chạy: claude"
echo "Chọn: 是，关联团队资产 -> numerology -> Senior-Dev -> No task"
echo "Sau đó chạy lệnh kiểm tra:"
echo "  docker logs tdai-proxy --tail 30 | grep -E 'userId|agent_id|team_id'"
echo "  docker exec tdai-memory-core ls -lat /data/tdai-memory/conversations/"

