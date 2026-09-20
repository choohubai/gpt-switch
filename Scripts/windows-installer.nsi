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

Section "安装" SecInstall
  SetOutPath "$INSTDIR"
  File /r "${PAYLOAD}\*.*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  CreateDirectory "$SMPROGRAMS\GPT Switch"
  CreateShortCut "$SMPROGRAMS\GPT Switch\GPT Switch.lnk" "$INSTDIR\GPT Switch.cmd"
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
  Delete "$SMPROGRAMS\GPT Switch\GPT Switch.lnk"
  Delete "$SMPROGRAMS\GPT Switch\卸载 GPT Switch.lnk"
  RMDir "$SMPROGRAMS\GPT Switch"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "${UNINST_KEY}"
  DeleteRegKey HKCU "Software\GPTSwitch"
SectionEnd

