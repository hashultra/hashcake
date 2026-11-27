# HashCake v0.1.24

本版本同时提供 Linux AMD64 与 Windows AMD64。

## 更新内容

- **管理后台新版本提示**：左上角版本号旁新增新版本提示（侧栏折叠、窄屏及移动端同步展示），检测到新稳定版本时点击即可直达「更新日志」页面查看更新内容与升级命令。
- **跨池抽水触发响应与比例收敛优化**：优化 BTC、LTC、ZEC 等跨池场景下的抽水入场节奏，大幅缩短矿机上线或重连后首次触发抽水的等待时间，消除部分矿机长时间未进入抽水的现象并提升实测比例收敛精度，同时保持 DASH 长驻留稳定性。
- **Sia（SC）重连首任务稳定性提升**：SC 矿机重连或上游会话切换后的首个任务强制下发 `clean_jobs` 并增加目标同步确认间隔，进一步降低 `nonce not satisfied` 拒绝。
- **错误日志降噪**：将闲置待命上游链路的正常断开归类至普通运行日志，显著减少错误日志刷屏，活跃链路与异常故障仍保留完整告警。

## 文件

- hashcake-0.1.24-linux-amd64：HashCake 服务端 linux-amd64 可执行文件，已内嵌 Web 管理后台。
- hashcake-0.1.24-windows.exe：HashCake 服务端 Windows x64 程序，已内嵌 Web 管理后台。

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
