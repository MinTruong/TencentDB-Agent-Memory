# TDAI Global Images — Deploy Local

Các script khởi động local của bộ image toàn cục — `memory-core` + `memory-hub` + `proxy`, chạy riêng được từng cái và cũng có thể một lệnh khởi động tất cả.

## Thành phần và cổng

| Thành phần | Tên container | Image (Docker Hub công khai) | Cổng host | Công dụng |
|---|---|---|---|---|
| **memory-core** | `tdai-memory-core` | [`agentmemory/memory-core`](https://hub.docker.com/r/agentmemory/memory-core) | `8420` | Kernel gateway, đọc ghi memory, auth, data plane skill/RAG |
| **memory-hub**  | `tdai-memory-hub`  | [`agentmemory/memory-hub`](https://hub.docker.com/r/agentmemory/memory-hub)   | `8125` / `8424` | Image gộp Panel quản lý + Knowledge service |
| **proxy**       | `tdai-proxy`       | [`agentmemory/memory-proxy`](https://hub.docker.com/r/agentmemory/memory-proxy) | `8096` | Proxy chuyển tiếp request LLM, cổng vào API của coding agent |

> Cả ba image đều được phát hành trong namespace [`agentmemory`](https://hub.docker.com/u/agentmemory) trên Docker Hub,
> multi-arch (`linux/amd64` + `linux/arm64`), pull công khai không cần đăng nhập. Muốn khóa phiên bản thì đổi tag trong `.env`
> từ `:latest` sang phiên bản cụ thể, ví dụ `:1.0.0-beta.1`.
>
> Đồng nghiệp nội bộ Tencent cũng có thể ghi đè sang private registry nội bộ `mirrors.tencent.com/memory-team-control/` — xem
> khối lựa chọn bị comment trong `.env.example`.

## Yêu cầu môi trường

- macOS / Linux
- Docker (một trong Docker Desktop / colima / OrbStack)
- `bash` 4+ (macOS có sẵn 3.2 cũng chạy được)

## Bắt đầu nhanh

```bash
# 1) Chuẩn bị .env
cp .env.example .env

# 2) Sửa .env, điền hai nhóm tham số LLM thành giá trị thật
#    - MEMORY_LLM_*   → memory-core + memory-hub dùng nội bộ
#    - PROXY_UPSTREAM_* → LLM upstream mà proxy chuyển tiếp tới
$EDITOR .env

# 3) Kiểm tra khô (không khởi động container)
#    Mặc định đồng thời kiểm tra đường truyền LLM — xác minh sớm API key/URL/tên model, tránh khởi động xong mới phát hiện sai
./verify.sh
# Không muốn gửi request ra ngoài (môi trường offline...): ./verify.sh --skip-llm

# 4) Một lệnh khởi động bộ ba
./start-all.sh
```

## Kiểm tra trước đường truyền LLM

`verify.sh` mặc định kiểm tra trước hai nhóm đường truyền LLM (tắt bằng `--skip-llm`):

- **Protocol OpenAI tương thích**: `GET {base}/models`, chỉ xác minh API key + URL, **không tốn bất kỳ token nào**
- **Protocol Anthropic**: `POST {base}/v1/messages` gửi message tối thiểu `max_tokens=1`, tốn ≤ 10 token
- **nhóm memory** và **nhóm proxy** kiểm tra độc lập; nếu hai nhóm cấu hình hoàn toàn giống nhau thì tự bỏ qua kiểm tra lặp
- **Khi container đã chạy**, chạy thêm một lần curl exec từ trong container, xác minh tính kết nối mạng "container → LLM" (một số môi trường proxy/DNS cô lập, host truy cập được nhưng container không)

Ví dụ thất bại:

```
[error] nhóm memory API key không hợp lệ (HTTP 401): https://api.deepseek.com/v1/models
{"error":{"message":"Authentication Fails, Your api key: ****abcd is invalid",...}}
```

—— API key sai, URL sai, tên model sai đều bị chặn lại trước khi khởi động, không đợi đến lúc wiki ingest / chat mới 401.

Sau khi khởi động xong:

- Panel UI: <http://localhost:8125/>
- Knowledge API: <http://localhost:8424/v3/>
- Knowledge Swagger: <http://localhost:8424/docs>
- Memory Gateway: <http://localhost:8420/>
- Proxy: <http://localhost:8096/>

## Hai nhóm tham số độc lập

**Đây là điểm cốt lõi của thiết kế script** — LLM của nhóm memory và nhóm proxy hoàn toàn độc lập, có thể trỏ tới nhà cung cấp / model khác nhau.

### nhóm memory (memory-core + memory-hub dùng)

Embed/summarize của kernel memory, wiki ingest / tổng hợp của knowledge đều dùng nhóm cấu hình này.

| Biến | Giải thích | Ví dụ |
|---|---|---|
| `MEMORY_LLM_BASE_URL` | base URL tương thích OpenAI | `https://api.deepseek.com/v1` |
| `MEMORY_LLM_API_KEY` | API Key của endpoint trên | `sk-xxxxxxxx` |
| `MEMORY_LLM_MODEL` | ID model | `deepseek-chat` |
| `MEMORY_LLM_PROTOCOL` | `openai` hoặc `anthropic`, mặc định `openai` | `openai` |

### nhóm proxy (proxy dùng)

Proxy nhận request người dùng rồi chuyển tiếp tới nhóm endpoint này.

| Biến | Giải thích | Ví dụ |
|---|---|---|
| `PROXY_UPSTREAM_URL` | base URL mục tiêu chuyển tiếp | `https://api.deepseek.com/v1` |
| `PROXY_UPSTREAM_API_KEY` | API Key dùng để chuyển tiếp | `sk-xxxxxxxx` |
| `PROXY_UPSTREAM_MODEL` | ID model hướng tới người dùng | `deepseek-chat` |

> Hai nhóm có thể điền giá trị giống nhau (cùng trỏ một LLM), cũng có thể hoàn toàn khác: ví dụ nhóm memory dùng model rẻ để embedding, nhóm proxy dùng model mạnh cho hội thoại chính.

Khi thiếu tham số, script sẽ **liệt kê tất cả mục thiếu trong một lần trước khi khởi động** và `exit 1`, không chạy được nửa chừng mới fail.

## Thông tin quản trị nội bộ (bắt buộc xem khi production)

Ba thành phần dùng `MEMORY_CORE_GATEWAY_API_KEY` để xác thực lẫn nhau, lần khởi động đầu còn qua
`init-admin` tạo một tài khoản `system_admin`. Để **trải nghiệm zero-config local**, giá trị mặc định của script là:

| Biến | Giá trị mặc định | Công dụng |
|---|---|---|
| `MEMORY_CORE_GATEWAY_API_KEY` | `local` | Bearer của memory-hub / proxy → memory-core |
| `MEMORY_CORE_ADMIN_USERNAME` | `admin` | Tên user của system_admin khởi tạo |
| `MEMORY_CORE_ADMIN_USER_KEY` | `admin` | Login key của admin user này |

> Ba giá trị mặc định này chỉ phù hợp để cá nhân chạy thông local. **Trước khi production / liên điều chỉnh / phơi ra mạng công khai phải thay bằng chuỗi dài ngẫu nhiên**,
> nếu không ai giữ được cổng cũng có thể lấy được quyền system_admin.
>
> Bỏ comment ba dòng tương ứng trong `.env` để ghi đè (`_lib.sh` sẽ `require_vars`
> kiểm tra các mục bắt buộc còn lại, nhưng ba biến này có mặc định bù, nên script lúc khởi động sẽ in `[warn]` nhắc bạn đổi).

## Dùng riêng từng thành phần

Ba script có thể chạy riêng, tiện cho việc gỡ lỗi hoặc khi chỉ cần một phần khả năng:

```bash
./start-memory-core.sh       # chỉ chạy kernel gateway (8420)
./start-memory-hub.sh   # chỉ chạy panel + knowledge (8125 + 8424); cần các tham số MEMORY_LLM_*
./start-proxy.sh        # chỉ chạy proxy (8096); cần các tham số PROXY_UPSTREAM_*
```

Quan hệ phụ thuộc:

- **memory-core**: không phụ thuộc ngoài, có thể khởi động độc lập
- **memory-hub**: khởi động độc lập được (LLM_MODE=custom nối thẳng LLM), nhưng knowledge bên trong gọi memory-core làm RAG sẽ fail → đề nghị khởi động memory-core trước
- **proxy**: khởi động độc lập được (khi cost-guard không dùng được sẽ tự giảm thành passthrough, chuyển tiếp thẳng), nhưng auth / tdai memory / skill inject cần memory-core mới có hiệu lực

Khi thiếu thành phần bất kỳ, script sẽ `warn` nhắc nhưng không chặn.

## Bền bỉ dữ liệu

- `tdai-memory-core-data` (named volume) → SQLite / dữ liệu memory của memory-core
- `tdai-panel-data` (named volume) → SQLite / git clone / file wiki của knowledge trong memory-hub

Trước khi `docker volume rm`, dữ liệu luôn được giữ. Đổi tên có thể sửa `MEMORY_CORE_VOLUME` / `PANEL_VOLUME` trong `.env`.

## Dừng / dọn dẹp

```bash
./stop-all.sh            # dừng container, giữ volume (khởi động sau dữ liệu vẫn còn)
./stop-all.sh --purge    # dừng container + xóa volume + xóa network (dọn sạch hoàn toàn)
```

## Xem log

```bash
docker logs -f tdai-memory-core
docker logs -f tdai-memory-hub
docker logs -f tdai-proxy
```

Bên trong memory-hub có hai tiến trình (panel + knowledge), log nằm tương ứng trong container `/data/knowledge/logs/panel.log` và `.../knowledge.log`.

## Xung đột cổng

Nếu `8125` / `8420` / `8424` / `8096` xung đột với service local đang chạy, cứ sửa trực tiếp trong `.env`:

```bash
MEMORY_CORE_PORT=18420
PANEL_PORT=18125
KNOWLEDGE_PORT=18424
PROXY_PORT=18096
# địa chỉ knowledge phơi ra ngoài phải đi theo KNOWLEDGE_PORT
KNOWLEDGE_PUBLIC_BASE_URL=http://host.docker.internal:18424/v3
```

## Dùng proxy làm API base của coding agent

Ví dụ với Claude Code:

```bash
export ANTHROPIC_BASE_URL=http://localhost:8096
export ANTHROPIC_API_KEY=any-string-if-auth-disabled
# client dùng protocol openai tương tự: OPENAI_BASE_URL=http://localhost:8096/v1
```

Thẻ "Địa chỉ kết nối client" trong Panel UI sẽ tự ghép LAN IP của host + `PROXY_PORT` (ví dụ
`http://192.168.1.100:8096/codebuddy/default`), máy người khác copy sang là kết nối được ngay.
Được đưa vào `metadata-instances.json.proxy_endpoint` bên trong memory-hub bởi `MEMORY_HUB_PROXY_PUBLIC_URL`
(khi chưa đặt, script dùng `hostname -I` / trên macOS `ipconfig getifaddr en0`
tự động dò, dò không ra mới fallback `localhost`).
Panel backend → Kernel chuyển tiếp không bị biến này ảnh hưởng (luôn đi theo `REMOTE_INSTANCE_URL` → memory-core:8420).
Địa chỉ tự dò không đúng (nhiều card mạng / domain công khai / đằng sau reverse proxy), hãy đặt tường minh trong `.env`
`MEMORY_HUB_PROXY_PUBLIC_URL=http://<giá trị thật>:8096`. Muốn card UI về hành vi cũ (fallback về
gateway_endpoint) thì đặt `MEMORY_HUB_PROXY_PUBLIC_URL` tường minh là chuỗi rỗng.

`proxy` mặc định tắt `auth` / `sessionInit` / `costGuard` (các thứ này phụ thuộc service nội bộ), chỉ làm chuyển tiếp thuần + context inject `tdai-memory` (tên injector, không phải tên container). Muốn bật full pipeline thì cần cấu hình riêng — xem `context_proxy/config.example.yaml`.

## Câu hỏi thường gặp

**Q: `./start-all.sh` kẹt ở wait_healthy?**
Image có thể vẫn đang pull. Dùng `docker pull <IMAGE>` pull trước một lần rồi chạy lại script.

**Q: memory-hub đã lên nhưng Panel mở không được?**

Kiểm tra trong `.env` `KNOWLEDGE_PUBLIC_BASE_URL` có chứa `/v3` không — thiếu `/v3` panel sẽ báo lỗi.

**Q: proxy chuyển tiếp trả về 401?**
`PROXY_UPSTREAM_API_KEY` không hợp lệ hoặc `PROXY_UPSTREAM_URL` không khớp. Dùng `docker logs tdai-proxy` xem lỗi.

**Q: Làm thế nào truy cập các service khác trên host từ ngoài container (Ollama, Langfuse...)?**
Script đã mặc định `--add-host=host.docker.internal:host-gateway`. Trong container dùng `http://host.docker.internal:<port>` là được.