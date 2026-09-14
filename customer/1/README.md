# HashCake 定制版 1

## Linux 安装与管理

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hashultra/hashcake/main/customer/1/install.sh)
```

## 国内中转（安装、更新与管理，带校验）

下面的命令会打开 HashCake 一键安装管理菜单，不绑定当前已安装版本。选择首次安装或更新时，安装器会自动查找 Edition 1 的最新稳定版，并根据该 Edition 的 SHA256SUMS 校验下载文件；日常管理操作不会重新安装程序：

```bash
bash <(curl -fsSL https://cdn.jsdmirror.com/gh/hashultra/hashcake@579ee1f8d58ac05268aecc1be6be3f63a7326cee/customer/1/install.sh)
```

## 离线重启

已手动替换程序的离线服务器，把新版 `install.sh` 传入后，运行 `bash install.sh` 并选择“5. 重启”。脚本会自动补齐必要启动设置并检查本地程序，不会联网下载、重新安装或重置账号。

## Windows 下载

```text
https://github.com/hashultra/hashcake/releases/latest/download/hashcake-1-windows-amd64.exe
```
