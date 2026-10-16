Option Explicit
Dim sh, fso, here, exe1, exe2, ps1, cmd
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
exe1 = here & "\多账号快捷方式.exe"
exe2 = here & "\CreateShortcuts.exe"
ps1 = here & "\CreateShortcuts.ps1"
If fso.FileExists(exe1) Then
  sh.Run """" & exe1 & """", 1, False
ElseIf fso.FileExists(exe2) Then
  sh.Run """" & exe2 & """", 1, False
ElseIf fso.FileExists(ps1) Then
  cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """"
  sh.Run cmd, 0, False
Else
  MsgBox "Cannot find 多账号快捷方式.exe or CreateShortcuts.ps1", 16, "Multi-account"
End If
