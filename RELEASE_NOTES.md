# HashCake v0.1.6

本版本提供 HashCake 服务端 linux-amd64 发布包。

## 更新内容

- 新增 XBT（Bitcoin BLAKE2b）币种接入：可在端口上选择 XBT，矿机经 DATUM 网关接入并由 HashCake 统一中转与统计，矿机、算力、份额与拒绝率都会出现在与管理面其它币种相同的位置。XBT 的地址与比例按端口配置，抽水比例沿用与其它币种一致的长期精准逻辑，并且修改比例对已经连上的矿机立即生效。接入 XBT 前请先确认端口的主矿池与费用矿池填写的是同一个 DATUM 网关地址：DATUM 按每次提交的账户名记账，费用与主份额共用同一条网关连接，填成两个不同地址会被配置校验直接拒绝。
- 修正 XBT 矿机的后台显示：矿机行此前不会显示矿池下发的难度，也不显示收到的任务数，现在与实际连接一致。
- 提升 XBT 长连接的稳定性：矿机断开或端口停止时，中继此前可能残留与矿池之间的半条连接，长时间运行会累积并让矿池侧一直看到未关闭的连接；现在两端会同时干净结束。

## 文件

- hashcake-0.1.6-linux-amd64：HashCake 服务端 linux-amd64 可执行文件，已内嵌 Web 管理后台。

Release 资产只包含二进制文件。安装脚本位于仓库根目录 `install.sh`。

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hashultra/hashcake/main/install.sh)
```

首次安装会随机生成 Web 后台端口和安全访问路径，并默认开启自签 HTTPS。

首次登录令牌有效 10 分钟，只用于创建首个管理员账号；账号创建成功后立即失效，之后使用账号与密码登录。

国内服务器可使用下面的通用管理入口。该命令不绑定当前已安装版本；选择安装或更新时，安装器会自动查找官方最新稳定版，并根据 SHA256SUMS 校验下载文件：

```bash
bash <(curl -fsSL https://cdn.jsdmirror.com/gh/hashultra/hashcake@0e29f1f86c02872b872b55de65fa2c8a9c0e629f/install.sh)
```

## 安装器可靠性

- 官方二进制下载会强制核对 `SHA256SUMS`，并在执行前检查实际版本与运行兼容性。
- 首次安装或更新失败会恢复旧二进制、服务文件、配置元数据和防火墙状态，避免留下半安装状态。
- 默认配置位于 `/opt/hashcake/config/hashcake.yaml`；旧路径会在更新时安全迁移。

## 配套项目

- CakeBox：https://github.com/hashultra/cakebox
