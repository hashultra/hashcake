# HashCake v0.1.16

本版本同时提供 Linux AMD64 与 Windows AMD64。

## 更新内容

- 修复签发表单使用 Cover IP 首项拼接 :443、覆盖显式后端标识的问题；新增显式地址保存接口，按保存配置、历史记录、自动建议的顺序提供地址，建议不再冒充已配置。
- HashCake 安装器按共享 sidecar-requirement 自动准备并校验官方 sidecar，纳入既有安装事务与服务权限；Web 确认实际公网地址后一键配置并启动 ingress/probe/sidecar，保存启用意图供重启恢复。
- 签发改为自动建议站点 ID（site-<地理位置>-<序号>，沿用已有站点前缀、留空退回 site-<序号>）、一次点击完成并显示结果；CakeBox 安装器 setup 同轮隐藏读取令牌、通过 stdin/权限受限文件导入并启动，升级保留旧状态。
- 区分组件运行、在线连接、已签发与撤销站点，失败回滚并允许重试；外部 sidecar 保留未知状态。旧缺失 Cover 意图仅从完整一致的历史令牌安全恢复，不猜测或轮换已有身份。
- 签发表单的「地理位置」「站点 ID」并排（均为短值，此前各占满面板宽）。

## 升级提示

建议先在少量设备上验证，再安排批量升级。Linux 使用原管理菜单或安装脚本的更新功能，升级会保留已有配置和账号；Windows 下载同版本程序替换更新。部分 Windows 设备可能提示发布者未受系统默认信任，请先核对下载文件校验值。

国内服务器通用管理入口：

```bash
HASHCAKE_RELEASE_MIRROR_BASE=https://cdn.jsdmirror.com/gh/hashultra/hashcake@main bash <(curl -fsSL https://cdn.jsdmirror.com/gh/hashultra/hashcake@8c5c83b540ecfcacaa5341cb7668dbd3bd3b3ef0/install.sh)
```

## 文件

- `hashcake-0.1.16-linux-amd64`：Linux amd64 程序，内置 Web 管理后台。
- `hashcake-0.1.16-windows.exe`：Windows x64 程序，内置 Web 管理后台。
