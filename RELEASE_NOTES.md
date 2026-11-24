# HashCake v0.1.20

本版本同时提供 Linux AMD64 与 Windows AMD64。

## 更新内容

### 拒绝率

- ZEC（Equihash）：被矿机固件标成下一个任务的份额，改为按它实际解出的任务提交；已经能确定低于矿池目标的份额在本地直接答复，不再发给矿池。抽水份额不再因为任务时间较久而被本地丢弃。
- DASH：抽水切换改为在整批份额之后进行，切回主矿池后不再出现 `high-hash` 拒绝。
- BTC：S19k Pro 等机型切换矿池会话后，稍作等待再下发新任务，减少切换瞬间的拒绝。
- 换块时的尾部份额判定按矿池端口分别学习，同一父块的任务刷新不再受其影响。

### 抽水

- 矿池回执晚于超时到达时，被接受的份额仍会计入抽水和算力，比例不再因此偏低。

### 管理后台

- 端口详情新增「提交诊断」：按矿池回执分类显示拒绝原因、迟到回执和提交耗时；Prometheus 指标同步提供。

### 隧道

- 隧道写入按消息类型合并，减少小包数量。
- 配合 CakeBox 0.1.11：份额提交使用更紧凑的帧格式，减少流量。
- 配合 CakeBox 0.1.11：隧道断线后自动续传，短时间中断内矿机连接保持不断，未送达的份额在新隧道上补发且只提交一次。
- 紧凑帧与断线续传需要 HashCake 与 CakeBox 同时升级后才会启用；只升级其中一端时保持原有方式工作。

## 文件

- hashcake-0.1.20-linux-amd64：HashCake 服务端 linux-amd64 可执行文件，已内嵌 Web 管理后台。
- hashcake-0.1.20-windows.exe：HashCake 服务端 Windows x64 程序，已内嵌 Web 管理后台。

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
