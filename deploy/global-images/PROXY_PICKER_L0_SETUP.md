# 📄 Tài liệu: Cấu hình TencentDB Agent Memory – Proxy Picker & L0 Memory

## 1. Mục tiêu
- **Hiển thị picker** (chọn team/agent/task) khi dùng Claude Code qua proxy.
- **Ghi L0 memory** thành công sau khi chọn.

## 2. Cấu hình cuối cùng

### 2.1 File `.env` (tại `deploy/global-images/.env`)
Thêm các dòng sau vào cuối file `.env`:

```bash
# Proxy feature flags
PROXY_ENABLE_AUTH=1
PROXY_ENABLE_TDAI=1
PROXY_ENABLE_SESSION_INIT=1
```

**Giải thích:**
- `PROXY_ENABLE_AUTH=1`: Bật xác thực (cần thiết để picker hoạt động).
- `PROXY_ENABLE_TDAI=1`: Bật injection và ghi nhớ L0/L1/L2/L3.
- `PROXY_ENABLE_SESSION_INIT=1`: Bật khởi tạo phiên, hiển thị picker.

### 2.2 File `start-proxy.sh` – phần sinh config (heredoc)
```yaml
sessionInit:
  enabled: $(bool $PROXY_ENABLE_SESSION_INIT)   # => true
  maxRetries: 3
  injectAgentContext: true
  injectTaskContext: true
  debugForceIdentity:
    teamId: "n0y6th4d"
    agentId: "uj03icd8"
    taskId: "default-task"
  debugForceUserId: "minhth"
  headerAutoSelect:
    enabled: true
    teamHeader: "x-team-id"
    agentHeader: "x-agent-id"
    taskHeader: "x-task-id"
    onMismatch: "form"
```

Và phần `auth`:
```yaml
auth:
  enabled: true   # BẮT BUỘC để picker hoạt động
```

## 3. Điều kiện để picker xuất hiện
- `sessionInit.enabled = true`
- `auth.enabled = true`
- `headerAutoSelect.enabled = true`
- `onMismatch = "form"`
- **Không** gửi header `x-team-id`, `x-agent-id` từ client (nếu có header, proxy sẽ tự chọn và không hiện picker).

## 4. Điều kiện để L0 được ghi
- `tdai.memory.writeL0 = true`
- `injection.injectors` có `tdai-memory`
- Session init **không bị bypass**: cần có `userId` hợp lệ (từ auth hoặc debugForceUserId).
- Sau khi chọn picker, proxy có `userId=usr-...` và `sessionKey` → injector `tdai-memory` chạy và ghi L0.

## 5. Cách khởi động
```bash
cd ~/TencentDB-Agent-Memory/deploy/global-images
./start-proxy.sh
```
Script tự động load `.env` và sinh config mới mỗi lần chạy.

Nếu chưa có biến trong `.env`, có thể chạy trực tiếp:
```bash
PROXY_ENABLE_AUTH=1 PROXY_ENABLE_TDAI=1 PROXY_ENABLE_SESSION_INIT=1 ./start-proxy.sh
```

## 6. Kiểm tra
- **Picker**: chạy Claude, gửi tin nhắn → hiện form chọn team/agent.
- **L0 memory**: kiểm tra log:
  ```bash
  docker logs tdai-proxy | grep writeL0
  ```
  hoặc hỏi Claude *"những gì tôi đã nói?"* để xác nhận recall.

## 7. Lưu ý quan trọng
- Không sửa tay file `config.yaml` vì bị ghi đè mỗi lần start.
- Nếu muốn tắt picker, set `PROXY_ENABLE_SESSION_INIT=0` trong `.env`.
- Nếu không cần auth nhưng vẫn muốn picker → cần sửa source proxy (không khuyến nghị).

## 8. Các lỗi thường gặp và cách khắc phục

| Lỗi | Nguyên nhân | Cách fix |
|-----|-------------|----------|
| Picker không hiện | `auth.enabled=false` hoặc `headerAutoSelect.enabled=false` | Bật `PROXY_ENABLE_AUTH=1` và `headerAutoSelect.enabled=true` |
| L0 không ghi | Session bị bypass (thiếu userId) | Chọn đầy đủ team/agent/task trên picker hoặc dùng `debugForceUserId` |
| `userId=?` trong log | Auth chưa được bật hoặc chưa chọn user trên picker | Bật auth và chọn user khi picker hiện |

---

**Tài liệu được tạo ngày:** 2026-08-23
