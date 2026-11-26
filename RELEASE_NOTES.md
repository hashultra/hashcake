# HashCake v0.1.21

本版本同时提供 Linux AMD64 与 Windows AMD64。

## 更新内容

### 拒绝率与算力留存

- ZEC（Equihash）：优化矿池切换、难度变更及换块边界的任务调度与队列恢复逻辑：
  - 完善错标任务的实时识别与路由，减少因矿机固件任务标号滞后导致的误拒绝；
  - 对相邻任务的下发加入间隔保护，避免部分固件在连续通知下丢失新任务并按旧难度提交；
  - 同源任务的难度上调改用平滑下发，保持矿机连续做功、减少额外尾部丢失；
  - 在换块并发切换和单板队列短暂卡滞场景下自动触发精准恢复，避免整机重连或长时间无效提交；
  - 自动跳过长期无有效提交的待机连接切换，降低空连接抖动带来的拒绝损耗。

## 文件

- hashcake-0.1.21-linux-amd64：HashCake 服务端 linux-amd64 可执行文件，已内嵌 Web 管理后台。
- hashcake-0.1.21-windows.exe：HashCake 服务端 Windows x64 程序，已内嵌 Web 管理后台。

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
