; Findio Windows 安装包脚本（Inno Setup 6）
;
; 构建入口：tools\Package-LpInstaller.ps1（版本号从构建产物读取，避免第二处硬编码）。
; 手工构建示例：
;   ISCC.exe /DAppVersion=1.0.1 /DAppNumericVersion=1.0.1.0 ^
;     /DSourceDir=<stage> /DOutputDir=<dist> ^
;     /DOutputBaseName=Findio-1.0.1-win-x64-setup installer\Findio.iss
;
; 安装行为：
;   - 安装范围二选一：默认「仅为我安装」（无需 UAC，写入 %LOCALAPPDATA%\Programs）；
;     可选「为所有用户安装」（写入 Program Files，需管理员权限与 UAC，开始菜单与
;     卸载项写入公共位置）。默认值取当前用户，避免未经审查的写入落到机器级目录；
;   - 数据/日志/索引始终按用户隔离（%LOCALAPPDATA%\Findio），两种模式相同：
;     索引反映当前用户可见的文件，混用会泄露他人文件列表；
;   - 当前版本没有开机自启功能，两种模式都不写 Run 项，因此不存在归属差异；
;   - 开始菜单快捷方式必装，桌面快捷方式为可选任务（默认不勾选）；
;   - 安装结束可选择立即启动 UI（runasoriginaluser，不继承提权），UI 会按既有逻辑
;     自动拉起同目录的 Service；
;   - 卸载移除程序文件、快捷方式与卸载注册项；配置/日志/索引缓存默认保留，
;     交互式卸载会询问是否一并删除；所有用户模式只询问并删除「执行卸载者」的数据，
;     其他用户的数据保留；
;   - 安装范围写入注册表（Software\Findio\InstallScope）供设置界面展示。

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef AppNumericVersion
  #define AppNumericVersion "0.0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\dist\Findio-win-x64"
#endif
#ifndef OutputDir
  #define OutputDir "..\dist"
#endif
#ifndef OutputBaseName
  #define OutputBaseName "Findio-" + AppVersion + "-win-x64-setup"
#endif

