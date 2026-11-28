# HashCake v0.1.26

本版本同时提供 Linux AMD64 与 Windows AMD64。

## 更新内容

- **Web 后台一键安全更新（Linux + Windows）**：在「更新日志」页面新增一键更新按钮、二次确认弹窗、国内高速镜像开关及实时进度与日志回显；底层通过权限分离的本机更新代理（Linux `systemd` `.path`/`.service`，Windows `SYSTEM` 计划任务，零新增监听端口）完成下载、替换与重启。
- **内置发布签名校验与自动回滚保护**：新增 `verify-release` 验签能力，更新停服前自动核对 `SHA256SUMS`、内置 Ed25519 发布签名、配置兼容性与版本身份（矿机断连窗口与命令行 `install.sh update` 一致）；新版本启动后连续执行 15 秒稳定性检查，若崩溃或异常将自动回滚至原版本。
- **老部署平滑过渡**：尚未启用更新代理的旧服务器在页面中保留原命令行更新入口，再通过官方安装脚本更新一次即可自动开启后续全部网页直更。

## 文件

- hashcake-0.1.26-linux-amd64：HashCake 服务端 linux-amd64 可执行文件，已内嵌 Web 管理后台。
- hashcake-0.1.26-windows.exe：HashCake 服务端 Windows x64 程序，已内嵌 Web 管理后台。

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
