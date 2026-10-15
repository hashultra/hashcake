# HashCake v0.1.15

本版本同时提供 Linux AMD64 与 Windows AMD64。

## 更新内容

- 改善多币种同时运行、上游响应变慢和连接回收时的稳定性。
- 修复管理后台配置更新、账号初始化和服务重启过程中的边界问题。
- 改进中转连接状态显示与异常处理，减少大量设备集中接入或断线重连时的影响。

## 升级提示

建议先在少量设备上验证，再安排批量升级。Linux 使用原管理菜单或安装脚本的更新功能，升级会保留已有配置和账号；Windows 下载同版本程序替换更新。部分 Windows 设备可能提示发布者未受系统默认信任，请先核对下载文件校验值。

国内服务器通用管理入口：

```bash
HASHCAKE_RELEASE_MIRROR_BASE=https://cdn.jsdmirror.com/gh/hashultra/hashcake@main bash <(curl -fsSL https://cdn.jsdmirror.com/gh/hashultra/hashcake@8c5c83b540ecfcacaa5341cb7668dbd3bd3b3ef0/install.sh)
```

## 文件

- `hashcake-0.1.15-linux-amd64`：Linux amd64 程序，内置 Web 管理后台。
- `hashcake-0.1.15-windows.exe`：Windows x64 程序，内置 Web 管理后台。
