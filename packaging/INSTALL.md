# 安装 Codex 额度时钟

这个预编译包包含 macOS 14 及以上版本的 Apple Silicon 和 Intel 主程序与小组件。安装脚本会使用你自己的 Apple Development 证书签名，并为两个组件生成匹配的 App Group。此版本采用本地开发签名方式分发，尚未经过 Apple 公证。

1. 在 Mac 上安装并登录 Codex。确认终端可以使用 Python 3，钥匙串中有带私钥和 Team ID 的 Apple Development 证书。可以运行 `security find-identity -v -p codesigning` 查看可用证书。
2. 解压下载包，在终端进入包含 `install.command` 的目录，运行以下命令。

```sh
./install.command
open "$HOME/Applications/Codex 额度时钟.app"
```

如需安装到其他位置，可将目标 .app 的完整路径作为参数传给 `install.command`。如有多张证书，可通过环境变量 `QUOTA_SIGN_IDENTITY` 指定目标证书的 SHA-1。

首次打开后点击「刷新」。右键点击 macOS 桌面，选择「编辑小组件」，搜索「Codex 周额度」。额度保护默认关闭，开关和采样间隔都在「保护与刷新」里。

源代码及从源码构建的说明见[项目仓库](https://github.com/ljtdsjtw/codex-quota-clock)。
