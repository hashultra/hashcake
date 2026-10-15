# HashCake 定制版 1 · 0.1.15

## 更新内容

- 改善多币种同时运行、上游响应变慢和连接回收时的稳定性。
- 修复管理后台配置更新、账号初始化和服务重启过程中的边界问题。
- 改进中转连接状态显示与异常处理，减少大量设备集中接入或断线重连时的影响。

## 升级提示

请从最新版说明中重新获取管理脚本再执行更新，以应用本次脚本修复。更新保留原有配置与账号；服务更新会短暂断开连接，建议在维护窗口操作。

Linux AMD64 与 Windows 均提供同版本定制文件。Windows 部分设备可能显示安全提示，请先核对下载文件校验值。

## 下载与安装

- Linux AMD64：`hashcake-0.1.15-linux-amd64`
- Windows AMD64：`hashcake-0.1.15-windows.exe`

定制版管理入口：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hashultra/hashcake/main/customer/1/install.sh)
```
