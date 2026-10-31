; Inno Setup script for the Sanitaryware ERP installer (setup.exe).
; Build it with build_release.bat, which runs the tests, builds the release
; and passes the version from lib/core/version.dart.
;
; The client's data is NOT in the install folder: it lives in
;   %APPDATA%\com.erp\sanitaryware_erp\SanitarywareERP
; (database, backups, logo), so installing an update or uninstalling never
; touches it. Before opening a database from an older version the app makes
; a backup by itself.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

#define AppNameAr "إدارة الأدوات الصحية"
#define AppExe "sanitaryware_erp.exe"

[Setup]
; Never change AppId: it is how Windows recognises an update of the same app.
AppId={{FAD10A96-D7C0-4749-A730-4A75378B2990}
AppName={#AppNameAr}
AppVersion={#AppVersion}
AppVerName={#AppNameAr} {#AppVersion}
AppPublisher=Mohamed Hussien
DefaultDirName={autopf}\SanitarywareERP
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=SanitarywareERP-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppNameAr}
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
PrivilegesRequired=admin
; An update closes the running app first (it backs up on close).
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; The whole release folder, including the Visual C++ runtime DLLs that
; build_release.bat copies next to the exe for clean Windows installs.
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppNameAr}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppNameAr}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppNameAr}}"; Flags: nowait postinstall skipifsilent
