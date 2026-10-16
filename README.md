# multi-account

一键为 WorkBuddy、Cursor 等应用创建多账号快捷方式：独立数据目录隔离登录，Mac/Windows 点选生成，默认 account1/account2，无需命令行。

## Mac

进入 `mac/` 目录，双击 **多账号快捷方式.app**。

若提示无法打开，先双击 **若打不开请先打开我.app**（或在「系统设置 → 隐私与安全性」允许），再重试。

按提示：搜索/选择应用 → 选择或新建账号 → 选择数据根目录 → 确认后生成桌面快捷方式。

## Windows

进入 `win/` 目录，双击 **多账号快捷方式.exe**（或 `CreateShortcuts.exe` / 双击创建快捷方式.vbs）。

按提示选择应用、账号与数据目录后，会在桌面生成独立快捷方式。

如需管理员权限，可使用 **以管理员身份创建.vbs**。

## 数据目录

多账号数据默认在以下位置之一（创建时自选）：

- `~/AppAccounts/`（Mac）或 `%USERPROFILE%\AppAccounts\`（Windows）
- 桌面 / 文档下的 `AppAccounts`

结构：`AppAccounts/应用名/账号名/`。删除某个账号文件夹即可清除该账号登录态。

## 说明

- 源码：`mac/mac_account.py`、`win/CreateShortcuts.ps1`
- Windows 可用 `win/build-exe.ps1` 重新打包 exe
