Set oShell  = CreateObject("WScript.Shell")
Set oFSO    = CreateObject("Scripting.FileSystemObject")

sDir      = oFSO.GetParentFolderName(WScript.ScriptFullName)
sLauncher = sDir & "\Launch Cyber Essentials SA.bat"
sDesktop  = oShell.SpecialFolders("Desktop")
sLink     = sDesktop & "\Cyber Essentials SA.lnk"

Set oSC = oShell.CreateShortcut(sLink)
oSC.TargetPath       = sLauncher
oSC.WorkingDirectory = sDir
oSC.Description      = "Cyber Essentials SA Self-Assessment"
oSC.WindowStyle      = 7
oSC.Save

MsgBox "Done! A shortcut called 'Cyber Essentials SA' has been added to your Desktop." _
     & vbCrLf & vbCrLf & "Double-click it any time to launch the app.", _
       vbInformation, "Shortcut Created"
