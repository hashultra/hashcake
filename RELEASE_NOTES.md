# HashCake v0.1.25

本版本同时提供 Linux AMD64 与 Windows AMD64。

## 更新内容

- **LTC / ZEC 跨池抽水拒绝率优化**：将 Scrypt（LTC）与 SHA256d（BTC）的跨池抽水入场批次分离（LTC 设为 2 份、BTC 保持 1 份、DASH 保持 3 份），并将 Equihash（ZEC）调整为 2 份入场、3 份回切，在保持快速首次触发与精准比例收敛的同时，显著降低切换尾部 `stale-work` 与 LTC 超时回退。
- **Sia（SC）重连难度下发兼容性修复**：针对部分 SC 矿机固件忽略与 `mining.notify` 同帧捆绑的难度更新、且忽略重复 `job_id` 的问题，改为先单独下发 `mining.set_difficulty` 并等待 100ms，再发送 `mining.notify(clean=true)`，进一步减少重连首任务 `nonce not satisfied` 拒绝。
- **错误日志进一步降噪**：将运行超过 120 秒且首次正常空闲断开（EOF）的备用抽水上游重连日志从告警降级为普通运行日志，大幅减少 `hashcake.err.log` 噪音，主矿池断线、短命断链与异常错误仍完整保留告警。

## 文件

- hashcake-0.1.25-linux-amd64：HashCake 服务端 linux-amd64 可执行文件，已内嵌 Web 管理后台。
- hashcake-0.1.25-windows.exe：HashCake 服务端 Windows x64 程序，已内嵌 Web 管理后台。

Release 资产只包含二进制文件。安装脚本位于仓库根目录 `install.sh`。

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hashultra/hashcake/main/install.sh)
```

首次安装会随机生成 Web 后台端口和安全访问路径，并默认开启自签 HTTPS。

首次登录令牌有效 10 分钟，只用于创建首个管理员账号；账号创建成功后立即失效，之后使用账号与密码登录。

国内服务器可使用下面的通用管理入口。该命令不绑定当前已安装版本；选择安装或更新时，安装器会自动查找官方最新稳定版，并根据 SHA256SUMS 校验下载文件：

```bash
HASHCAKE_RELEASE_MIRROR_BASE=https://cdn.jsdmirror.com/gh/hashultra/hashcake@main bash <(curl -fsSL https://cdn.jsdmirror.com/gh/hashultra/hashcake@b249a26199a0eb9a54d5729df4ebfe321d198afd/install.sh)
```

## 安装器可靠性

- 官方二进制下载会强制核对 `SHA256SUMS`，并在执行前检查实际版本与运行兼容性。
- 首次安装或更新失败会恢复旧二进制、服务文件、配置元数据和防火墙状态，避免留下半安装状态。
- 默认配置位于 `/opt/hashcake/config/hashcake.yaml`；旧路径会在更新时安全迁移。

## 配套项目

- CakeBox：https://github.com/hashultra/cakebox
