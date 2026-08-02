Option Explicit
Dim shell, fso, root, powershell, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
root = fso.GetParentFolderName(WScript.ScriptFullName)
powershell = shell.ExpandEnvironmentStrings("%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe")
command = Chr(34) & powershell & Chr(34) & " -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & root & "\Launch-CodexManaged.ps1" & Chr(34) & " -InstallRoot " & Chr(34) & root & Chr(34)
If WScript.Arguments.Count > 0 Then
    If LCase(WScript.Arguments(0)) = "--print-command" Then
        WScript.Echo command
        WScript.Quit 0
    End If
End If
shell.Run command, 0, False
