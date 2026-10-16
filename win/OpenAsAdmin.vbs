Option Explicit
Dim sh, fso, here, exe1, exe2, ps1
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
exe1 = here & "\多账号快捷方式.exe"
exe2 = here & "\CreateShortcuts.exe"
ps1 = here & "\CreateShortcuts.ps1"
If fso.FileExists(exe1) Then
  sh.Run "powershell.exe -NoProfile -Command ""Start-Process -FilePath '" & Replace(exe1,"'","''") & "' -Verb RunAs""", 0, False
ElseIf fso.FileExists(exe2) Then
  sh.Run "powershell.exe -NoProfile -Command ""Start-Process -FilePath '" & Replace(exe2,"'","''") & "' -Verb RunAs""", 0, False
ElseIf fso.FileExists(ps1) Then
  sh.Run "powershell.exe -NoProfile -Command ""Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \""" & Replace(ps1,"'","''") & "\""' -Verb RunAs""", 0, False
Else
  MsgBox "Cannot find exe or ps1", 16, "Multi-account"
End If
