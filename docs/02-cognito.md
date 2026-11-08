# 02 – AWS Cognito (IdP)

Cognito là nơi **duy nhất** quản lý người dùng, group và các ứng dụng được phép đăng nhập. Envoy Gateway chỉ tin vào token do Cognito ký.

## 1. Những gì sẽ được tạo

| Loại | Tên | Dùng cho |
|---|---|---|
| User Pool | `eg-demo-users` | Kho user, đăng nhập bằng email, chỉ admin tạo user |
| Hosted UI domain | `https://gitlabonlinecom-eg-demo.auth.ap-southeast-1.amazoncognito.com` | Trang đăng nhập (OIDC) |
| Group | `devops-admin`, `developer`, `viewer` | Xuất hiện trong claim `cognito:groups` của token user |
| Resource server | `orders-api` với scope `read`, `write` | Scope `orders-api/read`, `orders-api/write` cho client máy |
| App client | `portal-web` | App 1: Authorization Code + client secret, callback `https://portal.gitlabonlinecom.click/oauth2/callback`, sign-out URL `https://portal.gitlabonlinecom.click/` |
| App client | `demo-cli` | **Chỉ để test**: lấy token user bằng `USER_PASSWORD_AUTH` |
| App client | `orders-m2m` | Client máy gọi App 2 bằng Client Credentials |
| User | `eg-demo-admin@example.com` | group `devops-admin` |
| User | `eg-demo-dev@example.com` | group `developer` |
| User | `eg-demo-viewer@example.com` | group `viewer` |
| User | `eg-demo-nogroup@example.com` | không thuộc group nào (để test bị từ chối) |

## 2. Chạy script

```bash
./scripts/02-cognito-setup.sh
```

Kết quả được ghi vào `config/cognito.env` (quyền 600, đã `.gitignore`): User Pool ID, issuer, các client ID và secret, email và mật khẩu của 4 user test, cùng 2 API key cho App 3.

Script lấy domain từ `DOMAIN=gitlabonlinecom.click` trong `config/demo.env` để khai báo callback cho `portal-web`. Nếu sau này đổi domain, phải sửa cả Callback URL và Sign-out URL của app client `portal-web`, không chỉ values của chart.

Kiểm tra sau khi chạy:

```bash
source config/demo.env && source config/cognito.env
```

```bash
curl -s "$COGNITO_ISSUER/.well-known/openid-configuration" | jq '{issuer, authorization_endpoint, token_endpoint, jwks_uri}'
```

Kết quả mong đợi: `authorization_endpoint` là `https://gitlabonlinecom-eg-demo.auth.ap-southeast-1.amazoncognito.com/oauth2/authorize`.

```bash
aws cognito-idp describe-user-pool-client --region "$AWS_REGION" --user-pool-id "$COGNITO_USER_POOL_ID" --client-id "$PORTAL_CLIENT_ID" --query 'UserPoolClient.{Callback:CallbackURLs,Logout:LogoutURLs,Flows:AllowedOAuthFlows}'
```

Kết quả mong đợi: `Callback` = `["https://portal.gitlabonlinecom.click/oauth2/callback"]`.

> Nếu `create-user-pool-domain` báo lỗi domain đã tồn tại, nghĩa là prefix `gitlabonlinecom-eg-demo` đã có người dùng trong region. Đổi `COGNITO_DOMAIN_PREFIX` trong `config/demo.env`, xoá User Pool vừa tạo dở bằng `scripts/99-cleanup.sh --cognito` (script đã ghi ID pool vào `config/cognito.env` ngay sau khi tạo), rồi chạy lại `02-cognito-setup.sh`.

Script dùng các lệnh AWS CLI dưới đây. Nếu muốn làm tay từng bước, chạy theo thứ tự:

