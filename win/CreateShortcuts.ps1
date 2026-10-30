#Requires -Version 5.0
# Windows multi-account shortcuts — WinForms, no console, pick from installed apps
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Title = '多账号快捷方式'
$USERPROFILE = $env:USERPROFILE
$LOCALAPPDATA = $env:LOCALAPPDATA
$APPDATA = $env:APPDATA
$PROGRAMFILES = ${env:ProgramFiles}
$PROGRAMFILES_X86 = ${env:ProgramFiles(x86)}
$PROGRAMDATA = $env:PROGRAMDATA

function Format-Size([long]$n) {
    if ($n -ge 1TB) { return ([math]::Round($n / 1TB, 1).ToString() + 'TB') }
    if ($n -ge 1GB) { return ([math]::Round($n / 1GB, 1).ToString() + 'GB') }
    if ($n -ge 1MB) { return ([math]::Round($n / 1MB, 1).ToString() + 'MB') }
    return ($n.ToString() + ' B')
}

function Normalize-Id([string]$raw) {
    $s = ($raw.Trim().ToLower() -replace '_','-' -replace ' ','-')
    $s = [regex]::Replace($s, '[^a-z0-9-]+', '-')
    $s = [regex]::Replace($s, '-{2,}', '-').Trim('-')
    if ([string]::IsNullOrEmpty($s)) { return 'account' }
    return $s
}

function Get-DesktopPath {
    $d = Join-Path $USERPROFILE 'Desktop'
    if (Test-Path $d -PathType Container) { return $d }
    $od = Join-Path $USERPROFILE 'OneDrive\Desktop'
    if (Test-Path $od -PathType Container) { return $od }
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

function Get-DrivesWithFree {
    $results = @()
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $drive.IsReady) { continue }
            if ($drive.DriveType -ne 'Fixed' -and $drive.DriveType -ne 'Removable') { continue }
            if ($drive.TotalSize -lt 1GB) { continue }
            if ($drive.AvailableFreeSpace -le 0) { continue }
            $results += [pscustomobject]@{
                Root = $drive.RootDirectory.FullName
                Free = [long]$drive.AvailableFreeSpace
                Total = [long]$drive.TotalSize
            }
        } catch {}
    }
    return $results | Sort-Object Free -Descending
}

