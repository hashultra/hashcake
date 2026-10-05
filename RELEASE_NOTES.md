# HashCake v0.1.9

本版本改善 Linux 服务器兼容性和安装管理体验。

## 本次更新

- 新增 GLIBC 2.31 运行兼容性，解决 Ubuntu 20.04 等系统提示 GLIBC 版本缺失的问题。
- systemd 245 不再被安装器整体拒绝；可选隔离功能按系统能力启用，并明确提示差异。
- 修改后台密码和 Web 设置不再被无关的下载、创建用户工具或下载参数阻断。
- 关闭 IPv6 后仍可查看旧配置，并通过 IPv4 设置恢复访问。
- 启动失败保留原始错误，缺少依赖时提供软件包安装提示。
- 下载支持国内镜像、GitHub raw 和 API 备用源；不支持的架构会直接说明，不再误导用户准备源码编译环境。
- 完整保留服务、日志、后台、隧道令牌、防火墙及连接限制管理功能。

## 文件

- `hashcake-0.1.9-linux-amd64`：Linux amd64 加密压缩单文件，内嵌 Web 管理后台。
- 本次更新 Linux 版本；Windows 文件请查看 Releases 页面中包含 Windows 资产的版本。

## 安装与更新

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hashultra/hashcake/main/install.sh)
```

国内服务器可使用固定安装器入口。安装或更新时仍自动选择最新稳定版，并核对 `SHA256SUMS`：

```bash
bash <(curl -fsSL https://cdn.jsdmirror.com/gh/hashultra/hashcake@fdc53a09e6659a278e3cf9962d2229cc418ce46c/install.sh)
```

一键管理要求 Linux amd64、GLIBC 2.31 或更高版本、bash 4 或更高版本、systemd 240 或更高版本、Python 3 和 root 权限。

更新保留原有配置、后台端口、安全访问路径、账号和令牌；下载校验与失败回滚机制保持启用。首次登录令牌有效 10 分钟，仅用于创建首个管理员账号。
