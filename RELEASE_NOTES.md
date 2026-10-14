# HashCake v0.1.14

## 更新内容

- CakeBox 首次启用不再固定使用同一个伪装站点：HashCake 会按服务器所在地区，从该地区实测过的候选站点里随机挑一个，并记录本次抽取结果，便于事后复核。
- 后台「CakeBox」页新增伪装站点选择：可选「自动（随机选择）」、从本地区实测候选中指定一个，或手填自定义域名。集群启用后会固定该站点，页面直接显示当前生效值并说明更换方式。
- 修复首次启用 CakeBox 时按钮不可用、提示只说要先配置隧道入口却无处可配的问题：安装脚本会自动准备 CakeBox 隧道组件，后台可一键开启，按钮状态与提示会明确指出还缺什么。
- 后台「CakeBox」页可一键签发令牌并随时再次复制；矿场安装脚本改为隐藏输入接收令牌，命令行不再需要明文粘贴。
- 优化 CakeBox 页面排版与端口列表展开方式，手机端同样适配。
- 改善大量矿机持续接入、多币种同时工作和集中断连时的稳定性。
- 修复系统更新检查可能引发服务重复重启的问题。
- 修复 Windows 配置保存误报失败及并发首次初始化的问题。
- 改进中转连接状态显示，并加强管理脚本的输入校验。

## 升级提示

请从最新版说明中重新获取管理脚本再执行更新，以应用本次脚本修复。更新保留原有配置与账号；服务更新会短暂断开连接，建议在维护窗口操作。

已经启用 CakeBox 的服务器不受伪装站点调整影响：集群一旦固定前端站点就会继续沿用，重新签发令牌不会改变它。

Linux AMD64 与 Windows 均提供同版本文件。Windows 使用带时间戳的代码签名，部分设备仍可能显示安全提示。

## 下载与安装

- Linux AMD64：`hashcake-0.1.14-linux-amd64`
- Windows AMD64：`hashcake-0.1.14-windows.exe`

国内服务器管理入口：

```bash
HASHCAKE_RELEASE_MIRROR_BASE=https://cdn.jsdmirror.com/gh/hashultra/hashcake@main bash <(curl -fsSL https://cdn.jsdmirror.com/gh/hashultra/hashcake@8c5c83b540ecfcacaa5341cb7668dbd3bd3b3ef0/install.sh)
```

## 文件

- `hashcake-0.1.14-linux-amd64`：Linux amd64 程序，内置 Web 管理后台。
- `hashcake-0.1.14-windows.exe`：Windows x64 程序，内置 Web 管理后台。
