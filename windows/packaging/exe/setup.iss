[Setup]
AppId={{DA3F45DE-00B2-4EFC-81B0-BA101DCA73E8}
AppName=SkyStream
AppVersion={#AppVersion}
; Inno 6's default text; Inno 7's drops "version" from the Add/Remove Programs name.
AppVerName=SkyStream version {#AppVersion}
AppPublisher=SkyStream
AppPublisherURL=https://github.com/skystream
AppSupportURL=https://github.com/skystream
AppUpdatesURL=https://github.com/skystream
DefaultDirName={autopf}\SkyStream
DefaultGroupName=SkyStream
DisableProgramGroupPage=yes
OutputBaseFilename=SkyStream-Windows-{#AppArch}-Setup-{#AppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\..\runner\resources\app_icon.ico
; Installed files keep their real time; local times from a CI build in UTC put them hours ahead west of UTC.
TimeStampsInUTC=yes
#if AppArch == "x64"
  ArchitecturesAllowed=x64compatible
  ArchitecturesInstallIn64BitMode=x64compatible
#else
  ArchitecturesAllowed={#AppArch}
  ArchitecturesInstallIn64BitMode={#AppArch}
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#AppDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\SkyStream"; Filename: "{app}\skystream.exe"
Name: "{autodesktop}\SkyStream"; Filename: "{app}\skystream.exe"; Tasks: desktopicon

[Run]
; libVLC's plugin cache, made on the installed files: Inno rounds timestamps to
; two seconds, and libVLC trusts an entry only if the DLL's time and size match
; exactly. Without it the first player after launch loads all 360 plugins
; (spec 1.7).
Filename: "{app}\vlc-cache-gen.exe"; Parameters: """{app}\plugins"""; Flags: runhidden waituntilterminated
Filename: "{app}\skystream.exe"; Description: "{cm:LaunchProgram,SkyStream}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{app}\plugins\plugins.dat"
