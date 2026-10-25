Unicode true
Name "GPT Switch"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\Programs\GPT Switch"
InstallDirRegKey HKCU "Software\GPTSwitch" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
Icon "${ICON}"
UninstallIcon "${ICON}"

!include "MUI2.nsh"
!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\GPTSwitch"
!define PS_EXE "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"

Section "安装" SecInstall
  ; 覆盖安装前先停掉旧注入器和面板，否则运行中的 EXE 无法被替换。
  IfFileExists "$INSTDIR\GPT Switch.exe" stopNative stopLegacy
stopNative:
  nsExec::ExecToLog '"$INSTDIR\GPT Switch.exe" --stop'
  Pop $0
  StrCmp $0 "0" installStopOk
  MessageBox MB_ICONSTOP "无法停止正在运行的 GPT Switch，请关闭它后重新安装。"
  Abort
installStopOk:
  Goto stopDone
stopLegacy:
  IfFileExists "$INSTDIR\GPT Switch.ps1" 0 stopDone
  nsExec::ExecToLog '"${PS_EXE}" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\GPT Switch.ps1" -Stop'
  Pop $0
  StrCmp $0 "0" installStopOk
  MessageBox MB_ICONSTOP "无法停止旧版 GPT Switch，请关闭它后重新安装。"
  Abort
stopDone:

  SetOutPath "$INSTDIR"
  File /r "${PAYLOAD}\*.*"
  ; 清掉旧版遗留的运行时、控制台启动器和 PowerShell 启动器。
  Delete "$INSTDIR\node.exe"
  Delete "$INSTDIR\GPT Switch.cmd"
  Delete "$INSTDIR\GPT Switch.ps1"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ; 开始菜单直接启动原生应用。
  CreateDirectory "$SMPROGRAMS\GPT Switch"
  CreateShortCut "$SMPROGRAMS\GPT Switch\GPT Switch.lnk" "$INSTDIR\GPT Switch.exe" \
    "" "$INSTDIR\GPT Switch.exe" 0
  CreateShortCut "$SMPROGRAMS\GPT Switch\卸载 GPT Switch.lnk" "$INSTDIR\Uninstall.exe"

  WriteRegStr HKCU "Software\GPTSwitch" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "GPT Switch"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "choohubai"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\GPT Switch.exe"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  ; 先停掉正在运行的注入器和面板，再删文件；用户配置目录保留。
  nsExec::ExecToLog '"$INSTDIR\GPT Switch.exe" --stop'
  Pop $0
  StrCmp $0 "0" uninstallStopOk
  MessageBox MB_ICONSTOP "无法停止正在运行的 GPT Switch，请关闭它后重新卸载。"
  Abort
uninstallStopOk:

  Delete "$SMPROGRAMS\GPT Switch\GPT Switch.lnk"
  Delete "$SMPROGRAMS\GPT Switch\卸载 GPT Switch.lnk"
  RMDir "$SMPROGRAMS\GPT Switch"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "${UNINST_KEY}"
  DeleteRegKey HKCU "Software\GPTSwitch"
SectionEnd
