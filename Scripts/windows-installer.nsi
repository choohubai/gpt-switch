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
  SetOutPath "$INSTDIR"
  File /r "${PAYLOAD}\*.*"
  ; 清掉 0.1.30 及更早版本留下的 node.exe 和控制台启动脚本。
  Delete "$INSTDIR\node.exe"
  Delete "$INSTDIR\GPT Switch.cmd"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ; 快捷方式用隐藏窗口的 PowerShell 拉起启动器，避免出现控制台窗口。
  CreateDirectory "$SMPROGRAMS\GPT Switch"
  CreateShortCut "$SMPROGRAMS\GPT Switch\GPT Switch.lnk" "${PS_EXE}" \
    '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$INSTDIR\GPT Switch.ps1"' \
    "$INSTDIR\AppIcon.ico" 0
  CreateShortCut "$SMPROGRAMS\GPT Switch\卸载 GPT Switch.lnk" "$INSTDIR\Uninstall.exe"

  WriteRegStr HKCU "Software\GPTSwitch" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "GPT Switch"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "choohubai"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\AppIcon.ico"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
  ; 先停掉正在运行的注入器和面板，再删文件；用户配置目录保留。
  nsExec::ExecToLog '"${PS_EXE}" -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\GPT Switch.ps1" -Stop'
  Pop $0

  Delete "$SMPROGRAMS\GPT Switch\GPT Switch.lnk"
  Delete "$SMPROGRAMS\GPT Switch\卸载 GPT Switch.lnk"
  RMDir "$SMPROGRAMS\GPT Switch"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "${UNINST_KEY}"
  DeleteRegKey HKCU "Software\GPTSwitch"
SectionEnd