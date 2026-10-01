# HashCake 定制版 1

## Linux 安装与管理

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hashultra/hashcake/main/customer/1/install.sh)
```

主菜单始终展示完整功能，按安装与运行、日志与开机启动、后台与配置、维护工具分组。更新保留配置与账号，不会切换到其它 Edition。

后台改密和忘记密码直接选择“15. 修改后台账号密码 / 忘记密码”；“16. CakeBox 隧道令牌”提供签发、列表和撤销；“17. 安装 / 切换指定版本”仍使用本 Edition 的下载和校验流程。防火墙、系统连接限制和卸载入口均保留。操作结束返回菜单，回车或 0 返回上一级，主菜单中退出。

## 国内中转（安装、更新与管理，带校验）

下面的命令会打开 HashCake 一键安装管理菜单，不绑定当前已安装版本。选择首次安装或更新时，安装器会自动查找 Edition 1 的最新稳定版，并根据该 Edition 的 SHA256SUMS 校验下载文件；日常管理操作不会重新安装程序：
国内镜像的清单缓存可能滞后：安装器会在解析版本时与 GitHub 清单比对，镜像落后时按更新的版本安装，下载仍优先使用国内镜像。

```bash
bash <(curl -fsSL https://cdn.jsdmirror.com/gh/hashultra/hashcake@15d98bd5824c48702ac6d08be098d4f7d413a218/customer/1/install.sh)
```

## Windows 下载

```text
https://github.com/hashultra/hashcake/releases/latest/download/hashcake-1-windows-amd64.exe
```
