@echo off
rem The command that ends up on PATH, and the reason it lives in bin\ alone.
rem
rem PowerShell resolves an ExternalScript BEFORE an Application, so with
rem tazuna.ps1 and tazuna.cmd side by side in one directory, `tazuna` picks
rem the .ps1 every time - measured with Get-Command -All. On a machine whose
rem ExecutionPolicy is AllSigned that is exactly the failure the .cmd exists to
rem avoid, and it came back once the PATH entry was added. A directory holding only this file has nothing to lose to.
rem
rem A .cmd is not subject to the policy, so this starts PowerShell with the
rem policy it needs FOR THIS PROCESS ONLY. Nothing on the machine changes and no
rem elevation is involved. Bypass also ignores the Mark of the Web, which every
rem file inside a ZIP downloaded from GitHub carries.
rem
rem CRLF line endings are required. With LF, cmd.exe splits its own keywords and
rem the file fails with 'm' is not recognized - measured, not guessed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\tazuna.ps1" %*
exit /b %ERRORLEVEL%