[Setup]
AppId={{847ED305-ED44-4C67-8538-940E88EDA53B}
AppName=Findio
AppVersion={#AppVersion}
AppVerName=Findio {#AppVersion}
AppPublisher=Findio
AppPublisherURL=https://github.com/yunyu697/findio
AppSupportURL=https://github.com/yunyu697/findio
AppUpdatesURL=https://github.com/yunyu697/findio/releases
; {autopf} 随安装模式解析：所有用户 -> {pf}\Findio；仅当前用户 -> {localappdata}\Programs\Findio。
DefaultDirName={autopf}\Findio
DefaultGroupName=Findio
DisableProgramGroupPage=yes
; 安装范围由向导显式选择（dialog），静默安装可用 /ALLUSERS 或 /CURRENTUSER 指定。
; 默认值 lowest = 「仅为我安装（推荐）」，理由见文件头注释。
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog commandline
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName=Findio {#AppVersion}
UninstallDisplayIcon={app}\Findio.UI.exe
; 安装包/卸载器自身也用产品图标：与 exe 内嵌的是同一份 .ico。
SetupIconFile=..\src\Findio.UI\Assets\Findio.ico
VersionInfoVersion={#AppNumericVersion}
VersionInfoProductName=Findio
VersionInfoDescription=Findio Setup
CloseApplications=yes
RestartApplications=no
SetupLogging=yes
AllowUNCPath=no

[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Messages]
; 把「会弹 UAC、装到哪里、默认值为什么」直接写在向导的安装范围选择页。
PrivilegesRequiredOverrideInstruction=选择安装范围（默认推荐「仅为我安装」）
PrivilegesRequiredOverrideText1=%1 可以为所有用户安装：写入 Program Files，需要管理员权限并弹出 UAC，开始菜单与卸载项写入公共位置。也可以仅为您安装：写入您的用户目录，不需要 UAC。默认选择「仅为我安装」，不必提权，也不会把程序写进机器级目录。
PrivilegesRequiredOverrideText2=%1 可以仅为您安装：写入您的用户目录，不需要 UAC，推荐。也可以为所有用户安装：写入 Program Files，需要管理员权限并弹出 UAC，开始菜单与卸载项写入公共位置。

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Findio"; Filename: "{app}\Findio.UI.exe"; WorkingDir: "{app}"; IconFilename: "{app}\Findio.UI.exe"; Comment: "Findio 快速定位"
Name: "{group}\卸载 Findio"; Filename: "{uninstallexe}"; IconFilename: "{app}\Findio.UI.exe"
Name: "{autodesktop}\Findio"; Filename: "{app}\Findio.UI.exe"; WorkingDir: "{app}"; IconFilename: "{app}\Findio.UI.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Findio.UI.exe"; Description: "{cm:LaunchProgram,Findio}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
function StopFindioProcesses(): Boolean;
var
  LpResultCode: Integer;
begin
  { 升级/卸载前结束旧进程，避免文件占用；未运行时 taskkill 返回非零，忽略即可。 }
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /T /IM Findio.UI.exe', '', SW_HIDE, ewWaitUntilTerminated, LpResultCode);
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /T /IM Findio.Service.exe', '', SW_HIDE, ewWaitUntilTerminated, LpResultCode);
  Result := True;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopFindioProcesses();
  Result := '';
end;

{ 把安装范围写入 64 位注册表视图，供设置界面显示「当前安装模式 / 维护者」。
  数据、日志、索引不在注册表，也不随安装范围改变：始终按用户隔离。 }
procedure WriteInstallScope();
begin
  try
    if IsAdminInstallMode then
    begin
      RegDeleteKeyIncludingSubkeys(HKCU64, 'Software\Findio');
      RegWriteStringValue(HKLM64, 'Software\Findio', 'InstallScope', 'allusers');
      RegWriteStringValue(HKLM64, 'Software\Findio', 'InstallDir', ExpandConstant('{app}'));
      RegWriteStringValue(HKLM64, 'Software\Findio', 'InstallVersion', '{#AppVersion}');
    end
    else
    begin
      try
        RegDeleteKeyIncludingSubkeys(HKLM64, 'Software\Findio');
      except
      end;
      RegWriteStringValue(HKCU64, 'Software\Findio', 'InstallScope', 'currentuser');
      RegWriteStringValue(HKCU64, 'Software\Findio', 'InstallDir', ExpandConstant('{app}'));
      RegWriteStringValue(HKCU64, 'Software\Findio', 'InstallVersion', '{#AppVersion}');
    end;
  except
  end;
end;

procedure RemoveInstallScope();
begin
  try
    if IsAdminInstallMode then
      RegDeleteKeyIncludingSubkeys(HKLM64, 'Software\Findio')
    else
      RegDeleteKeyIncludingSubkeys(HKCU64, 'Software\Findio');
  except
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    WriteInstallScope();
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  LpDeleteData: Boolean;
  LpDataRoot: String;
  LpDataNote: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    StopFindioProcesses();
    LpDataRoot := ExpandConstant('{localappdata}\Findio');
    if IsAdminInstallMode then
      LpDataNote := '当前为「所有用户」安装模式，但数据按用户隔离：这里只会删除执行卸载的这位用户的数据，' +
        '其他用户的数据保留。'
    else
      LpDataNote := '当前为「仅当前用户」安装模式，这里只会删除这位用户的数据。';
    LpDeleteData := False;
    if not UninstallSilent then
    begin
      LpDeleteData := MsgBox('是否同时删除当前用户的配置、日志与索引缓存？' + #13#10 +
        '选择“否”将保留这些数据，重新安装后可以继续使用。' + #13#10#13#10 +
        LpDataNote + #13#10#13#10 +
        '位置：' + LpDataRoot, mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
    end;

    { 安装目录可能与数据根同名，此时交给卸载器自己清理程序文件。 }
    if LpDeleteData and (CompareText(ExpandConstant('{app}'), LpDataRoot) <> 0) then
    begin
      DelTree(LpDataRoot, True, True, True);
    end;

    RemoveInstallScope();
  end;
end;
