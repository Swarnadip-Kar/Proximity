; Proximity Windows installer — Inno Setup 6 script.
;
; Build on Windows (or the windows job of release.yml):
;   flutter build windows --release
;   iscc /DAppVersion=0.1.0 packaging\windows\proximity.iss
;
; Output: dist\Proximity-Setup-<version>-Windows-x64.exe
; The installer is currently UNsigned (no code-signing cert yet): Windows
; SmartScreen shows the "Unknown publisher" prompt on first install. Signing
; later needs only signtool + the Inno `SignTool` directive — no script
; restructure.
#define AppVersion GetEnv("APP_VERSION") == "" ? "0.1.0" : GetEnv("APP_VERSION")

[Setup]
AppId={{2D51583A-D29F-445F-AA6A-0F9C5A9EE6C6}}
AppName=Proximity
AppVersion={#AppVersion}
AppVerName=Proximity {#AppVersion}
AppPublisher=IIT Bhilai
DefaultDirName={autopf}\Proximity
DefaultGroupName=Proximity
OutputDir=..\..\dist
OutputBaseFilename=Proximity-Setup-{#AppVersion}-Windows-x64
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
PrivilegesRequired=lowest
WizardStyle=modern
UninstallDisplayName=Proximity
VersionInfoVersion={#AppVersion}.0

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Proximity"; Filename: "{app}\proximity_app.exe"
Name: "{autodesktop}\Proximity"; Filename: "{app}\proximity_app.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\proximity_app.exe"; Description: "{cm:LaunchProgram,Proximity}"; Flags: nowait postinstall skipifsilent
