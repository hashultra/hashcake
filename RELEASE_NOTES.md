# HashCake v0.1.22

本版本同时提供 Linux AMD64 与 Windows AMD64。

## 更新内容

- **日志存储与降噪**：默认将标准错误输出限制为 `WARN` 及以上级别，避免长期运行或高频重连场景下未轮转错误日志文件持续膨胀；异常冷却期内重复的 `unknown job` 提交日志自动折叠，保持核心指标与计数完整准确。
- **矿池握手与连接优化**：新增有界 `mining.configure` 协商负缓存并跳过 Sia（SC）币种扩展协商，消除部分矿池（如 SC、DASH 及部分 LTC 矿池）每次建连固定 3 秒超时的惩罚。
- **LTC / Scrypt 与 ZEC 稳定性**：引入零提交 `safety_deadline` 指数退避机制；对卡在已终结任务上的 Scrypt 矿机自动平滑下发最新任务而不断开连接；修复 ZEC 矿机已达标提交误触发同任务刷新引发重复提交的问题。
- **监控指标清理**：过滤端口热切换币种后产生的全零旧币种幽灵指标序列，完整保留非零历史统计数据。

## 文件

- hashcake-0.1.22-linux-amd64：HashCake 服务端 linux-amd64 可执行文件，已内嵌 Web 管理后台。
- hashcake-0.1.22-windows.exe：HashCake 服务端 Windows x64 程序，已内嵌 Web 管理后台。

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
