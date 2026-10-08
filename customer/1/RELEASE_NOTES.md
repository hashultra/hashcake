# HashCake v0.1.13

## 更新内容

- 改善大量矿机持续接入、多币种同时工作和集中断连时的稳定性。
- 修复系统更新检查可能引发服务重复重启的问题。
- 修复 Windows 配置保存误报失败及并发首次初始化的问题。
- 改进中转连接状态显示，并加强管理脚本的输入校验。

## 升级提示

请从最新版说明中重新获取管理脚本再执行更新，以应用本次脚本修复。更新保留原有配置与账号；服务更新会短暂断开连接，建议在维护窗口操作。

Linux AMD64 与 Windows 均提供同版本文件。Windows 使用带时间戳的代码签名，部分设备仍可能显示安全提示。

## 下载与安装

- Linux AMD64：`hashcake-0.1.13-linux-amd64`
- Windows AMD64：`hashcake-0.1.13-windows.exe`

国内服务器管理入口：

```bash
HASHCAKE_RELEASE_MIRROR_BASE=https://cdn.jsdmirror.com/gh/hashultra/hashcake@main bash <(curl -fsSL https://cdn.jsdmirror.com/gh/hashultra/hashcake@ecdc13839d0818109eb536055604ec6863d615ab/customer/1/install.sh)
```