| Bước | Lệnh chính | Ghi chú |
|---|---|---|
| 1 | `aws cognito-idp create-user-pool` | `--username-attributes email`, `AllowAdminCreateUserOnly=true` (tắt tự đăng ký), password policy 12 ký tự |
| 2 | `aws cognito-idp set-user-pool-mfa-config` | Demo đặt `OPTIONAL` (TOTP) để test lấy token bằng mật khẩu. **Production: `ON`** |
| 3 | `aws cognito-idp create-user-pool-domain --managed-login-version 1` | Hosted UI kiểu classic, dùng ngay không cần cấu hình branding |
| 4 | `aws cognito-idp create-group` | 3 group |
| 5 | `aws cognito-idp create-resource-server` | `orders-api` + scope `read`, `write` |
| 6 | `aws cognito-idp create-user-pool-client` | 3 app client như bảng trên |
| 7 | `admin-create-user` + `admin-set-user-password --permanent` + `admin-add-user-to-group` | 4 user test |

## 3. Thông số token

| App client | Access token | ID token | Refresh token |
|---|---|---|---|
| `portal-web`, `demo-cli` | 30 phút | 30 phút | 12 giờ |
| `orders-m2m` | 60 phút | – | – |

Token sống ngắn giúp thay đổi group (thêm/bớt quyền) có hiệu lực trong vòng tối đa 30 phút. Envoy tự dùng refresh token để làm mới session của portal.

## 4. Đặc điểm token Cognito cần nhớ khi cấu hình Envoy

| Claim | ID token | Access token (user) | Access token (Client Credentials) |
|---|---|---|---|
| `iss` | `https://cognito-idp.ap-southeast-1.amazonaws.com/<pool_id>` | giống | giống |
| `aud` | client id | ❌ **không có** | ❌ **không có** |
| `client_id` | ❌ | ✅ | ✅ |
| `token_use` | `id` | `access` | `access` |
| `sub` | id của user | id của user | **client id** |
| `cognito:groups` | ✅ nếu user thuộc group | ✅ nếu user thuộc group | ❌ |
| `scope` | ❌ | `aws.cognito.signin.user.admin` | `orders-api/read orders-api/write` |
| `email` | ✅ | ❌ | ❌ |

Áp dụng trong cấu hình:

- **App 1** verify **ID token** với `audiences: [<portal-web client id>]`.
- **App 2** **không** đặt `audiences` (access token không có `aud`), thay vào đó chặn `token_use=id` và phân quyền theo `cognito:groups` hoặc `scope`.
- Rate limit của App 2 dựa vào `sub`: mỗi user, và mỗi client máy, có bộ đếm riêng.

## 5. Lấy token để thử

Access token của user:

```bash
./scripts/get-token.sh user admin
```

ID token của user:

```bash
./scripts/get-token.sh user viewer id
```

Token của client máy:

```bash
./scripts/get-token.sh m2m
```

Xem claims bên trong token:

```bash
./scripts/get-token.sh decode "$(./scripts/get-token.sh user dev)"
```

## 6. Quản lý user sau này

Thêm user mới (user nhận email chứa mật khẩu tạm):

```bash
aws cognito-idp admin-create-user --region "$AWS_REGION" --user-pool-id "$COGNITO_USER_POOL_ID" --username new.user@company.com --user-attributes Name=email,Value=new.user@company.com Name=email_verified,Value=true
```

```bash
aws cognito-idp admin-add-user-to-group --region "$AWS_REGION" --user-pool-id "$COGNITO_USER_POOL_ID" --username new.user@company.com --group-name developer
```

Khoá user và thu hồi toàn bộ refresh token (nhân viên nghỉ việc):

```bash
aws cognito-idp admin-disable-user --region "$AWS_REGION" --user-pool-id "$COGNITO_USER_POOL_ID" --username new.user@company.com
```

```bash
aws cognito-idp admin-user-global-sign-out --region "$AWS_REGION" --user-pool-id "$COGNITO_USER_POOL_ID" --username new.user@company.com
```

> Token đã cấp vẫn hợp lệ đến khi hết hạn (tối đa 30 phút). Session portal sẽ hết khi Envoy làm mới token thất bại.

## 7. Chi phí cần biết

- Cognito tính phí theo số user hoạt động hàng tháng (MAU), có bậc miễn phí.
- Token **machine-to-machine** (Client Credentials) được tính phí theo số lần cấp token. Client máy nên **cache token đến gần hết hạn** thay vì xin token mới cho mỗi request.
