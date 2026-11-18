# 自托管同步

WeekGlass 的同步 API 使用 PostgreSQL。选择 `self_hosted` 模式即可用自己的服务器同步，无需启用收款或申请官方云账号。

在仓库根目录构建 API 镜像：

```sh
docker build -t weekglass-api -f server/runtime/Dockerfile server
```

为 WeekGlass 创建专用 PostgreSQL 数据库和账号。将 API 容器放在可访问此数据库的私有网络，仅向 HTTPS 反向代理暴露容器端口 8000。API 容器使用 UID 10001；挂载的密钥文件须允许该 UID 读取，不要放入 Git 或镜像。

| 环境变量 | 值 |
| --- | --- |
| `WEEKGLASS_MODE` | `self_hosted` |
| `WEEKGLASS_SERVER_ID` | 此实例的持久 UUID |
| `WEEKGLASS_PUBLIC_ORIGIN` | 你的 HTTPS 地址（如 `https://sync.example.com`，不带路径） |
| `AUTH_SIGNING_KEY_FILE` | 容器中含至少 32 字节独立随机密钥的文件路径 |
| `DB_HOST`、`DB_PORT`、`DB_NAME`、`DB_USER` | 专用 PostgreSQL 实例的连接参数 |
| `DB_PASSWORD_FILE` | 容器中数据库密码文件的路径 |
| `FORWARDED_ALLOW_IPS` | 唯一受信的反向代理 IP 或网段 |

代理须保留正确的 `Host` 并设置 `X-Forwarded-Proto: https`。启动后用 `/healthz` 核对服务状态。打开客户端的「设置 → 云同步 → 自己的服务器」，输入 HTTPS 地址；首次登录时注册独立的 WeekGlass 账号并保存恢复码即可。

新版 API 与 WeekGlass 0.21.0 及以上可同步同一账号的作息设置，包括是否启用、睡觉时间和起床时间。API 启动时会自动应用新增字段；旧客户端继续同步日程，连接旧 API 时作息只保存在本机。

[OpenAPI 合同](contracts/sync-v1.openapi.json) | [服务端测试](runtime/tests) | [构建托管版](runtime/README.md#build-the-hosted-api)

如果你修改了按 AGPL 授权的服务端，并让用户通过网络使用，请按 [AGPL 第 13 条](../LICENSE)向这些用户显著、免费提供正在运行版本的对应源码，包括所需的构建、安装和运行脚本。上游仓库的链接不能代替你自己的改动。
