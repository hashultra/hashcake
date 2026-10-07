# HashCake v0.1.11

本版本同时提供 Linux AMD64 与 Windows AMD64。

## 新增

- 新增“纯中转”币种选项：端口选择后原样转发矿机与矿池之间的数据，适合暂未单独适配的币种；纯中转端口不支持抽水。
- 主矿池和备用矿池可以分别选择 TCP 或 SSL，备用矿池也可以测试连接。
- 顶部币种栏较多时可左右滚动浏览。

## 修复与改进

- 降低 BTC、BCH、BSV 在矿池调高难度时的拒绝率。
- 修复部分 LTC/DOGE 矿池连接正常、提交却无法得到确认的问题，改善币印等矿池的兼容性。
- 改善 ETC 在 K1Pool 等矿池的兼容性，矿机状态上报不会影响正常提交。
- 改善大量矿机同时接入或断线重连时的稳定性。
- 优化端口编辑界面排版，调整导入、导出配置图标。

## 升级说明

- 建议先在少量设备上验证，再安排批量升级。
- Linux 使用原管理菜单或安装脚本的更新功能，升级会保留已有配置和账号。
- Windows 下载同版本程序替换更新。系统可能提示发布者不受信任，请先核对下载文件校验值。

Linux 国内服务器通用管理入口：

```bash
bash <(curl -fsSL https://cdn.jsdmirror.com/gh/hashultra/hashcake@fdc53a09e6659a278e3cf9962d2229cc418ce46c/install.sh)
```

## 文件

- `hashcake-0.1.11-linux-amd64`：Linux amd64 程序，内置 Web 管理后台。
- `hashcake-0.1.11-windows.exe`：Windows x64 程序，内置 Web 管理后台。
