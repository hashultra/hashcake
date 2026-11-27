# HashCake v0.1.23

本版本同时提供 Linux AMD64 与 Windows AMD64。

## 更新内容

- **管理后台端口排序优化**：矿工列表、代理端口与控制中心统一按端口实时活跃度排序——有算力端口按算力降序排列，无算力但有矿机的端口按在线及总矿机数降序排列，无矿机端口排在最后；矿工列表默认选中首位活跃端口，并在鼠标悬停端口栏时冻结顺序防止刷新误点。
- **全币种备用连接稳态化**：对长时间无提交的备用连接抑制非必要切换，减少空闲上游连接反复重建与超时告警。
- **Sia（SC）与 ZEC 稳定性提升**：SC 首次下发任务时原子同帧发送难度与通知，支持矿池 `"nonce not satisfied"` 拒绝自愈与 60 秒窗口聚合；ZEC 已达标提交遇到滞后回执时不再误刷新任务而引发重复提交。
- **重连刷盘日志降噪**：将断线队列重放期间的 `unknown job` 冷却折叠窗口延长至 30 秒，减少高频告警刷屏，同时完整保留拒绝计数与统计准确性。

## 文件

- hashcake-0.1.23-linux-amd64：HashCake 服务端 linux-amd64 可执行文件，已内嵌 Web 管理后台。
- hashcake-0.1.23-windows.exe：HashCake 服务端 Windows x64 程序，已内嵌 Web 管理后台。

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
