# multi-account

一键为 WorkBuddy、Cursor 等应用创建多账号快捷方式：独立数据目录隔离登录，Mac/Windows 点选生成，默认 account1/account2，无需命令行。

## 下载（v1.0.1）

**Gitee**

- [发行版页面](https://gitee.com/hogan_dev/multi-account/releases/tag/v1.0.1)
- [Mac：mac-multi-account.zip](https://gitee.com/hogan_dev/multi-account/releases/download/v1.0.1/mac-multi-account.zip)
- [Windows：win-multi-account.zip](https://gitee.com/hogan_dev/multi-account/releases/download/v1.0.1/win-multi-account.zip)

**GitHub（镜像）**

- [发行版页面](https://github.com/systemhejiyong/multi-account/releases/tag/v1.0.1)
- [Mac：mac-multi-account.zip](https://github.com/systemhejiyong/multi-account/releases/download/v1.0.1/mac-multi-account.zip)
- [Windows：win-multi-account.zip](https://github.com/systemhejiyong/multi-account/releases/download/v1.0.1/win-multi-account.zip)

### v1.0.1 修复

- **Windows WorkBuddy 双击快捷方式无反应**：WorkBuddy 实际把数据写在 `%USERPROFILE%\.workbuddy\app`，忽略 `--user-data-dir`；旧版 `launch.vbs` 用 VBS Process 环境变量 + `shell.Run`，子进程吃不到隔离目录。现改为 `cmd /c set USERPROFILE=… && start …`，并预创建 `runtime-home\.workbuddy\app`，快捷方式指向 `wscript.exe`。重新运行本工具生成快捷方式即可；已有 WorkBuddy 请先完全退出再只用新快捷方式打开。

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

## 远程仓库

双远程，内容对齐（以 `main` 为准）：

- Gitee：https://gitee.com/hogan_dev/multi-account （源仓 / Release `v1.0.0`）
- GitHub：https://github.com/systemhejiyong/multi-account （镜像）

```bash
git remote add origin https://gitee.com/hogan_dev/multi-account.git   # 若尚无
git remote add github https://github.com/systemhejiyong/multi-account.git
git push origin main
git push github main
```

## 说明

- 源码：`mac/mac_account.py`、`win/CreateShortcuts.ps1`
- Windows 可用 `win/build-exe.ps1` 重新打包 exe
