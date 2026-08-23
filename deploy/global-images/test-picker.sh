#!/bin/bash
# test_picker_fixed.sh

USER_KEY="sk-mem-mHEx9wa3pIWMHPLDmAzUsyPpuE0Im2ZJ"
TEAM_ID="team-alt25dpai1"

echo "=== 1. Kiểm tra user_key với memory-core (body đúng) ==="
curl -sS -X POST "http://10.10.10.126:8420/v3/meta/auth/verify" \
  -H "x-tdai-service-id: default" \
  -H "x-tdai-user-key: $USER_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"user_key\":\"$USER_KEY\"}" | jq .

echo -e "\n=== 2. Gửi request tới proxy với đủ headers ==="
SESSION_ID=$(uuidgen)
echo "Session ID: $SESSION_ID"

# Thêm -v để xem header gửi đi và response chi tiết
curl -v -X POST "http://10.10.10.126:8096/claude-code/default/v1/messages" \
  -H "Content-Type: application/json" \
  -H "x-claude-code-session-id: $SESSION_ID" \
  -H "x-tdai-user-key: $USER_KEY" \
  -H "x-tdai-service-id: default" \
  -d '{"model":"xkiro","messages":[{"role":"user","content":"hi"}],"max_tokens":5,"stream":false}' 2>&1 | tee /tmp/curl_output.txt

# Kiểm tra response có tool_calls không
echo -e "\n=== 3. Phân tích response ==="
RESPONSE=$(cat /tmp/curl_output.txt | grep -v "^[*>]" | tail -n +2)
echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"

if echo "$RESPONSE" | jq -e '.tool_calls' > /dev/null 2>&1; then
    echo -e "\n[OK] Picker đã được gửi!"
else
    echo -e "\n[FAIL] Không thấy tool_calls. Kiểm tra header x-tdai-user-key có được gửi không:"
    grep -i "x-tdai-user-key" /tmp/curl_output.txt
fi