function Get-FreestAppAccountsRoot {
    $drives = @(Get-DrivesWithFree)
    if ($drives.Count -eq 0) { return (Join-Path $USERPROFILE 'AppAccounts') }
    $best = $drives[0]
    $system = 'C:\'
    $nonSystem = @($drives | Where-Object { $_.Root.ToUpper() -ne $system })
    if ($nonSystem.Count -gt 0) {
        $alt = $nonSystem[0]
        if ($best.Root.ToUpper() -eq $system) {
            return (Join-Path $USERPROFILE 'AppAccounts')
        }
        return (Join-Path $alt.Root.TrimEnd('\') 'AppAccounts')
    }
    if ($best.Root.ToUpper().StartsWith('C:')) {
        return (Join-Path $USERPROFILE 'AppAccounts')
    }
    return (Join-Path $best.Root.TrimEnd('\') 'AppAccounts')
}

function Ensure-Dir([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

function New-Junction([string]$link, [string]$target) {
    if (Test-Path -LiteralPath $link) { return }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) { return }
    $parent = Split-Path $link -Parent
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $null = cmd /c "mklink /J `"$link`" `"$target`"" 2>&1
}

# --- Built-in presets (special isolation) ---
# Mode: workbuddy | electron | chrome | generic
$script:PresetRules = @(
    @{ Id='workbuddy'; Names=@('WorkBuddy','CodeBuddy'); Match=@('\workbuddy\','workbuddy.exe','\codebuddy\'); Mode='workbuddy'; Desc='腾讯龙虾，HOME隔离多账号' }
    @{ Id='cursor'; Names=@('Cursor'); Match=@('\cursor\','cursor.exe'); Mode='electron'; Desc='Cursor，独立 user-data' }
    @{ Id='vscode'; Names=@('Visual Studio Code','VS Code'); Match=@('microsoft vs code\code.exe','\code.exe'); Mode='electron'; Desc='VS Code，独立配置' }
    @{ Id='chrome'; Names=@('Google Chrome','Chrome'); Match=@('chrome\application\chrome.exe','google\chrome'); Mode='chrome'; Desc='Chrome，独立用户数据' }
    @{ Id='qoderwork'; Names=@('QoderWork','Qoder Work','QoderWork CN'); Match=@('qoderwork','qoder work'); Mode='electron'; Desc='QoderWork，独立 user-data' }
    @{ Id='qoder'; Names=@('Qoder'); Match=@('\qoder\qoder.exe','\programs\qoder\'); Mode='electron'; Desc='Qoder，独立 user-data' }
    @{ Id='grokbot'; Names=@('Grok Bot','GrokBot'); Match=@('grok bot\grok bot.exe','\grokbot\','grok bot.exe'); Mode='electron'; Desc='Grok Bot，独立 user-data' }
)

function Resolve-Preset([string]$name, [string]$exePath) {
    $n = $name.ToLowerInvariant()
    $p = $exePath.ToLowerInvariant().Replace('/','\')
    foreach ($rule in $script:PresetRules) {
        foreach ($dn in $rule.Names) {
            $d = $dn.ToLowerInvariant()
            if ($n -eq $d -or $n.StartsWith($d + ' ')) { return $rule }
        }
        foreach ($m in $rule.Match) {
            $mm = $m.ToLowerInvariant()
            if ($p.Contains($mm) -or $n.Contains($mm.Trim('\'))) { return $rule }
        }
    }
    return $null
}

function Test-LikelyElectron([string]$exePath) {
    try {
        $dir = Split-Path $exePath -Parent
        $markers = @(
            (Join-Path $dir 'resources\app.asar'),
            (Join-Path $dir 'resources\electron.asar'),
            (Join-Path $dir 'resources\default_app.asar'),
            (Join-Path $dir 'chrome_100_percent.pak'),
            (Join-Path $dir 'v8_context_snapshot.bin')
        )
        foreach ($m in $markers) {
            if (Test-Path -LiteralPath $m) { return $true }
        }
        # sibling Resources (some layouts)
        $upar = Join-Path $dir 'resources'
        if (Test-Path -LiteralPath $upar) {
            $asar = Get-ChildItem -LiteralPath $upar -Filter '*.asar' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($asar) { return $true }
        }
    } catch {}
    return $false
}

function Get-WshShell {
    if (-not $script:WshShell) {
        $script:WshShell = New-Object -ComObject WScript.Shell
    }
    return $script:WshShell
}

function Get-ShortcutTarget([string]$lnkPath) {
    try {
        $ws = Get-WshShell
        $s = $ws.CreateShortcut($lnkPath)
        $t = $s.TargetPath
        if ($t -and $t.ToLower().EndsWith('.exe') -and (Test-Path -LiteralPath $t -PathType Leaf)) {
            return [pscustomobject]@{ Path=$t; Name=[IO.Path]::GetFileNameWithoutExtension($lnkPath); Args=$s.Arguments }
        }
    } catch {}
    return $null
}

function Add-AppCandidate([System.Collections.Generic.Dictionary[string,object]]$map, [string]$name, [string]$exe, [string]$source) {
    if (-not $exe) { return }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { return }
    $leaf = [IO.Path]::GetFileName($exe).ToLowerInvariant()
    # skip uninstallers / helpers / sidecars
    if ($leaf -match 'uninstall|update|crash|helper|setup|installer|elevate\.exe|cmd\.exe|powershell|pwsh|wscript|cscript|code-tunnel|sharetarget|share-target|launcher\.exe|notification|cefsharp|squirrel') { return }
    if ($name -match 'uninstall|卸载|更新|setup|installer|elevate|share target|sharetarget') { return }
    # skip resources\ subfolder binaries
    if ($exe -match '(?i)[\\/]resources[\\/]') { return }
    if ($exe -match '(?i)[\\/]bin[\\/]code-tunnel') { return }
    try {
        $key = (Resolve-Path -LiteralPath $exe).Path.ToLowerInvariant()
    } catch {
        $key = $exe.ToLowerInvariant()
    }
    if ($map.ContainsKey($key)) { return }
    $display = if ($name) { $name.Trim() } else { [IO.Path]::GetFileNameWithoutExtension($exe) }
    if ([string]::IsNullOrWhiteSpace($display)) { return }
    $preset = Resolve-Preset $display $exe
    $mode = 'generic'
    $desc = '通用启动（尝试独立数据目录）'
    $toolId = Normalize-Id $display
    if ($preset) {
        $mode = $preset.Mode
        $desc = $preset.Desc
        $toolId = $preset.Id
        # prefer preset display name
        foreach ($dn in $preset.Names) {
            if ($display -like "$dn*" -or $display -eq $dn) { $display = $dn; break }
        }
    } elseif (Test-LikelyElectron $exe) {
        $mode = 'electron'
        $desc = '疑似 Electron，使用 --user-data-dir 隔离'
    }
    $map[$key] = [pscustomobject]@{
        Id = $toolId
        Name = $display
        Exe = $exe
        Mode = $mode
        Desc = $desc
        Source = $source
        IsPreset = [bool]$preset
    }
}

function Find-ExeInFolder([string]$folder, [string[]]$preferredNames) {
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return $null }
    foreach ($n in $preferredNames) {
        $c = Join-Path $folder $n
        if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    }
    try {
        $exes = @(Get-ChildItem -LiteralPath $folder -Filter '*.exe' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch 'uninstall|update|crash|helper|setup' })
        if ($exes.Count -eq 1) { return $exes[0].FullName }
        # prefer exe matching folder name
        $fname = [IO.Path]::GetFileName($folder)
        $hit = $exes | Where-Object { $_.BaseName -ieq $fname } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
        if ($exes.Count -gt 0) { return $exes[0].FullName }
    } catch {}
    return $null
}

function Get-InstalledApps {
    $map = New-Object 'System.Collections.Generic.Dictionary[string,object]'

    # 1) Start Menu shortcuts (fast, user-visible apps)
    $startRoots = @(
        (Join-Path $APPDATA 'Microsoft\Windows\Start Menu\Programs'),
        (Join-Path $PROGRAMDATA 'Microsoft\Windows\Start Menu\Programs')
    )
    foreach ($root in $startRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        try {
            # Depth-limited: deep OEM trees are slow
            Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -Depth 5 -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $info = Get-ShortcutTarget $_.FullName
                    if ($info) {
                        Add-AppCandidate $map $info.Name $info.Path 'StartMenu'
                    }
                }
        } catch {}
    }

    # 2) LocalAppData\Programs (Electron apps often here)
    $lap = Join-Path $LOCALAPPDATA 'Programs'
    if (Test-Path -LiteralPath $lap -PathType Container) {
        try {
            Get-ChildItem -LiteralPath $lap -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $exe = Find-ExeInFolder $_.FullName @("$($_.Name).exe")
                if ($exe) { Add-AppCandidate $map $_.Name $exe 'LocalPrograms' }
                # one level deeper
                Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    $exe2 = Find-ExeInFolder $_.FullName @("$($_.Name).exe", "$($_.Parent.Name).exe")
                    if ($exe2) { Add-AppCandidate $map $_.Parent.Name $exe2 'LocalPrograms' }
                }
            }
        } catch {}
    }

    # 3) Common Program Files (shallow)
    foreach ($pf in @($PROGRAMFILES, $PROGRAMFILES_X86)) {
        if (-not $pf) { continue }
        if (-not (Test-Path -LiteralPath $pf -PathType Container)) { continue }
        try {
            # Only top-level + one child level; skip huge trees (Windows Kits, etc.)
            Get-ChildItem -LiteralPath $pf -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '^(Windows Kits|Reference Assemblies|MSBuild|dotnet|ModifiableWindowsApps)$' } |
                Select-Object -First 80 |
                ForEach-Object {
                    $exe = Find-ExeInFolder $_.FullName @("$($_.Name).exe")
                    if ($exe) { Add-AppCandidate $map $_.Name $exe 'ProgramFiles' }
                    Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue | Select-Object -First 4 | ForEach-Object {
                        $exe2 = Find-ExeInFolder $_.FullName @("$($_.Name).exe", "$($_.Parent.Name).exe")
                        if ($exe2) {
                            $nm = if ($_.Parent) { $_.Parent.Name } else { $_.Name }
                            Add-AppCandidate $map $nm $exe2 'ProgramFiles'
                        }
                    }
                }
        } catch {}
    }

    # 4) Explicit known locations (Qoder / Grok / WorkBuddy etc.)
    $known = @(
        @{ Name='WorkBuddy'; Paths=@(
            (Join-Path $LOCALAPPDATA 'Programs\WorkBuddy\WorkBuddy.exe'),
            (Join-Path $LOCALAPPDATA 'Programs\CodeBuddy\WorkBuddy.exe'),
            (Join-Path $LOCALAPPDATA 'Programs\CodeBuddy\CodeBuddy.exe')
        )}
        @{ Name='Cursor'; Paths=@(
            (Join-Path $LOCALAPPDATA 'Programs\cursor\Cursor.exe'),
            (Join-Path $LOCALAPPDATA 'Programs\Cursor\Cursor.exe')
        )}
        @{ Name='VS Code'; Paths=@(
            (Join-Path $LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'),
            (Join-Path $PROGRAMFILES 'Microsoft VS Code\Code.exe')
        )}
        @{ Name='Chrome'; Paths=@(
            (Join-Path $PROGRAMFILES 'Google\Chrome\Application\chrome.exe'),
            (Join-Path $PROGRAMFILES_X86 'Google\Chrome\Application\chrome.exe'),
            (Join-Path $LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
        )}
        @{ Name='Qoder'; Paths=@(
            (Join-Path $LOCALAPPDATA 'Programs\Qoder\Qoder.exe'),
            (Join-Path $LOCALAPPDATA 'Programs\qoder\Qoder.exe'),
            (Join-Path $PROGRAMFILES 'Qoder\Qoder.exe')
        )}
        @{ Name='QoderWork'; Paths=@(
            (Join-Path $LOCALAPPDATA 'Programs\QoderWork\QoderWork.exe'),
            (Join-Path $LOCALAPPDATA 'Programs\Qoder Work\QoderWork.exe'),
            (Join-Path $PROGRAMFILES 'QoderWork\QoderWork.exe')
        )}
        @{ Name='Grok Bot'; Paths=@(
            (Join-Path $LOCALAPPDATA 'Programs\Grok Bot\Grok Bot.exe'),
            (Join-Path $LOCALAPPDATA 'Programs\GrokBot\GrokBot.exe'),
            (Join-Path $LOCALAPPDATA 'Programs\Grok\Grok.exe'),
            (Join-Path $PROGRAMFILES 'Grok Bot\Grok Bot.exe')
        )}
    )
    foreach ($k in $known) {
        foreach ($p in $k.Paths) {
            if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) {
                Add-AppCandidate $map $k.Name $p 'Known'
                break
            }
        }
    }

    $list = @($map.Values)
    # Drop weaker duplicates of same Id when a better main exe exists
    $byId = @{}
    foreach ($a in $list) {
        $key = if ($a.IsPreset) { $a.Id } else { $a.Exe.ToLowerInvariant() }
        $score = 0
        $leaf = [IO.Path]::GetFileNameWithoutExtension($a.Exe)
        if ($leaf -ieq $a.Name) { $score += 5 }
        if ($a.Exe -match '(?i)Programs\\') { $score += 2 }
        if ($a.Source -eq 'Known') { $score += 4 }
        if ($a.Source -eq 'StartMenu') { $score += 1 }
        if (-not $byId.ContainsKey($key)) {
            $byId[$key] = @{ App=$a; Score=$score }
        } elseif ($score -gt $byId[$key].Score) {
            $byId[$key] = @{ App=$a; Score=$score }
        }
    }
    $list = @($byId.Values | ForEach-Object { $_.App })
    return @($list | Sort-Object @{Expression={-not $_.IsPreset}}, @{Expression={$_.Name}})
}

$script:ProfilePresets = @(
    [pscustomobject]@{ Label='两个账号：account1 + account2（推荐）'; Pairs=@(
        @{Profile='account1'; Display='account1'}, @{Profile='account2'; Display='account2'}) }
    [pscustomobject]@{ Label='两个账号：工作 + 个人'; Pairs=@(
        @{Profile='work'; Display='工作'}, @{Profile='personal'; Display='个人'}) }
    [pscustomobject]@{ Label='三个账号：account1~account3'; Pairs=@(
        @{Profile='account1'; Display='account1'}, @{Profile='account2'; Display='account2'}, @{Profile='account3'; Display='account3'}) }
    [pscustomobject]@{ Label='四个账号：account1~account4'; Pairs=@(
        @{Profile='account1'; Display='account1'}, @{Profile='account2'; Display='account2'},
        @{Profile='account3'; Display='account3'}, @{Profile='account4'; Display='account4'}) }
    [pscustomobject]@{ Label='只要一个账号：account1'; Pairs=@(
        @{Profile='account1'; Display='account1'}) }
)

function Prepare-WorkBuddyDirs([string]$accountDir) {
    Ensure-Dir (Join-Path $accountDir 'app')
    Ensure-Dir (Join-Path $accountDir 'auth')
    $runtime = Join-Path $accountDir 'runtime-home'
    Ensure-Dir (Join-Path $runtime 'AppData\Roaming\CodeBuddyExtension\Data\Public\auth')
    Ensure-Dir (Join-Path $runtime 'AppData\Local')
    # WorkBuddy ignores CLI --user-data-dir and writes to %USERPROFILE%\.workbuddy\app
    Ensure-Dir (Join-Path $runtime '.workbuddy\app')
    foreach ($name in @('Desktop','Downloads','Documents','Pictures','Videos','Music')) {
        $src = Join-Path $USERPROFILE $name
        $dst = Join-Path $runtime $name
        New-Junction $dst $src
    }
}

function Prepare-ElectronDirs([string]$accountDir) {
    Ensure-Dir $accountDir
    Ensure-Dir (Join-Path $accountDir 'extensions')
}

function Write-WorkBuddyVbs([string]$path, [string]$profile, [string]$accountDir, [string]$exe) {
    # WorkBuddy (Windows) stores state under %USERPROFILE%\.workbuddy\app and largely
    # ignores --user-data-dir. Isolation requires rewriting USERPROFILE/HOME for the
    # child process. VBScript Environment("Process") + shell.Run does NOT stick for
    # this Electron app; launching via cmd.exe "set ... && start" does (verified).
    $electron = Join-Path $accountDir 'app'
    $runtime = Join-Path $accountDir 'runtime-home'
    $realHome = $USERPROFILE
    $appdata = Join-Path $runtime 'AppData\Roaming'
    $localappdata = Join-Path $runtime 'AppData\Local'
    $authDir = Join-Path $appdata 'CodeBuddyExtension\Data\Public\auth'
    $wbApp = Join-Path $runtime '.workbuddy\app'
    if ($runtime.Length -ge 2 -and $runtime[1] -eq ':') {
        $homedrive = $runtime.Substring(0,2)
        $homepath = if ($runtime.Length -gt 2) { $runtime.Substring(2) } else { '\' }
    } else {
        $homedrive = 'C:'
        $homepath = $runtime
    }
    function Esc([string]$s) { return $s.Replace('"','""') }
    function EscCmd([string]$s) {
        # for embedding inside cmd /c "..." — escape meta chars lightly
        return $s.Replace('^','^^').Replace('&','^&').Replace('|','^|').Replace('<','^<').Replace('>','^>')
    }
    $lines = @(
        "' WorkBuddy multi-account launcher (no console)"
        "' profile: $profile"
        "' Uses cmd setenv+start — VBS Process env is ignored by WorkBuddy.exe"
        'Option Explicit'
        'Dim shell, fso, accountDir, electronDir, runtimeHome, realHome, exePath'
        'Dim appDataDir, localAppDataDir, authDir, wbAppDir, cmd, folderName, linkPath, targetPath, q'
        'Dim homeDrive, homePath'
        ''
        'Set shell = CreateObject("WScript.Shell")'
        'Set fso = CreateObject("Scripting.FileSystemObject")'
        'q = Chr(34)'
        ''
        ('accountDir = "' + (Esc $accountDir) + '"')
        ('electronDir = "' + (Esc $electron) + '"')
        ('runtimeHome = "' + (Esc $runtime) + '"')
        ('realHome = "' + (Esc $realHome) + '"')
        ('exePath = "' + (Esc $exe) + '"')
        ('appDataDir = "' + (Esc $appdata) + '"')
        ('localAppDataDir = "' + (Esc $localappdata) + '"')
        ('authDir = "' + (Esc $authDir) + '"')
        ('wbAppDir = "' + (Esc $wbApp) + '"')
        ('homeDrive = "' + (Esc $homedrive) + '"')
        ('homePath = "' + (Esc $homepath) + '"')
        ''
        'If Not fso.FolderExists(electronDir) Then fso.CreateFolder(electronDir)'
        'If Not fso.FolderExists(accountDir & "\auth") Then'
        '  If Not fso.FolderExists(accountDir) Then fso.CreateFolder(accountDir)'
        '  fso.CreateFolder(accountDir & "\auth")'
        'End If'
        'EnsureFolder runtimeHome'
        'EnsureFolder runtimeHome & "\AppData"'
        'EnsureFolder runtimeHome & "\AppData\Roaming"'
        'EnsureFolder runtimeHome & "\AppData\Local"'
        'EnsureFolder appDataDir & "\CodeBuddyExtension"'
        'EnsureFolder appDataDir & "\CodeBuddyExtension\Data"'
        'EnsureFolder appDataDir & "\CodeBuddyExtension\Data\Public"'
        'EnsureFolder authDir'
        'EnsureFolder runtimeHome & "\.workbuddy"'
        'EnsureFolder wbAppDir'
        ''
        'For Each folderName In Array("Desktop", "Downloads", "Documents", "Pictures", "Videos", "Music")'
        '  targetPath = realHome & "\" & folderName'
        '  linkPath = runtimeHome & "\" & folderName'
        '  If fso.FolderExists(targetPath) Then'
        '    If Not fso.FolderExists(linkPath) Then'
        '      shell.Run "cmd /c mklink /J " & q & linkPath & q & " " & q & targetPath & q, 0, True'
        '    End If'
        '  End If'
        'Next'
        ''
        "' Rewrite USERPROFILE via cmd so WorkBuddy inherits it (shell.Run alone does not)."
        'cmd = "cmd /c " & q & _'
        '  "set USERPROFILE=" & runtimeHome & _'
        '  "&& set HOME=" & runtimeHome & _'
        '  "&& set HOMEDRIVE=" & homeDrive & _'
        '  "&& set HOMEPATH=" & homePath & _'
        '  "&& set APPDATA=" & appDataDir & _'
        '  "&& set LOCALAPPDATA=" & localAppDataDir & _'
        '  "&& set WORKBUDDY_CONFIG_DIR=" & accountDir & _'
        '  "&& set CODEBUDDY_CONFIG_DIR=" & accountDir & _'
        '  "&& set WORKBUDDY_USER_DATA_DIR=" & wbAppDir & _'
        '  "&& set ELECTRON_RUN_AS_NODE=" & _'
        '  "&& start " & q & q & " " & q & exePath & q & " --new-window" & q'
        'shell.Run cmd, 0, False'
        'WScript.Quit 0'
        ''
        'Sub EnsureFolder(path)'
        '  Dim parts, i, cur, fso2'
        '  Set fso2 = CreateObject("Scripting.FileSystemObject")'
        '  If fso2.FolderExists(path) Then Exit Sub'
        '  parts = Split(path, "\")'
        '  If UBound(parts) < 0 Then Exit Sub'
        '  cur = parts(0)'
        '  For i = 1 To UBound(parts)'
        '    If parts(i) <> "" Then'
        '      cur = cur & "\" & parts(i)'
        '      If Not fso2.FolderExists(cur) Then'
        '        On Error Resume Next'
        '        fso2.CreateFolder(cur)'
        '        On Error GoTo 0'
        '      End If'
        '    End If'
        '  Next'
        'End Sub'
        ''
    )
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, ($lines -join "`r`n"), $utf8)
}

function Write-GenericVbs([string]$path, [string]$accountDir, [string]$exe, [string]$extraArgs) {
    function Esc([string]$s) { return $s.Replace('"','""') }
    $argPart = if ($extraArgs) { ' & " " & "' + (Esc $extraArgs) + '"' } else { '' }
    $lines = @(
        "' Generic multi-account launcher (no console)"
        'Option Explicit'
        'Dim shell, fso, q, exePath, dataDir, cmd'
        'Set shell = CreateObject("WScript.Shell")'
        'Set fso = CreateObject("Scripting.FileSystemObject")'
        'q = Chr(34)'
        ('exePath = "' + (Esc $exe) + '"')
        ('dataDir = "' + (Esc $accountDir) + '"')
        'If Not fso.FolderExists(dataDir) Then fso.CreateFolder(dataDir)'
        ('cmd = q & exePath & q & " --user-data-dir=" & q & dataDir & q' + $argPart)
        'shell.Run cmd, 1, False'
        'WScript.Quit 0'
    )
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, ($lines -join "`r`n"), $utf8)
}

function Create-ShortcutLnk([string]$lnkPath, [string]$target, [string]$arguments = '', [string]$workdir = '', [string]$icon = '') {
    $dir = Split-Path $lnkPath -Parent
    Ensure-Dir $dir
    if (-not $workdir) { $workdir = Split-Path $target -Parent }
    if (-not $icon) { $icon = $target }
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($lnkPath)
    $s.TargetPath = $target
    $s.Arguments = $arguments
    $s.WorkingDirectory = $workdir
    $s.IconLocation = "$icon,0"
    $s.WindowStyle = 1
    $s.Save()
}

function Show-Info([string]$message, [string]$t = $script:Title) {
    [System.Windows.Forms.MessageBox]::Show($message, $t, 'OK', 'Information') | Out-Null
}
function Show-Warn([string]$message, [string]$t = $script:Title) {
    [System.Windows.Forms.MessageBox]::Show($message, $t, 'OK', 'Warning') | Out-Null
}
function Show-Confirm([string]$message, [string]$t = '确认创建') {
    $r = [System.Windows.Forms.MessageBox]::Show($message, $t, 'YesNo', 'Question')
    return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Show-ChoiceForm([string]$prompt, [string[]]$labels, [string]$formTitle = $script:Title, [int]$defaultIndex = 0) {
    if ($defaultIndex -lt 0 -or $defaultIndex -ge $labels.Count) { $defaultIndex = 0 }
    $script:ChoiceSelected = $defaultIndex
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $formTitle
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
    $form.TopMost = $true
    $form.AutoScaleMode = 'Dpi'
    $rowH = 48
    $maxH = [Math]::Min(420, ($labels.Count * $rowH) + 8)
    $form.ClientSize = New-Object System.Drawing.Size(620, (90 + $maxH + 80))

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $prompt
    $lbl.Left = 20; $lbl.Top = 14; $lbl.Width = 580; $lbl.Height = 50
    $lbl.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 13, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lbl)

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Left = 20; $panel.Top = 70
    $panel.Width = 580; $panel.Height = $maxH
    $panel.AutoScroll = $true
    $form.Controls.Add($panel)

    for ($i = 0; $i -lt $labels.Count; $i++) {
        $rb = New-Object System.Windows.Forms.RadioButton
        $rb.Text = $labels[$i]
        $rb.Left = 6; $rb.Top = ($i * $rowH); $rb.Width = 540; $rb.Height = ($rowH - 4)
        $rb.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
        $rb.Tag = $i
        if ($i -eq $defaultIndex) { $rb.Checked = $true }
        $rb.Add_CheckedChanged({ if ($this.Checked) { $script:ChoiceSelected = [int]$this.Tag } })
        $panel.Controls.Add($rb)
    }

    $y = 70 + $maxH + 16
    $next = New-Object System.Windows.Forms.Button
    $next.Text = '下一步'; $next.Left = 360; $next.Top = $y; $next.Width = 140; $next.Height = 44
    $next.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
    $next.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($next); $form.AcceptButton = $next

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'; $cancel.Left = 120; $cancel.Top = $y; $cancel.Width = 140; $cancel.Height = 44
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel); $form.CancelButton = $cancel

    $dr = $form.ShowDialog()
    $idx = [int]$script:ChoiceSelected
    $form.Dispose()
    if ($dr -ne [System.Windows.Forms.DialogResult]::OK) { return -1 }
    return $idx
}

function Show-AppPickerForm([object[]]$apps) {
    $script:AppPickIndex = -1
    $script:AllApps = @($apps)
    $script:Filtered = @($apps)
    $script:PickerList = $null
    $script:PickerStatus = $null
    $script:PickerNext = $null
    $script:PickerSearch = $null

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $script:Title
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object System.Drawing.Size(700, 520)
    $form.MinimumSize = New-Object System.Drawing.Size(640, 480)
    $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
    $form.TopMost = $true
    $form.AutoScaleMode = 'Dpi'
    $form.MaximizeBox = $true

    $header = New-Object System.Windows.Forms.Label
    $header.Text = '第1步：从本机已安装的应用中选择'
    $header.Left = 16; $header.Top = 12; $header.Width = 660; $header.Height = 32
    $header.Anchor = 'Top,Left,Right'
    $header.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($header)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = '可搜索名称；带 [推荐] 的有特殊隔离。选中后点下一步，或双击。'
    $hint.Left = 16; $hint.Top = 44; $hint.Width = 660; $hint.Height = 24
    $hint.Anchor = 'Top,Left,Right'
    $hint.ForeColor = [System.Drawing.Color]::FromArgb(26, 115, 232)
    $form.Controls.Add($hint)

    $searchBox = New-Object System.Windows.Forms.TextBox
    $searchBox.Left = 16; $searchBox.Top = 74; $searchBox.Width = 660; $searchBox.Height = 28
    $searchBox.Anchor = 'Top,Left,Right'
    $searchBox.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12)
    $form.Controls.Add($searchBox)
    $script:PickerSearch = $searchBox

    $status = New-Object System.Windows.Forms.Label
    $status.Left = 16; $status.Top = 108; $status.Width = 660; $status.Height = 22
    $status.Anchor = 'Top,Left,Right'
    $status.ForeColor = [System.Drawing.Color]::FromArgb(95, 99, 104)
    $form.Controls.Add($status)
    $script:PickerStatus = $status

    $list = New-Object System.Windows.Forms.ListBox
    $list.Left = 16; $list.Top = 134; $list.Width = 660; $list.Height = 310
    $list.Anchor = 'Top,Bottom,Left,Right'
    $list.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11)
    $list.IntegralHeight = $false
    $form.Controls.Add($list)
    $script:PickerList = $list

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.Width = 120; $btnCancel.Height = 42
    $btnCancel.Left = 16; $btnCancel.Top = 460
    $btnCancel.Anchor = 'Bottom,Left'
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)
    $form.CancelButton = $btnCancel

    $btnNext = New-Object System.Windows.Forms.Button
    $btnNext.Text = '下一步'
    $btnNext.Width = 160; $btnNext.Height = 42
    $btnNext.Left = 520; $btnNext.Top = 460
    $btnNext.Anchor = 'Bottom,Right'
    $btnNext.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
    $btnNext.Enabled = $false
    $form.Controls.Add($btnNext)
    $script:PickerNext = $btnNext

    $refresh = {
        $q = ''
        if ($script:PickerSearch -and $script:PickerSearch.Text) {
            $q = $script:PickerSearch.Text.Trim().ToLowerInvariant()
        }
        $script:Filtered = @()
        foreach ($a in $script:AllApps) {
            $hit = $false
            if ($q -eq '') { $hit = $true }
            elseif ($a.Name.ToLowerInvariant().Contains($q)) { $hit = $true }
            elseif ($a.Desc.ToLowerInvariant().Contains($q)) { $hit = $true }
            elseif ($a.Exe.ToLowerInvariant().Contains($q)) { $hit = $true }
            if ($hit) { $script:Filtered += $a }
        }
        $script:PickerList.BeginUpdate()
        $script:PickerList.Items.Clear()
        foreach ($a in $script:Filtered) {
            $tag = if ($a.IsPreset) { '[推荐] ' } else { '' }
            $modeTag = '通用'
            if ($a.Mode -eq 'workbuddy') { $modeTag = 'HOME隔离' }
            elseif ($a.Mode -eq 'electron') { $modeTag = 'user-data' }
            elseif ($a.Mode -eq 'chrome') { $modeTag = 'Chrome配置' }
            [void]$script:PickerList.Items.Add(("$tag" + $a.Name + '  —  ' + $modeTag + '  ·  ' + $a.Desc))
        }
        $script:PickerList.EndUpdate()
        $script:PickerStatus.Text = ('共 ' + $script:Filtered.Count + ' 个应用（全部 ' + $script:AllApps.Count + '） · 已选：—')
        $script:PickerNext.Enabled = $false
        $script:AppPickIndex = -1
    }
    $script:PickerRefresh = $refresh

    $searchBox.Add_TextChanged({ & $script:PickerRefresh })
    $list.Add_SelectedIndexChanged({
        if ($script:PickerList.SelectedIndex -ge 0 -and $script:PickerList.SelectedIndex -lt $script:Filtered.Count) {
            $script:AppPickIndex = $script:PickerList.SelectedIndex
            $a = $script:Filtered[$script:PickerList.SelectedIndex]
            $script:PickerStatus.Text = ('已选：' + $a.Name + '  ·  ' + $a.Exe)
            $script:PickerNext.Enabled = $true
        }
    })
    $list.Add_DoubleClick({
        if ($script:PickerList.SelectedIndex -ge 0) {
            $script:AppPickIndex = $script:PickerList.SelectedIndex
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        }
    })
    $btnNext.Add_Click({
        if ($script:PickerList.SelectedIndex -ge 0) {
            $script:AppPickIndex = $script:PickerList.SelectedIndex
            $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $form.Close()
        }
    })
    $form.Add_Shown({
        $form.TopMost = $false
        & $script:PickerRefresh
        $script:PickerSearch.Focus()
    })
    $form.Add_Resize({
        $script:PickerNext.Left = ($form.ClientSize.Width - 180)
        $script:PickerSearch.Width = ($form.ClientSize.Width - 40)
        $script:PickerList.Width = ($form.ClientSize.Width - 40)
        $script:PickerList.Height = ($form.ClientSize.Height - 210)
        $btnCancel.Top = ($form.ClientSize.Height - 60)
        $script:PickerNext.Top = ($form.ClientSize.Height - 60)
    })

    $dr = $form.ShowDialog()
    $picked = $null
    if ($dr -eq [System.Windows.Forms.DialogResult]::OK -and $script:AppPickIndex -ge 0 -and $script:AppPickIndex -lt $script:Filtered.Count) {
        $picked = $script:Filtered[$script:AppPickIndex]
    }
    $form.Dispose()
    return $picked
}

function Invoke-Create {
    $loading = New-Object System.Windows.Forms.Form
    $loading.Text = $script:Title
    $loading.StartPosition = 'CenterScreen'
    $loading.FormBorderStyle = 'FixedDialog'
    $loading.ControlBox = $false
    $loading.Size = New-Object System.Drawing.Size(360, 120)
    $loading.TopMost = $true
    $ll = New-Object System.Windows.Forms.Label
    $ll.Text = "正在扫描本机已安装的应用…`n请稍候"
    $ll.Dock = 'Fill'
    $ll.TextAlign = 'MiddleCenter'
    $ll.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12)
    $loading.Controls.Add($ll)
    $loading.Show()
    [System.Windows.Forms.Application]::DoEvents()

    $apps = @()
    try {
        $apps = @(Get-InstalledApps)
    } catch {
        $loading.Close(); $loading.Dispose()
        Show-Warn "扫描应用失败：`n$($_.Exception.Message)"
        return
    }
    $loading.Close(); $loading.Dispose()

    if ($apps.Count -eq 0) {
        Show-Warn "没有扫描到可配置的应用。`n请确认开始菜单或 LocalAppData\Programs 里有程序。"
        return
    }

    $tool = Show-AppPickerForm $apps
    if (-not $tool) { return }

    # warn for generic mode
    if ($tool.Mode -eq 'generic') {
        $ok = Show-Confirm ("【$($tool.Name)】不是已知的 Electron/Chrome 类应用。`n`n将尝试用 --user-data-dir 隔离；若程序忽略该参数，多开可能仍会串号。`n`n是否继续？")
        if (-not $ok) { return }
    }

    # Step 2: account plan
    $presetLabels = @($script:ProfilePresets | ForEach-Object { $_.Label })
    $pi = Show-ChoiceForm '第2步：请选择账号方案：' $presetLabels
    if ($pi -lt 0) { return }
    $preset = $script:ProfilePresets[$pi]

    # Step 3: data root
    $defaultRoot = Get-FreestAppAccountsRoot
    $drives = @(Get-DrivesWithFree)
    $rootLabels = @(); $rootValues = @()
    $freeLabel = ''; $place = '用户目录'
    if ($drives.Count -gt 0) {
        $m = $drives[0]
        $freeLabel = "，剩余 $(Format-Size $m.Free)"
        if ($m.Root.ToUpper().StartsWith('C:')) { $place = '系统盘 - 用户目录' }
        else { $place = "磁盘 $($m.Root)" }
    }
    $rootLabels += "默认：最空闲磁盘（$place$freeLabel）"
    $rootValues += $defaultRoot
    $extra = 0
    foreach ($d in $drives) {
        if ($d.Root.ToUpper().StartsWith('C:')) { continue }
        $cand = Join-Path $d.Root.TrimEnd('\') 'AppAccounts'
        if ($cand -eq $defaultRoot) { continue }
        $rootLabels += "磁盘 $($d.Root)AppAccounts（剩余 $(Format-Size $d.Free)）"
        $rootValues += $cand
        $extra++; if ($extra -ge 3) { break }
    }
    $rootLabels += (Join-Path $USERPROFILE 'AppAccounts'); $rootValues += (Join-Path $USERPROFILE 'AppAccounts')
    $desk = Get-DesktopPath
    $rootLabels += (Join-Path $desk 'AppAccounts'); $rootValues += (Join-Path $desk 'AppAccounts')
    $docs = Join-Path $USERPROFILE 'Documents\AppAccounts'
    $rootLabels += $docs; $rootValues += $docs

    $ri = Show-ChoiceForm '第3步：请选择数据存放位置：' $rootLabels
    if ($ri -lt 0) { return }
    $root = $rootValues[$ri]

    $plans = @()
    foreach ($pair in $preset.Pairs) {
        $profile = Normalize-Id $pair.Profile
        $dataDir = Join-Path $root (Join-Path (Normalize-Id $tool.Id) $profile)
        $plans += [pscustomobject]@{ Profile=$profile; Display=$pair.Display; DataDir=$dataDir }
    }

    $lines = @("将为【$($tool.Name)】创建 $($plans.Count) 个账号快捷方式：", '')
    foreach ($p in $plans) {
        $lines += "* $($p.Display)（$($p.Profile)）"
        $lines += "  $($p.DataDir)"
    }
    $lines += ''
    $lines += "隔离方式：$($tool.Mode) — $($tool.Desc)"
    $lines += "程序：$($tool.Exe)"
    if (-not (Show-Confirm ($lines -join "`n"))) { return }

    $desktop = Get-DesktopPath
    $exe = $tool.Exe
    $results = @()
    try {
        foreach ($plan in $plans) {
            $accountDir = $plan.DataDir
            $lnkName = "$($tool.Name)-$($plan.Profile).lnk" -replace '[\\/:*?"<>|]', '-'
            $lnkPath = Join-Path $desktop $lnkName

            switch ($tool.Mode) {
                'workbuddy' {
                    Prepare-WorkBuddyDirs $accountDir
                    $vbsPath = Join-Path $accountDir 'launch.vbs'
                    Write-WorkBuddyVbs $vbsPath $plan.Profile $accountDir $exe
                    $wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
                    Create-ShortcutLnk $lnkPath $wscript ("//nologo `"$vbsPath`"") $accountDir $exe
                }
                'chrome' {
                    Ensure-Dir $accountDir
                    $args = "--user-data-dir=`"$accountDir`" --no-first-run --no-default-browser-check --new-window"
                    Create-ShortcutLnk $lnkPath $exe $args (Split-Path $exe -Parent) $exe
                }
                'electron' {
                    Prepare-ElectronDirs $accountDir
                    $args = "--user-data-dir=`"$accountDir`" --extensions-dir=`"$accountDir\extensions`" --new-window"
                    Create-ShortcutLnk $lnkPath $exe $args (Split-Path $exe -Parent) $exe
                }
                default {
                    Ensure-Dir $accountDir
                    # try --user-data-dir via silent vbs so odd apps still get a clean launch
                    $vbsPath = Join-Path $accountDir 'launch.vbs'
                    Write-GenericVbs $vbsPath $accountDir $exe '--new-window'
                    Create-ShortcutLnk $lnkPath $vbsPath '' $accountDir $exe
                }
            }
            $results += [pscustomobject]@{ Display=$plan.Display; DataDir=$accountDir; Shortcut=$lnkPath }
        }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'access|拒绝|denied|Unauthorized|权限') {
            Show-Warn "写入失败，可能需要管理员权限。`n错误：$msg`n`n请右键 exe → 以管理员身份运行后重试。`n（一般选用户目录不需要管理员）"
        } else {
            Show-Warn "创建失败：`n$msg"
        }
        return
    }

    $done = @("已创建 $($results.Count) 个 $($tool.Name) 快捷方式：", '')
    foreach ($item in $results) {
        $done += "* $($item.Display)"
        $done += "  数据：$($item.DataDir)"
        $done += "  桌面：$(Split-Path $item.Shortcut -Leaf)"
    }
    $done += ''
    $done += '去桌面双击即可打开对应账号（不会出现黑色命令行窗口）。'
    if ($tool.Mode -eq 'workbuddy') {
        $done += ''
        $done += '重要：请完全退出原来的 WorkBuddy 后，只用新快捷方式打开。'
        $done += '每个窗口第一次要分别登录；登录态已按账号隔离，不会再串号。'
    }
    if ($tool.Mode -eq 'generic') {
        $done += ''
        $done += '提示：该应用为通用模式。若多开仍串号，说明程序不支持 --user-data-dir。'
    }
    Show-Info ($done -join "`n")
}

try {
    Invoke-Create
} catch {
    Show-Warn "出错：`n$($_.Exception.Message)"
}
