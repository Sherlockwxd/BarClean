# BarClean

![BarClean 标志](Resources/BarClean-logo.png)

macOS 27 菜单栏图标收纳工具。点击收纳图标或菜单栏空白处展开隐藏图标；在设置中拖动第三方图标，选择隐藏或常驻，并调整当前可见图标的顺序。

## 下载

[下载 v0.1.1（Apple 芯片）](https://github.com/Sherlockwxd/BarClean/releases/tag/v0.1.1)。解压后将 `BarClean.app` 放入 `/Applications` 再启动；更新前先退出旧版。

当前版本使用临时签名，未经 Apple 公证。若首次打开被 macOS 拦截，可在“系统设置 → 隐私与安全性”中选择“仍要打开”。

## 使用

1. 右键点击收纳图标打开设置，点击“授权布局文件…”，选择 `~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist`。
2. 拖动图标到“隐藏”或“常驻”，点击“保存隐藏设置”。要调整菜单栏实际顺序，先展开菜单栏并授予“辅助功能”权限，再拖动“当前”中的图标并点击“应用排序”。
3. 设置中还可切换收纳图标、启用登录时启动，以及开启鼠标离开菜单栏 5 秒后自动收起。

点击菜单栏空白处展开也需要辅助功能权限；仅点击收纳图标不需要。

## 限制

- 仅支持 macOS 27、Apple 芯片；隐藏依赖系统私有接口，系统升级后可能失效。
- 只处理第三方图标；同一应用的多个图标会一起隐藏。排序仅支持当前可见且可唯一识别的第三方常驻图标，不支持系统图标或隐藏区排序。
- 应用需保持运行，退出后会解除隐藏。旧版更换 Bundle ID 后，设置和系统授权需要重新配置。

## 自行构建

安装 Swift Command Line Tools 后运行 `zsh build.sh`，生成 `build/BarClean.app`。

## 许可证

[MIT](LICENSE) · [第三方许可声明](NOTICE.md)
