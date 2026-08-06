' ============================================================
'  SA Privacy & Cybersecurity Framework
'  Creates a Desktop Shortcut for the App
' ============================================================

Dim oShell, oFS, sAppDir, sShortcutPath, oShortcut

Set oShell = CreateObject("WScript.Shell")
Set oFS    = CreateObject("Scripting.FileSystemObject")

' Get the folder this script lives in
sAppDir = oFS.GetParentFolderName(WScript.ScriptFullName)

' Path to the launcher
sLauncher = sAppDir & "\Launch App.bat"

' Desktop path
sDesktop = oShell.SpecialFolders("Desktop")
sShortcutPath = sDesktop & "\SA Privacy & Cyber Framework.lnk"

' Create shortcut
Set oShortcut = oShell.CreateShortcut(sShortcutPath)
oShortcut.TargetPath       = sLauncher
oShortcut.WorkingDirectory = sAppDir
oShortcut.Description      = "SA Privacy & Cybersecurity Framework"
oShortcut.WindowStyle      = 7   ' minimised (so the bat window flashes briefly)
oShortcut.Save

MsgBox "Desktop shortcut created!" & vbCrLf & vbCrLf & _
       "You can now launch the app from your Desktop." & vbCrLf & _
       "Look for: SA Privacy & Cyber Framework", _
       vbInformation, "Shortcut Created"
