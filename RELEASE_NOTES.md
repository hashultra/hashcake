# HashCake v0.1.8

本版本更新 HashCake 服务端 Linux AMD64。推荐使用 SRBMiner 或 WildRig 的 PRL 用户更新。

## 更新内容

- 新增 PearlHash 原生 PRL 中转与抽水，已验证 WildRig 0.51.3 的真实挖矿及抽水后恢复。
- 修复 Kryptex PRL 矿工名被合并成默认 worker 的问题，保留每台设备的名称。
- 修复 SRBMiner 大证明导致断线，以及 SSL 连接提交后长时间没有回执的问题。
- 改善 PRL 跨池抽水、不同难度下的比例计算、长时间不刷新的任务处理和断线恢复。已在 SRBMiner 3.7.1、3.6.9 的 Kryptex 与 K1Pool 组合上完成真实矿机验证。实测范围有限，建议先单机验证，再逐步更新。
- 改善 XBT 异常断连、未响应份额统计和任务难度变化时的计账；关闭抽水后立即停止新的抽水分流。
- XBT 上游地址保留 TCP/SSL 连接方式；补齐 XBT 和 PRL 币种图标。

## 使用范围

- PRL 主池、备用池和抽水池须使用同一种协议，标准 JSON PRL 与 PearlHash 原生任务不能混用；切换协议时需同步调整矿机。
- SSL 必须使用矿池对应的加密端口和有效证书。Kryptex PRL 香港节点使用 8048；PearlHash 9443 当前的自签名证书不在默认信任范围内。
- XBT 经 DATUM 网关接入，抽水地址与主地址共用同一网关连接，不支持把份额转投到另一个矿池。

## 文件

- hashcake-0.1.8-linux-amd64：HashCake 服务端 linux-amd64 可执行文件，已内嵌 Web 管理后台。

Release 资产只包含二进制文件。安装脚本位于仓库根目录 `install.sh`。

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hashultra/hashcake/main/install.sh)
```

首次安装会随机生成 Web 后台端口和安全访问路径，并默认开启自签 HTTPS。

首次登录令牌有效 10 分钟，只用于创建首个管理员账号；账号创建成功后立即失效，之后使用账号与密码登录。

国内服务器可使用下面的通用管理入口。该命令不绑定当前已安装版本；选择安装或更新时，安装器会自动查找官方最新稳定版，并根据 SHA256SUMS 校验下载文件：

```bash
bash <(curl -fsSL https://cdn.jsdmirror.com/gh/hashultra/hashcake@15d98bd5824c48702ac6d08be098d4f7d413a218/install.sh)
```

## 安装器可靠性

- 官方二进制下载会强制核对 `SHA256SUMS`，并在执行前检查实际版本与运行兼容性。
- 首次安装或更新失败会恢复旧二进制、服务文件、配置元数据和防火墙状态，避免留下半安装状态。
- 默认配置位于 `/opt/hashcake/config/hashcake.yaml`；旧路径会在更新时安全迁移。

## 配套项目

- CakeBox：https://github.com/hashultra/cakebox
