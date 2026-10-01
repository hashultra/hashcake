# HashCake v0.1.7

本版本提供 HashCake 服务端 linux-amd64 发布包。

## 更新内容

- 新增 PRL（Pearl，pearlhash PoUW）币种接入：可在端口上选择 PRL，矿机以明文 Stratum 接入，由 HashCake 统一中转、统计与抽水，矿机、算力、份额与拒绝率都会出现在与管理面其它币种相同的位置。该币种的协议与其它币种差异较大（授权即建连、参数为对象、不单独下发难度），HashCake 已按它的方言适配，矿机侧无需特殊设置。接入前请注意两点：一是主矿池与费用矿池**可以指向不同的矿池**，费用线路会切换成费用矿池自己下发的任务，因此费用钱包必须是费用矿池认可的地址；二是该端口使用明文 TCP，矿机地址按 `stratum+tcp://` 填写。
- 提升 XBT（Bitcoin BLAKE2b，经 DATUM 网关接入）的健壮性：加强网关任务标识校验，对上游连接增加超时保护，并补上中继侧的算力与份额统计，网关异常时不再出现长时间挂起。
- 安装器交互改进：菜单支持颜色输出（非交互终端与设置 `NO_COLOR` 时自动关闭）；权限提示更明确，引导先用 `sudo -i` 进入 root shell 再重跑原命令，而不是让 sudo 在管道中失败；启动服务前会检查系统是否具备 systemd；服务已在运行时不再重复启动，直接显示当前状态。

## 文件

- hashcake-0.1.7-linux-amd64：HashCake 服务端 linux-amd64 可执行文件，已内嵌 Web 管理后台。

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
