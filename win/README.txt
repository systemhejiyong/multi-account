Windows 多账号快捷方式

【推荐】双击：
  多账号快捷方式.exe
  或 CreateShortcuts.exe

用法：
  1. 窗口会扫描本机已安装应用（开始菜单 / Programs）
  2. 可搜索，从列表里选择（Qoder、QoderWork、Grok Bot 等会出现）
  3. 选账号方案（默认 account1 + account2）
  4. 选数据目录 → 确认 → 桌面生成 .lnk

带 [推荐] 的应用有特殊隔离（WorkBuddy / Cursor / VS Code / Chrome 等）。
其它 Electron 类用 --user-data-dir；未知程序会提示后仍尝试隔离。

备用（同样无黑框）：
  双击创建快捷方式.vbs

需要管理员时：
  以管理员身份创建.vbs
