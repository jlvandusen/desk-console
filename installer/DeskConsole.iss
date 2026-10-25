; DeskConsoleSetup.exe -- one installer for every PC (the keyboard/mouse server and its clients).
; Build:  tools\Get-Redist.ps1            (downloads + hash-checks the bundled third-party installers)
;         "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\DeskConsole.iss
;         -> dist\DeskConsoleSetup-<version>.exe
;
; Installs Desk Console for the current user (no admin), then runs Setup-Synergy.ps1:
;   User   phase (as you):  share login -> Credential Manager, optional drive mapping, kvm.json provider/server
;   Admin  phase (one UAC): Deskflow or Synergy (the other switched off), RustDesk + password,
;                           firewall, automatic sign-in, machines.csv
;   Finish phase (as you):  Deskflow settings + server layout, the 2-minute trust sync / agent task, dev box
; Each phase appends "<Phase>|OK|", "<Phase>|WARN|<text>" or "<Phase>|FAIL|<text>" to
; {tmp}\ds-result.txt (-ResultFile). [Run] ignores exit codes and the consoles that showed a
; problem have closed by the end, so the Finished page lists those lines (contract C-1).
; A PC that is already set up (RustDesk installed, and this PC in kvm.json or machines.csv) first
; gets "Update and keep this PC's settings": that skips every other custom page and passes no
; -Kvm / -Role / -AutoLogon / -DevBoxFolder, so only the files change and the admin step re-applies
; (repairs) what it manages.
; Passwords go from the wizard to the script through {tmp}\ds-secrets.txt (deleted after),
; never on a command line. RustDesk, Deskflow and the Visual C++ runtime are bundled; Synergy
; (commercial) is never bundled -- it is installed from the shared folder's installer\ only if chosen.
; Shared state lives in the shared folder: kvm.json, machines.csv, fingerprints\, logs\.
; site.json: copied from the folder setup runs from when present, else written from the
; "Shared folder" page.

#define VerFile FileOpen(SourcePath + "..\src\version.txt")
#define AppVer Trim(FileRead(VerFile))
#expr FileClose(VerFile)
#undef VerFile

[Setup]
AppId=DeskConsole
AppName=Desk Console
AppVersion={#AppVer}
AppVerName=Desk Console {#AppVer}
; the exe's numeric file version (it was 0.0.0.0) -- from the same src\version.txt
VersionInfoVersion={#AppVer}
AppPublisher=James VanDusen
AppPublisherURL=https://github.com/jlvandusen/desk-console
AppComments=Keyboard + mouse sharing (Deskflow or Synergy) and RustDesk for every PC
DefaultDirName={localappdata}\Programs\DeskConsole
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=DeskConsoleSetup-{#AppVer}
SetupIconFile=..\src\desk-console.ico
UninstallDisplayIcon={app}\desk-console.ico
UninstallDisplayName=Desk Console
; No licence page: MIT asks for no acceptance, and the page came after three passwords had been
; typed (the custom pages follow wpWelcome). LICENSE.txt is installed instead. Default wizard size
; (WizardSizePercent=115 made it smaller than Inno's 120).
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
SetupLogging=yes
; one setup at a time: two would race through the same admin step and kvm.json
SetupMutex=DeskConsoleSetup,Global\DeskConsoleSetup
; let Windows Restart Manager name and close whatever holds our files (scripts included)
CloseApplications=yes
CloseApplicationsFilter=*.exe,*.dll,*.ps1,*.ico,*.txt
RestartApplications=no

[Tasks]
Name: desktopicon; Description: "Desktop shortcut"
Name: autostart;   Description: "Start Desk Console in the notification area when I sign in"; Flags: unchecked
Name: autolock;    Description: "After an automatic sign-in, lock the screen straight away (recommended)"; Check: AutoLogonOn
Name: noautorestart; Description: "Windows Update: don't restart this PC by itself while someone is signed in (Pro / Enterprise)"

[Files]
; The app files, in the order src\Install-DeskConsole.ps1 copies them (version.txt last). This list,
; AppFile() / AppFileCount in [Code] below and $Files in src\Install-DeskConsole.ps1 must name the
; same files (contract C-8) -- change all three together. A file missing from AppFile() is not set
; aside before copying, which is the "file locked mid-install" incident again.
Source: "..\src\Desk-Console.ps1";            DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\Setup-Synergy.ps1";           DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\Agent.ps1";                   DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\Install-DeskConsole.ps1";     DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\Start-DevBox.ps1";            DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\Set-NoAutoRestart.cmd";       DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\Remove-Synergy.cmd";          DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\desk-console.ico";            DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\mobile\rustdesk-android.png"; DestDir: "{app}\mobile"; Flags: ignoreversion
Source: "..\src\mobile\rustdesk-ios.png";     DestDir: "{app}\mobile"; Flags: ignoreversion
Source: "..\src\whats-new.txt";               DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\version.txt";                 DestDir: "{app}"; Flags: ignoreversion
; installer-only files (not in the shared folder, so self-update does not copy them)
Source: "..\THIRD-PARTY-NOTICES.md";          DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE";                         DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
; QR codes for the installer's phone page (3 px per module; extracted to {tmp} only)
Source: "mobile\rustdesk-android.bmp"; Flags: dontcopy
Source: "mobile\rustdesk-ios.bmp";     Flags: dontcopy
; the shared folder's own site.json, when setup is run from it
Source: "{src}\site.json"; DestDir: "{app}"; Flags: external skipifsourcedoesntexist ignoreversion
Source: "redist\rustdesk-1.5.0-x86_64.msi";   DestDir: "{tmp}"; Flags: deleteafterinstall
Source: "redist\deskflow-1.27.0-win-x64.msi"; DestDir: "{tmp}"; Flags: deleteafterinstall
; Deskflow needs the Microsoft Visual C++ runtime 14.44+ (installed only when missing/older)
Source: "redist\vc_redist.x64.exe";           DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{userprograms}\Desk Console"; Filename: "{sys}\conhost.exe"; \
  Parameters: "--headless {sys}\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Desk-Console.ps1"""; \
  WorkingDir: "{app}"; IconFilename: "{app}\desk-console.ico"; Comment: "Keyboard + mouse sharing and RustDesk for every PC"
Name: "{userdesktop}\Desk Console"; Filename: "{sys}\conhost.exe"; \
  Parameters: "--headless {sys}\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Desk-Console.ps1"""; \
  WorkingDir: "{app}"; IconFilename: "{app}\desk-console.ico"; Tasks: desktopicon
; at sign-in it starts in the notification area, not as a window (contract C-9: -Tray)
Name: "{userstartup}\Desk Console"; Filename: "{sys}\conhost.exe"; \
  Parameters: "--headless {sys}\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Desk-Console.ps1"" -Tray"; \
  WorkingDir: "{app}"; IconFilename: "{app}\desk-console.ico"; Tasks: autostart

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Setup-Synergy.ps1"" -Phase User -FromInstaller -SecretsFile ""{tmp}\ds-secrets.txt"" -ResultFile ""{tmp}\ds-result.txt"" {code:KvmArgs}"; \
  StatusMsg: "Saving the share login..."; Flags: runhidden waituntilterminated; BeforeInstall: WriteSecrets
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Setup-Synergy.ps1"" -Phase Admin -FromInstaller -SecretsFile ""{tmp}\ds-secrets.txt"" -InstallerDir ""{tmp}"" -ResultFile ""{tmp}\ds-result.txt"" {code:AutoLogonArgs} {code:UpdatesArgs}"; \
  StatusMsg: "Installing keyboard/mouse sharing and RustDesk (approve the Windows prompt)..."; \
  Flags: shellexec waituntilterminated; Verb: runas
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Setup-Synergy.ps1"" -Phase Finish -FromInstaller -ResultFile ""{tmp}\ds-result.txt"" {code:DevBoxArgs}"; \
  StatusMsg: "Configuring Deskflow and the background tasks..."; Flags: runhidden waituntilterminated; AfterInstall: DeleteSecrets
Filename: "{sys}\conhost.exe"; \
  Parameters: "--headless {sys}\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Desk-Console.ps1"""; \
  Description: "Open Desk Console"; Flags: postinstall nowait skipifsilent

[UninstallRun]
; The per-user tasks (created as the user, so no admin is needed to remove them). Left behind, they
; start a PowerShell against a deleted script -- the dev box one at every sign-in, the trust-sync
; one every 2 minutes. The "lock after auto sign-in" task stays on purpose: it needs no installed
; file, and removing it would leave a PC that still signs in by itself unlocked.
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""DeskConsole Deskflow trust sync"" /F"; \
  Flags: runhidden; RunOnceId: "DeleteTrustSyncTask"
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""DeskConsole dev box resume"" /F"; \
  Flags: runhidden; RunOnceId: "DeleteDevBoxTask"
; the RustDesk window watcher (on unless kvm.json showRustDeskWindow lists the PC) runs until sign-out: end it, then delete it
Filename: "{sys}\schtasks.exe"; Parameters: "/End /TN ""DeskConsole RustDesk window watcher"""; \
  Flags: runhidden; RunOnceId: "EndCmWatchTask"
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""DeskConsole RustDesk window watcher"" /F"; \
  Flags: runhidden; RunOnceId: "DeleteCmWatchTask"

[UninstallDelete]
; what Desk Console itself writes into its folder, so the folder goes too: the share caches and
; update.log (Desk-Console.ps1), agent.json/.log (Agent.ps1), devbox.json/.log (Start-DevBox.ps1)
Type: files; Name: "{app}\machines.csv"
Type: files; Name: "{app}\kvm.json"
Type: files; Name: "{app}\site.json"
Type: files; Name: "{app}\update.log"
Type: files; Name: "{app}\agent.json"
Type: files; Name: "{app}\agent.log"
Type: files; Name: "{app}\devbox.json"
Type: files; Name: "{app}\devbox.log"
Type: files; Name: "{app}\agent.log.old"
; an interrupted atomic write (agent.json.tmp, devbox.json.tmp) would keep the folder
Type: files; Name: "{app}\*.tmp"
Type: dirifempty; Name: "{app}\mobile"
Type: dirifempty; Name: "{app}"

[Messages]
FinishedLabel=Desk Console is installed.%n%nRun this installer on every PC (the keyboard/mouse server first). Setup logs are in the shared folder's logs folder.

[Code]
const
  // how many files AppFile() names: the app files of [Files] above (contract C-8)
  AppFileCount = 12;
  DRIVE_REMOTE = 4;
  LOGON32_LOGON_INTERACTIVE = 2;
  LOGON32_PROVIDER_DEFAULT = 0;
  ERROR_LOGON_FAILURE = 1326;
  WinlogonKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon';
  // what the wizard knows about kvm.json in the shared folder (R6)
  KvmUnknown = 0;   // the shared folder cannot be read yet (no saved login, offline)
  KvmFresh = 1;     // readable, and there is no kvm.json yet
  KvmKnown = 2;     // read: DefProvider and DefServer are what the other PCs use

var
  KeepPage, KvmPage, RolePage, AlPage, DevPage: TInputOptionWizardPage;
  SitePage, NasPage, RdPage, AlCredPage: TInputQueryWizardPage;
  DevDirPage: TInputDirWizardPage;
  PhonePage: TWizardPage;
  DefProvider, DefServer, ShareFromSite, UserFromSite, InitialShare: String;
  AutoLogonNow, AutoLogonNowText, DevBoxNow: String;
  KvmState, DeskConsoleClosed: Integer;
  ShareOk, ExistingSetup: Boolean;
  ResUserOk, ResAdminOk, ResFinishOk: Boolean;
  ResFails, ResWarns: TArrayOfString;

function LogonUser(lpszUsername, lpszDomain, lpszPassword: String; dwLogonType, dwLogonProvider: Cardinal;
  var phToken: THandle): Bool;
  external 'LogonUserW@advapi32.dll stdcall setuponly';
function CloseHandle(hObject: THandle): Bool;
  external 'CloseHandle@kernel32.dll stdcall setuponly';
function GetDriveType(lpRootPathName: String): Cardinal;
  external 'GetDriveTypeW@kernel32.dll stdcall setuponly';

function InstalledDir: String;
begin
  Result := ExpandConstant('{localappdata}\Programs\DeskConsole');
end;

// a small text file as one string (UTF-8 with or without a BOM, or ANSI)
function LoadText(const FileName: String; var S: String): Boolean;
var L: TArrayOfString; I: Integer;
begin
  S := '';
  Result := LoadStringsFromFile(FileName, L);
  if Result then
    for I := 0 to GetArrayLength(L) - 1 do S := S + L[I] + #10;
end;

// value of "key": "value" in a small JSON file; '' when absent or not a string
// (JSON \\ and the \u0027 / \u0026 that PowerShell 5.1's ConvertTo-Json writes are unescaped)
function JsonStr(const S, Key: String): String;
var p, q: Integer; T: String;
begin
  Result := '';
  p := Pos('"' + Key + '"', S); if p = 0 then exit;
  T := Copy(S, p + Length(Key) + 2, Length(S));
  p := Pos(':', T); if p = 0 then exit;
  T := TrimLeft(Copy(T, p + 1, Length(T)));
  if (T = '') or (T[1] <> '"') then exit;
  T := Copy(T, 2, Length(T));
  q := Pos('"', T); if q = 0 then exit;
  Result := Copy(T, 1, q - 1);
  StringChangeEx(Result, '\u0027', '''', True);
  StringChangeEx(Result, '\u0026', '&', True);
  StringChangeEx(Result, '\\', '\', True);
end;

// "key": true in a small JSON file
function JsonBool(const S, Key: String): Boolean;
var p: Integer; T: String;
begin
  Result := False;
  p := Pos('"' + Key + '"', S); if p = 0 then exit;
  T := Copy(S, p + Length(Key) + 2, Length(S));
  p := Pos(':', T); if p = 0 then exit;
  Result := Lowercase(Copy(TrimLeft(Copy(T, p + 1, Length(T))), 1, 4)) = 'true';
end;

function CountOf(const Sub, S: String): Integer;
var P: Integer; T: String;
begin
  Result := 0;
  T := S;
  P := Pos(Sub, T);
  while P > 0 do begin
    Result := Result + 1;
    T := Copy(T, P + Length(Sub), Length(T));
    P := Pos(Sub, T);
  end;
end;

function NormDir(const S: String): String;
begin
  Result := Trim(S);
  while (Length(Result) > 3) and (Result[Length(Result)] = '\') do Result := Copy(Result, 1, Length(Result) - 1);
end;

// U9b: a folder the other PCs can reach -- \\server\share\... or a mapped network drive
function IsNetworkPath(const P: String): Boolean;
begin
  Result := Copy(P, 1, 2) = '\\';
  if not Result and (Length(P) >= 2) and (P[2] = ':') then
    Result := GetDriveType(Copy(P, 1, 2) + '\') = DRIVE_REMOTE;
end;

function IsThisPc(const Name: String): Boolean;
begin
  Result := (Name <> '') and (CompareText(Name, GetComputerNameString) = 0);
end;

function ProviderName(I: Integer): String;
begin
  case I of
    1: Result := 'Synergy';
    2: Result := 'None';
  else Result := 'Deskflow';
  end;
end;

function ProviderIndex(const P: String): Integer;
begin
  if CompareText(P, 'Synergy') = 0 then Result := 1
  else if CompareText(P, 'None') = 0 then Result := 2
  else Result := 0;
end;

function SrcHasSite: Boolean;
begin
  Result := FileExists(ExpandConstant('{src}\site.json'));
end;

// the shared folder: the site.json beside setup, else the Shared folder page, else what the
// wizard started with (InitialShare)
function ShareDir: String;
begin
  if ShareFromSite <> '' then Result := ShareFromSite
  else if SitePage <> nil then Result := SitePage.Values[0]
  else Result := InitialShare;
  Result := NormDir(Result);
end;

procedure ReadDefaults;
var S, Src, Installed: String;
begin
  ShareFromSite := ''; UserFromSite := ''; InitialShare := ''; Installed := '';
  Src := NormDir(ExpandConstant('{src}'));
  if LoadText(Src + '\site.json', S) then begin
    ShareFromSite := NormDir(JsonStr(S, 'shareRoot'));
    if ShareFromSite = '' then ShareFromSite := Src;
    UserFromSite := JsonStr(S, 'credentialUser');
  end;
  // U10: re-run from a download, the installed copy already knows the shared folder
  if LoadText(InstalledDir + '\site.json', S) then begin
    Installed := NormDir(JsonStr(S, 'shareRoot'));
    if UserFromSite = '' then UserFromSite := JsonStr(S, 'credentialUser');
  end;
  // U9b: pre-fill {src} only when it is a network folder -- run from Downloads it used to be
  // accepted as the "shared folder" that no other PC can reach
  if IsNetworkPath(Src) and (FileExists(Src + '\kvm.json') or FileExists(Src + '\machines.csv')) then InitialShare := Src
  else if Installed <> '' then InitialShare := Installed
  else if IsNetworkPath(Src) then InitialShare := Src;
end;

// kvm.json in the shared folder: provider, server, and whether the wizard really knows them (R6)
procedure ReadKvm;
var D, S: String;
begin
  KvmState := KvmUnknown; DefProvider := 'Deskflow'; DefServer := '';
  D := ShareDir;
  ShareOk := (D <> '') and DirExists(D);
  if not ShareOk then exit;
  if LoadText(D + '\kvm.json', S) then begin
    KvmState := KvmKnown;
    if JsonStr(S, 'provider') <> '' then DefProvider := ProviderName(ProviderIndex(JsonStr(S, 'provider')));
    DefServer := JsonStr(S, 'server');
  end else if not FileExists(D + '\kvm.json') then KvmState := KvmFresh;
end;

// the first field of a machines.csv row is the PC name
function NameInCsv(const Path, Name: String): Boolean;
var L: TArrayOfString; I, P: Integer; F: String;
begin
  Result := False;
  if not LoadStringsFromFile(Path, L) then exit;
  for I := 0 to GetArrayLength(L) - 1 do begin
    F := L[I];
    P := Pos(',', F);
    if P > 0 then F := Copy(F, 1, P - 1);
    StringChangeEx(F, '"', '', True);
    if CompareText(Trim(F), Name) = 0 then begin
      Result := True;
      exit;
    end;
  end;
end;

// U10: set up before = RustDesk is installed and this PC is in kvm.json or machines.csv
function DetectExistingSetup: Boolean;
var S: String;
begin
  Result := False;
  if (not FileExists(ExpandConstant('{commonpf64}\RustDesk\rustdesk.exe'))) or (not ShareOk) then exit;
  if (KvmState = KvmKnown) and LoadText(ShareDir + '\kvm.json', S) and
     (Pos('"' + Uppercase(GetComputerNameString) + '"', Uppercase(S)) > 0) then Result := True
  else Result := NameInCsv(ShareDir + '\machines.csv', GetComputerNameString);
end;

// automatic sign-in as Windows has it now: 'DOMAIN\name', or '' when it is off
function ReadAutoLogon: String;
var V, U, D: String;
begin
  Result := ''; V := ''; U := ''; D := '';
  if (not RegQueryStringValue(HKLM64, WinlogonKey, 'AutoAdminLogon', V)) or (Trim(V) <> '1') then exit;
  RegQueryStringValue(HKLM64, WinlogonKey, 'DefaultUserName', U);
  RegQueryStringValue(HKLM64, WinlogonKey, 'DefaultDomainName', D);
  if (D <> '') and (Pos('\', U) = 0) then Result := D + '\' + U else Result := U;
  if Result = '' then Result := '(no account named)';
end;

// shown on the Update and Automatic sign-in pages; AutoLogonUser is what setup turned it on for
// (another account's console sign-in rewrites Winlogon's name, R13)
function AutoLogonText: String;
var Want: String;
begin
  if AutoLogonNow = '' then begin
    Result := 'off';
    exit;
  end;
  Result := 'ON for ' + AutoLogonNow;
  Want := '';
  if RegQueryStringValue(HKLM64, 'SOFTWARE\DeskConsole', 'AutoLogonUser', Want) and (Want <> '') and
     (CompareText(Want, AutoLogonNow) <> 0) then
    Result := Result + ' (setup turned it on for ' + Want + ')';
end;

function KvmNowText: String;
begin
  if KvmState <> KvmKnown then Result := 'no kvm.json in the shared folder'
  else if DefProvider = 'None' then Result := 'off on every PC (None)'
  else if IsThisPc(DefServer) then Result := DefProvider + ', this PC is the server'
  else if DefServer <> '' then Result := DefProvider + ', a client of ' + DefServer
  else Result := DefProvider + ', no server set';
end;

function CurrentSettingsText: String;
begin
  Result := 'This PC already runs Desk Console:' + #13#10 +
    '      Shared folder:  ' + ShareDir + #13#10 +
    '      Keyboard and mouse:  ' + KvmNowText + #13#10 +
    '      Automatic sign-in:  ' + AutoLogonNowText + #13#10 +
    '      Dev box:  ' + DevBoxNow + #13#10#13#10 +
    'Updating keeps all of this. One Windows prompt (UAC) follows: it updates RustDesk and ' +
    'keyboard/mouse sharing and re-applies the firewall and sign-in settings.';
end;

function KeepMode: Boolean;
begin
  Result := ExistingSetup and (KeepPage <> nil) and (KeepPage.SelectedValueIndex = 0);
end;

function AutoLogonOn: Boolean;
begin
  Result := (AlPage <> nil) and not KeepMode and ((AlPage.SelectedValueIndex = 1) or (AlPage.SelectedValueIndex = 2));
end;

function DevBoxOn: Boolean;
begin
  Result := (DevPage <> nil) and (DevPage.Values[0] or DevPage.Values[1]);
end;

function KvmText: String;
begin
  Result := 'Saved in kvm.json in the shared folder, so it applies to EVERY PC the next time its setup runs. ' +
    'The program not chosen is switched off on this PC, not uninstalled.';
  case KvmState of
    KvmKnown: Result := Result + ' Right now every PC uses ' + DefProvider + '.';
    KvmFresh: Result := Result + ' There is no kvm.json yet: this choice starts it.';
  else
    Result := Result + ' The shared folder cannot be read yet, so this PC cannot see what the others use: ' +
      'a choice here is used only if kvm.json names no program yet.';
  end;
end;

function RoleText: String;
begin
  Result := 'One PC is the server; every other PC is a client. ';
  case KvmState of
    KvmKnown:
      if DefServer = '' then Result := Result + 'No server is set yet.'
      else if IsThisPc(DefServer) then Result := Result + 'This PC is the server right now.'
      else Result := Result + 'The server right now is ' + DefServer + '.';
    KvmFresh: Result := Result + 'No server is set yet.';
  else
    Result := Result + 'The current server is unknown (the shared folder cannot be read yet): Server ' +
      'takes effect only if no other PC is the server yet.';
  end;
end;

function NasText: String;
begin
  Result := 'Saved in Windows Credential Manager so this PC reaches the shared folder at every sign-in. ';
  if ShareOk then
    Result := Result + 'This PC can open ' + ShareDir + ' right now: leave the password blank to keep the login it uses.'
  else
    Result := Result + 'This PC cannot open ' + ShareDir + ' right now, so enter the login.';
end;

// change a page's explanation after Inno laid it out, moving what is below it
procedure SetOptionText(Page: TInputOptionWizardPage; const S: String);
begin
  Page.SubCaptionLabel.Caption := S;
  WizardForm.IncTopDecHeight(Page.CheckListBox, WizardForm.AdjustLabelHeight(Page.SubCaptionLabel));
end;

procedure SetQueryText(Page: TInputQueryWizardPage; Count: Integer; const S: String);
var I, D: Integer;
begin
  Page.SubCaptionLabel.Caption := S;
  D := WizardForm.AdjustLabelHeight(Page.SubCaptionLabel);
  for I := 0 to Count - 1 do begin
    Page.PromptLabels[I].Top := Page.PromptLabels[I].Top + D;
    Page.Edits[I].Top := Page.Edits[I].Top + D;
  end;
end;

// R6: preselect only what is known. When kvm.json could not be read, nothing is preselected:
// a preselected Server (1.6.0) silently made a new client the server of every PC.
procedure ApplyKvmDefaults;
begin
  KvmPage.SelectedValueIndex := ProviderIndex(DefProvider);
  case KvmState of
    KvmKnown:
      if (DefServer = '') or IsThisPc(DefServer) then RolePage.SelectedValueIndex := 0
      else RolePage.SelectedValueIndex := 1;
    KvmFresh: RolePage.SelectedValueIndex := 0;
  else begin   // unknown: no preselection (SelectedValueIndex := -1 does not clear one already made)
    RolePage.CheckListBox.Checked[0] := False;
    RolePage.CheckListBox.Checked[1] := False;
  end;
  end;
end;

// ---- phone / tablet page: QR codes that open the RustDesk app download (RustDesk is NOT on
// Google Play since 2023 -- Android installs come from its GitHub APK or F-Droid)
function MobileUrl(I: Integer): String;
begin
  case I of
    0: Result := 'https://github.com/rustdesk/rustdesk/releases/download/1.5.0/rustdesk-1.5.0-aarch64-signed.apk';
    1: Result := 'https://f-droid.org/packages/com.carriez.flutter_hbb/';
    2: Result := 'https://apps.apple.com/app/rustdesk-remote-desktop/id1581225015';
  else Result := '';
  end;
end;

procedure MobileLinkClick(Sender: TObject);
var RC: Integer;
begin
  ShellExec('open', MobileUrl(TComponent(Sender).Tag), '', '', SW_SHOWNORMAL, ewNoWait, RC);
end;

function AddText(Page: TWizardPage; const S: String; X, Y: Integer; Bold: Boolean; Link: Integer): TNewStaticText;
begin
  Result := TNewStaticText.Create(Page);
  Result.Parent := Page.Surface;
  Result.Caption := S;
  Result.Left := X;
  Result.Top := Y;
  if Bold then Result.Font.Style := [fsBold];
  if Link >= 0 then begin
    Result.Font.Color := clBlue;
    Result.Font.Style := [fsUnderline];
    Result.Cursor := crHand;
    Result.Tag := Link;
    Result.OnClick := @MobileLinkClick;
  end;
end;

// QR bitmaps are shown at their exact pixel size: a scaled QR code scans badly
function AddQr(Page: TWizardPage; const Bmp: String; X, Y: Integer): TBitmapImage;
begin
  ExtractTemporaryFile(Bmp);
  Result := TBitmapImage.Create(Page);
  Result.Parent := Page.Surface;
  Result.AutoSize := True;
  Result.Bitmap.LoadFromFile(ExpandConstant('{tmp}\') + Bmp);
  Result.Left := X;
  Result.Top := Y;
end;

function ReadVersion(const FileName: String): String;
var L: TArrayOfString;
begin
  Result := '';
  if LoadStringsFromFile(FileName, L) and (GetArrayLength(L) > 0) then Result := Trim(L[0]);
end;

function PackVer(S: String; var V: Int64): Boolean;
var I, Dots: Integer;
begin
  S := Trim(S);
  Dots := 0;
  for I := 1 to Length(S) do
    if S[I] = '.' then Dots := Dots + 1;
  while Dots < 3 do begin
    S := S + '.0';
    Dots := Dots + 1;
  end;
  Result := StrToVersion(S, V);
end;

// E2: never put an older Desk Console over a newer one without asking. "Repair / update this PC"
// starts the newest setup in the shared folder, which can be older than a copy from a download.
function InitializeSetup: Boolean;
var Have: String; A, B: Int64;
begin
  Result := True;
  Have := ReadVersion(InstalledDir + '\version.txt');
  if (Have <> '') and PackVer(Have, A) and PackVer('{#AppVer}', B) and (ComparePackedVersion(A, B) > 0) then
    Result := SuppressibleMsgBox('Desk Console ' + Have + ' is installed on this PC; this setup is the older {#AppVer}.' + #13#10#13#10 +
      'Install {#AppVer} over it anyway?', mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDYES;
end;

procedure InitializeWizard;
var S, DevFolder, DevText, RdText: String; Q: TBitmapImage; T: TNewStaticText; Y1, Y2, DevMore: Integer;
    DevCode, DevClaude: Boolean;
begin
  ReadDefaults;
  ReadKvm;
  ExistingSetup := DetectExistingSetup;
  AutoLogonNow := ReadAutoLogon;
  AutoLogonNowText := AutoLogonText;
  // devbox.json (Start-DevBox.ps1): folder/openCode/resumeClaude are the 1.6.0 shape and, in the
  // 1.7.0 one, its first "items" entry again. This page shows that first folder; Start-DevBox
  // -Configure -Folder changes only it, so further folders (Desk Console > Dev box) stay.
  DevFolder := ''; DevCode := False; DevClaude := False; DevMore := 0;
  if LoadText(InstalledDir + '\devbox.json', S) then begin
    DevFolder := JsonStr(S, 'folder');
    DevCode := JsonBool(S, 'openCode');
    DevClaude := JsonBool(S, 'resumeClaude');
    DevMore := CountOf('"path"', S) - 1;
    if DevMore < 0 then DevMore := 0;
  end;
  if (DevFolder <> '') and (DevCode or DevClaude) then begin
    if DevCode and DevClaude then DevBoxNow := 'VS Code + claude --continue'
    else if DevCode then DevBoxNow := 'VS Code'
    else DevBoxNow := 'claude --continue';
    DevBoxNow := DevBoxNow + ' in ' + DevFolder;
    if DevMore > 0 then DevBoxNow := DevBoxNow + ' and ' + IntToStr(DevMore) + ' more folder(s)';
  end
  else if CountOf('"path"', S) > 0 then DevBoxNow := 'set in Desk Console > Dev box'
  else DevBoxNow := 'off';

  // U10: a re-run on a PC that is set up -- usually only the files need updating
  KeepPage := CreateInputOptionPage(wpWelcome, 'Update Desk Console',
    'This PC is already set up. Keep its settings?', CurrentSettingsText, True, False);
  KeepPage.Add('Update and keep this PC''s settings  (recommended)');
  KeepPage.Add('Change settings  (shared folder, keyboard/mouse, passwords, automatic sign-in, dev box)');
  KeepPage.SelectedValueIndex := 0;

  SitePage := CreateInputQueryPage(KeepPage.ID, 'Shared folder',
    'Where do your PCs keep their shared settings?',
    'A network folder every PC can reach, for example \\server\share\DeskConsole. It holds the ' +
    'PC list, the keyboard/mouse layout, Deskflow fingerprints and setup logs. Use the same folder on every PC.');
  SitePage.Add('Shared folder:', False);
  SitePage.Values[0] := InitialShare;

  KvmPage := CreateInputOptionPage(SitePage.ID, 'Keyboard and mouse sharing',
    'Which program shares one keyboard and mouse across your PCs?', KvmText, True, False);
  KvmPage.Add('Deskflow  -  free, open source (the project Synergy 3 is built on)');
  KvmPage.Add('Synergy 3  -  paid licence; its installer must be in the shared folder''s installer\ folder');
  KvmPage.Add('None  -  no keyboard/mouse sharing');

  RolePage := CreateInputOptionPage(KvmPage.ID, 'This PC''s role',
    'Are the keyboard and mouse plugged into this PC?', RoleText, True, False);
  RolePage.Add('Server  -  the keyboard and mouse are plugged in here');
  RolePage.Add('Client  -  use another PC''s keyboard and mouse');
  ApplyKvmDefaults;

  NasPage := CreateInputQueryPage(RolePage.ID, 'Shared folder login',
    'The login for the shared folder''s server', NasText);
  NasPage.Add('User name:', False);
  NasPage.Add('Password:', True);
  NasPage.Values[0] := UserFromSite;

  if FileExists(ExpandConstant('{commonpf64}\RustDesk\rustdesk.exe')) then
    RdText := 'RustDesk is already set up on this PC: leave both blank to keep its password.'
  else
    RdText := 'RustDesk is new on this PC, so it needs a password.';
  RdPage := CreateInputQueryPage(NasPage.ID, 'RustDesk password',
    'The password other PCs use to view and control this one',
    RdText + ' Use the same password on every PC. Desk Console on this PC saves it too ' +
    '(Credential Manager), so View + control connects without asking.');
  RdPage.Add('Password:', True);
  RdPage.Add('Confirm password:', True);

  // Automatic sign-in: your own account, or a dedicated local standard user. The password goes
  // to the LSA secret store, not the registry.
  AlPage := CreateInputOptionPage(RdPage.ID, 'Automatic sign-in',
    'Should this PC sign in by itself when it starts?',
    'Useful for PCs you reach only through RustDesk. The password is stored encrypted ' +
    '(the same way as Sysinternals Autologon), not in the registry as plain text, and Windows ' +
    'checks it before anything changes. Anyone at the keyboard after a restart gets this ' +
    'account, so a later page lets you lock the screen right after. ' +
    'Right now: automatic sign-in is ' + AutoLogonNowText + '.', True, False);
  AlPage.Add('Leave it as it is');
  AlPage.Add('Turn on with an existing account  (e.g. your own)');
  AlPage.Add('Turn on with a dedicated local account  (created if missing, standard user)');
  AlPage.Add('Turn off');
  AlPage.SelectedValueIndex := 0;

  // R10: an existing dedicated account keeps its password when the one typed is right; only a
  // different one is reset (which loses that account's saved passwords). Three fields fill this
  // page, so the text stays at the 1.6.0 length (3 lines).
  AlCredPage := CreateInputQueryPage(AlPage.ID, 'Automatic sign-in account',
    'Which account signs in, and its password',
    'Existing account: yours is filled in (DOMAIN\user for a domain account); its password is ' +
    'checked here. Dedicated account: just a name; created if missing, its password reset only if it differs.');
  AlCredPage.Add('Account:', False);
  AlCredPage.Add('Password:', True);
  AlCredPage.Add('Confirm password:', True);

  // Dev box: reopen VS Code on a folder and resume Claude Code at sign-in (Start-DevBox.ps1)
  DevText := 'For a development PC: at each sign-in -- including an automatic one -- reopen VS Code on a ' +
    'folder, and resume your last Claude Code chat there with "claude --continue". It runs as you. ' +
    'Leave both unticked to keep this PC''s current setting; change it any time in Desk Console > Dev box.';
  if DevMore > 0 then DevText := DevText + ' This PC''s dev box has ' + IntToStr(DevMore + 1) + ' folders: this page ' +
    'shows the first, and a change here leaves the others as they are.';
  DevPage := CreateInputOptionPage(AlCredPage.ID, 'Dev box (optional)',
    'Reopen your work every time you sign in?', DevText, False, False);
  DevPage.Add('Reopen VS Code on a folder at sign-in');
  DevPage.Add('Also open a terminal running  claude --continue  in that folder');
  DevDirPage := CreateInputDirPage(DevPage.ID, 'Dev box folder', 'Which folder should reopen?',
    'Pick the project folder, for example your repository.', False, '');
  DevDirPage.Add('');
  DevDirPage.Values[0] := DevFolder;
  DevPage.Values[0] := DevCode;
  DevPage.Values[1] := DevClaude;

  // Phone or tablet: install RustDesk by scanning, then connect to the PCs
  PhonePage := CreateCustomPage(DevDirPage.ID, 'Phone or tablet (optional)',
    'Control these PCs from a phone or tablet too');
  AddText(PhonePage, 'Android  (phone, foldable, tablet)', 0, 0, True, -1);
  Q := AddQr(PhonePage, 'rustdesk-android.bmp', 0, ScaleY(20));
  Y1 := Q.Top + Q.Height + ScaleY(6);
  AddText(PhonePage, 'RustDesk APK (GitHub)', 0, Y1, False, 0);
  AddText(PhonePage, 'F-Droid', 0, Y1 + ScaleY(18), False, 1);
  AddText(PhonePage, 'iPhone / iPad', ScaleX(250), 0, True, -1);
  Q := AddQr(PhonePage, 'rustdesk-ios.bmp', ScaleX(250), ScaleY(20));
  Y2 := Q.Top + Q.Height + ScaleY(6);
  AddText(PhonePage, 'App Store', ScaleX(250), Y2, False, 2);
  if Y2 > Y1 + ScaleY(18) then Y1 := Y2 else Y1 := Y1 + ScaleY(18);
  T := AddText(PhonePage, 'Scan a code with the phone''s camera to install RustDesk (it is not on Google Play; ' +
    'Android uses the APK or F-Droid). Put the phone on the same Wi-Fi as these PCs, then connect to a PC''s ' +
    'address with your RustDesk password. Desk Console > Phone / tablet... shows this again with every PC''s address.',
    0, Y1 + ScaleY(24), False, -1);
  T.AutoSize := False;
  T.WordWrap := True;
  T.Width := PhonePage.SurfaceWidth;
  T.Height := ScaleY(60);
end;

// a folder as one quoted command-line argument
function FolderArg(const Folder: String): String;
var F: String;
begin
  F := NormDir(Folder);   // "C:\x\" would escape the closing quote
  if (Length(F) = 2) and (F[2] = ':') then F := F + '\';   // "D:" alone is a drive-relative path
  // R8: a drive root keeps its backslash, and "D:\" would escape the closing quote and swallow
  // -DevBoxClaude; doubled ("D:\\") it reaches the script as D:\
  if (F <> '') and (F[Length(F)] = '\') then F := F + '\';
  Result := '"' + F + '"';
end;

function DevBoxArgs(Param: String): String;
begin
  Result := '';
  if KeepMode or not DevBoxOn then exit;
  Result := '-DevBoxFolder ' + FolderArg(DevDirPage.Values[0]);
  if DevPage.Values[1] then Result := Result + ' -DevBoxClaude';
  if not DevPage.Values[0] then Result := Result + ' -DevBoxNoCode';
end;

function UpdatesArgs(Param: String): String;
begin
  if WizardIsTaskSelected('noautorestart') then Result := '-NoAutoRestart Enable' else Result := '';
end;

function AutoLogonArgs(Param: String): String;
begin
  Result := '';
  if KeepMode then exit;
  case AlPage.SelectedValueIndex of
    1, 2: begin
      Result := '-AutoLogon Enable';
      if WizardIsTaskSelected('autolock') then Result := Result + ' -AutoLogonLock';
    end;
    3: Result := '-AutoLogon Disable';
  end;
end;

// R6: only a real choice goes to kvm.json. 1.6.0 always passed -Kvm and -Role, so a PC that could
// not read kvm.json (no share login yet) flipped every PC's program or made itself the server.
// Now: the provider only when it differs from what kvm.json says (Deskflow when unread), and
// "IfUnset" whenever kvm.json was not read -- Setup-Synergy.ps1 then changes only what it names
// nothing for yet. Server over another named server is a takeover the Role page confirmed.
function KvmArgs(Param: String): String;
var P: String;
begin
  Result := '';
  if KeepMode then exit;   // keep: kvm.json stays as it is (the admin step still follows it)
  P := ProviderName(KvmPage.SelectedValueIndex);
  if CompareText(P, DefProvider) <> 0 then begin
    Result := '-Kvm ' + P;
    if KvmState <> KvmKnown then Result := Result + ' -KvmIfUnset';
  end;
  if KvmPage.SelectedValueIndex = 2 then exit;
  if RolePage.SelectedValueIndex = 1 then Result := Result + ' -Role Client'
  else if (KvmState = KvmKnown) and (DefServer <> '') then Result := Result + ' -Role Server'
  else Result := Result + ' -Role ServerIfUnset';
  Result := Trim(Result);
end;

function IsSettingsPage(PageID: Integer): Boolean;
begin
  Result := (PageID = SitePage.ID) or (PageID = KvmPage.ID) or (PageID = RolePage.ID) or (PageID = NasPage.ID) or
            (PageID = RdPage.ID) or (PageID = AlPage.ID) or (PageID = AlCredPage.ID) or (PageID = DevPage.ID) or
            (PageID = DevDirPage.ID) or (PageID = PhonePage.ID);
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  if PageID = KeepPage.ID then Result := not ExistingSetup
  else if KeepMode and IsSettingsPage(PageID) then Result := True
  else Result := ((PageID = SitePage.ID) and SrcHasSite) or
                 ((PageID = RolePage.ID) and (KvmPage.SelectedValueIndex = 2)) or
                 ((PageID = AlCredPage.ID) and not AutoLogonOn) or
                 ((PageID = DevDirPage.ID) and not DevBoxOn);
end;

// "Bob", ".\Bob", "PC\Bob" and "DOMAIN\Bob" split the way Setup-Synergy.ps1 splits them
procedure SplitAccount(Account: String; var Domain, Name: String);
var P: Integer;
begin
  Account := Trim(Account);
  if Copy(Account, 1, 2) = '.\' then Account := Copy(Account, 3, Length(Account));
  P := Pos('\', Account);
  if P > 0 then begin
    Domain := Copy(Account, 1, P - 1);
    Name := Copy(Account, P + 1, Length(Account));
  end else begin
    Domain := GetComputerNameString;
    Name := Account;
  end;
  if (Domain = '') or (Domain = '.') then Domain := GetComputerNameString;
end;

// U9a: ask Windows now, before the admin prompt, whether this account can sign in with this
// password -- the same LogonUser call the admin step makes. That step refuses a wrong password
// too, but says so in a console that closes by itself.
function CheckLogon(const Domain, Name, Password: String): Boolean;
var H: THandle; Err: Integer;
begin
  Result := LogonUser(Name, Domain, Password, LOGON32_LOGON_INTERACTIVE, LOGON32_PROVIDER_DEFAULT, H);
  if Result then begin
    CloseHandle(H);
    exit;
  end;
  Err := DLLGetLastError;
  if Err = ERROR_LOGON_FAILURE then
    MsgBox('Windows does not accept that password for ' + Domain + '\' + Name + ' (or there is no such account).' + #13#10#13#10 +
      'Automatic sign-in needs the account''s current Windows password.', mbError, MB_OK)
  else
    MsgBox('Windows would not sign ' + Domain + '\' + Name + ' in with that password:' + #13#10 + SysErrorMessage(Err), mbError, MB_OK);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var S, Dom, Name: String;
begin
  Result := True;
  if CurPageID = SitePage.ID then begin
    S := NormDir(SitePage.Values[0]);
    if S = '' then begin
      SuppressibleMsgBox('Enter the shared folder, for example \\server\share\DeskConsole.', mbError, MB_OK, IDOK);
      Result := False;
      exit;
    end;
    if not IsNetworkPath(S) then
      if SuppressibleMsgBox(S + ' is a folder on this PC, so your other PCs cannot reach it.' + #13#10 +
          'Use a network folder every PC can open, for example \\server\share\DeskConsole.' + #13#10#13#10 +
          'Use this local folder anyway (one PC only)?', mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDNO then begin
        Result := False;
        exit;
      end;
    ReadKvm;   // pick up the existing layout
    ApplyKvmDefaults;
    if not ShareOk then
      SuppressibleMsgBox('This PC cannot open ' + ShareDir + ' right now.' + #13#10 +
        'That is fine if its login is entered on a later page (the keyboard/mouse pages then cannot show ' +
        'the current setup); otherwise check the path.', mbInformation, MB_OK, IDOK);
  end;
  // a change of program for every PC (only when kvm.json was read: otherwise it is IfUnset)
  if (CurPageID = KvmPage.ID) and (KvmState = KvmKnown) and
     (CompareText(ProviderName(KvmPage.SelectedValueIndex), DefProvider) <> 0) then
    if SuppressibleMsgBox('Every PC uses ' + DefProvider + ' now. Switch EVERY PC to ' + ProviderName(KvmPage.SelectedValueIndex) +
        '? (kvm.json; each PC switches the next time its setup runs.)', mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDYES) = IDNO then
      Result := False;
  if CurPageID = RolePage.ID then begin
    if RolePage.SelectedValueIndex < 0 then begin
      SuppressibleMsgBox('Choose Server or Client for this PC.', mbError, MB_OK, IDOK);
      Result := False;
    end else if (RolePage.SelectedValueIndex = 0) and (KvmState = KvmKnown) and (DefServer <> '') and not IsThisPc(DefServer) then
      if SuppressibleMsgBox('kvm.json names ' + DefServer + ' as the keyboard/mouse server.' + #13#10#13#10 +
          'Make THIS PC the server for every PC instead? (' + DefServer + ' becomes a client the next time its setup runs.)',
          mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDNO) = IDNO then
        Result := False;
  end;
  if CurPageID = NasPage.ID then begin
    // U9c: a blank password keeps a saved login -- which only helps if there is one
    if (NasPage.Values[1] = '') and not ShareOk then begin
      ShareOk := (ShareDir <> '') and DirExists(ShareDir);
      if not ShareOk then
        if SuppressibleMsgBox('This PC cannot open ' + ShareDir + ' right now and no password was entered, so no share login ' +
            'will be saved.' + #13#10#13#10 + 'Go on without one?', mbConfirmation, MB_YESNO or MB_DEFBUTTON2, IDYES) = IDNO then
          Result := False;
    end;
  end;
  if CurPageID = RdPage.ID then begin
    if RdPage.Values[0] <> RdPage.Values[1] then begin
      MsgBox('The two RustDesk passwords are different.', mbError, MB_OK);
      Result := False;
    end else if (RdPage.Values[0] = '') and not FileExists(ExpandConstant('{commonpf64}\RustDesk\rustdesk.exe')) then begin
      MsgBox('RustDesk is new on this PC, so it needs a password.', mbError, MB_OK);
      Result := False;
    end;
  end;
  if CurPageID = AlCredPage.ID then begin
    if (Trim(AlCredPage.Values[0]) = '') or (AlCredPage.Values[1] = '') then begin
      MsgBox('Automatic sign-in needs an account and its password.', mbError, MB_OK);
      Result := False;
    end else if AlCredPage.Values[1] <> AlCredPage.Values[2] then begin
      MsgBox('The two passwords are different.', mbError, MB_OK);
      Result := False;
    end else begin
      SplitAccount(AlCredPage.Values[0], Dom, Name);
      if (AlPage.SelectedValueIndex = 2) and (CompareText(Name, GetUserNameString) = 0) then begin
        MsgBox(Name + ' is the account you are signed in with. For it, go Back and choose "Turn on with an existing ' +
          'account": the dedicated-account choice can reset its password, which loses its saved passwords.', mbError, MB_OK);
        Result := False;
      end else if AlPage.SelectedValueIndex = 1 then
        Result := CheckLogon(Dom, Name, AlCredPage.Values[1]);
    end;
  end;
  if CurPageID = DevDirPage.ID then begin
    if not DirExists(Trim(DevDirPage.Values[0])) then begin
      MsgBox('Pick a folder that exists on this PC.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

// ---- Ready page (U8): what the setup steps are about to do
function ProviderMemo: String;
var P: String;
begin
  P := ProviderName(KvmPage.SelectedValueIndex);
  if CompareText(P, DefProvider) <> 0 then begin
    if KvmState = KvmKnown then Result := P + ' on every PC (was ' + DefProvider + '; each PC switches when its setup runs)'
    else Result := P + ', if kvm.json names no program yet';
  end
  else if KvmState = KvmKnown then Result := P + ' (unchanged)'
  else if KvmState = KvmFresh then Result := P + ' (the first kvm.json)'
  else Result := 'what kvm.json in the shared folder says (Deskflow when there is none)';
end;

function RoleMemo: String;
begin
  if RolePage.SelectedValueIndex = 1 then begin
    Result := 'this PC is a client';
    if (DefServer <> '') and not IsThisPc(DefServer) then Result := Result + ' of ' + DefServer;
  end
  else if KvmState = KvmUnknown then Result := 'this PC is the server if kvm.json names none yet (else it joins as a client)'
  else if (KvmState = KvmKnown) and (DefServer <> '') and not IsThisPc(DefServer) then
    Result := 'this PC becomes the server, instead of ' + DefServer
  else Result := 'this PC is the server';
end;

function AutoLogonMemo: String;
begin
  case AlPage.SelectedValueIndex of
    1, 2: begin
      Result := 'ON for ' + Trim(AlCredPage.Values[0]);
      if AlPage.SelectedValueIndex = 2 then Result := Result + ' (dedicated local account)';
      if WizardIsTaskSelected('autolock') then Result := Result + ', then the screen locks';
    end;
    3: Result := 'OFF';
  else Result := 'unchanged (' + AutoLogonNowText + ')';
  end;
end;

function DevBoxMemo: String;
begin
  if not DevBoxOn then Result := 'unchanged (' + DevBoxNow + ')'
  else begin
    if DevPage.Values[0] and DevPage.Values[1] then Result := 'VS Code + claude --continue'
    else if DevPage.Values[0] then Result := 'VS Code'
    else Result := 'claude --continue';
    Result := Result + ' in ' + NormDir(DevDirPage.Values[0]) + ' at each sign-in';
  end;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var S: String;
begin
  S := 'Shared folder:' + NewLine + Space + ShareDir + NewLine + NewLine;
  if KeepMode then begin
    S := S + 'This PC''s settings (all kept):' + NewLine +
      Space + 'Keyboard and mouse: ' + KvmNowText + NewLine +
      Space + 'Automatic sign-in: ' + AutoLogonNowText + NewLine +
      Space + 'Dev box: ' + DevBoxNow + NewLine +
      Space + 'Share login and RustDesk password: unchanged' + NewLine + NewLine;
  end else begin
    S := S + 'Keyboard and mouse (kvm.json, every PC):' + NewLine + Space + ProviderMemo + NewLine;
    if KvmPage.SelectedValueIndex <> 2 then S := S + Space + RoleMemo + NewLine;
    S := S + NewLine + 'Shared folder login:' + NewLine + Space;
    if NasPage.Values[1] <> '' then S := S + 'a new login for ' + Trim(NasPage.Values[0]) + ' is saved'
    else if ShareOk then S := S + 'the login this PC uses now is kept'
    else S := S + 'none (this PC cannot open the shared folder now)';
    S := S + NewLine + NewLine + 'RustDesk password:' + NewLine + Space;
    if RdPage.Values[0] <> '' then S := S + 'new; also saved for View + control on this PC' else S := S + 'unchanged';
    S := S + NewLine + NewLine + 'Automatic sign-in:' + NewLine + Space + AutoLogonMemo + NewLine + NewLine +
      'Dev box:' + NewLine + Space + DevBoxMemo + NewLine + NewLine;
  end;
  if MemoTasksInfo <> '' then S := S + MemoTasksInfo + NewLine + NewLine;
  S := S + 'Then one Windows prompt (UAC): RustDesk and keyboard/mouse sharing, firewall, sign-in settings ' +
    'and this PC''s entry in machines.csv.';
  Result := S;
end;

// site.json for the installed copy when setup did not run from a folder that has one, or when
// the Shared folder page names another folder than the installed one
procedure WriteSite;
var L: TArrayOfString; S, F, V, Old: String; P, Q, R: Integer; Edited: Boolean;
begin
  F := ExpandConstant('{app}\site.json');
  V := ShareDir;
  StringChangeEx(V, '\', '\\', True);
  Edited := False;
  if LoadText(F, S) then begin
    Old := NormDir(JsonStr(S, 'shareRoot'));
    if (Old <> '') and (CompareText(Old, ShareDir) = 0) then exit;   // keep it, with its other settings
    // Change only shareRoot: credentialHosts, mapDrive, lanCidr... must survive (1.6.0 wrote a
    // one-key file over them). A BOM read as text would be written back twice.
    if Copy(S, 1, 1) = #$FEFF then S := Copy(S, 2, Length(S));
    if Copy(S, 1, 3) = #$EF#$BB#$BF then S := Copy(S, 4, Length(S));
    P := Pos('"shareRoot"', S);
    if P > 0 then begin
      Q := P + Length('"shareRoot"');
      while Q <= Length(S) do begin                  // the value's opening quote
        if S[Q] = '"' then break;
        Q := Q + 1;
      end;
      R := Q + 1;
      while R <= Length(S) do begin                  // its closing quote, past any \x escape
        if S[R] = '"' then break;
        if S[R] = '\' then R := R + 2 else R := R + 1;
      end;
      if R <= Length(S) then begin
        S := Copy(S, 1, Q) + V + Copy(S, R, Length(S));
        Edited := True;
      end;
    end else begin
      P := Pos('{', S);
      if P > 0 then begin
        if Pos('"', Copy(S, P + 1, Length(S))) > 0 then   // other keys follow: separate with a comma
          S := Copy(S, 1, P) + #13#10 + '  "shareRoot": "' + V + '",' + Copy(S, P + 1, Length(S))
        else
          S := Copy(S, 1, P) + ' "shareRoot": "' + V + '" ' + Copy(S, P + 1, Length(S));
        Edited := True;
      end;
    end;
  end;
  if Edited then begin
    SetArrayLength(L, 1);
    L[0] := S;
  end else begin   // none, or not JSON this can edit
    SetArrayLength(L, 3);
    L[0] := '{';
    L[1] := '  "shareRoot": "' + V + '"';
    L[2] := '}';
  end;
  SaveStringsToUTF8File(F, L, False);
end;

procedure WriteSecrets;
var L: TArrayOfString;
begin
  WriteSite;
  SetArrayLength(L, 6);
  if KeepMode then begin   // keep: nothing changes, so no secrets either
    L[0] := 'nas_user='; L[1] := 'nas_pass='; L[2] := 'rd_pass=';
    L[3] := 'al_user='; L[4] := 'al_pass='; L[5] := 'al_new=0';
  end else begin
    L[0] := 'nas_user=' + NasPage.Values[0];
    L[1] := 'nas_pass=' + NasPage.Values[1];
    L[2] := 'rd_pass=' + RdPage.Values[0];
    L[3] := 'al_user=' + AlCredPage.Values[0];
    L[4] := 'al_pass=' + AlCredPage.Values[1];
    if AlPage.SelectedValueIndex = 2 then L[5] := 'al_new=1' else L[5] := 'al_new=0';
  end;
  SaveStringsToUTF8File(ExpandConstant('{tmp}\ds-secrets.txt'), L, False);
end;

procedure DeleteSecrets;
begin
  DeleteFile(ExpandConstant('{tmp}\ds-secrets.txt'));
end;

// A running Desk Console (window or tray) can be updating itself from the share at the same
// moment, which locks Desk-Console.ps1 ("Access is denied"). Close it before copying; the [Run]
// step reopens it. Returns how many were closed.
function CloseDeskConsole: Integer;
var RC: Integer;
begin
  Result := 0;
  if Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -Command "$p = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -eq ''powershell.exe'' -and ' +
    '$_.CommandLine -match ''Desk-Console\.ps1'' }); $p | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; ' +
    'if ($p.Count) { Start-Sleep 2 }; exit (100 + $p.Count)"',
    '', SW_HIDE, ewWaitUntilTerminated, RC) then
    if RC >= 100 then Result := RC - 100;   // a PowerShell that failed before the end (exit 1) counts as none closed
end;

// The files [Files] replaces in the app folder (contract C-8): the same list, in the same order, as
// [Files] above and $Files in src\Install-DeskConsole.ps1. AppFileCount is how many there are.
function AppFile(I: Integer): String;
begin
  case I of
    0: Result := 'Desk-Console.ps1';
    1: Result := 'Setup-Synergy.ps1';
    2: Result := 'Agent.ps1';
    3: Result := 'Install-DeskConsole.ps1';
    4: Result := 'Start-DevBox.ps1';
    5: Result := 'Set-NoAutoRestart.cmd';
    6: Result := 'Remove-Synergy.cmd';
    7: Result := 'desk-console.ico';
    8: Result := 'mobile\rustdesk-android.png';
    9: Result := 'mobile\rustdesk-ios.png';
    10: Result := 'whats-new.txt';
    11: Result := 'version.txt';
  else Result := '';
  end;
end;

// Move an existing file aside (<name>.old). Windows lets a file that is only open for
// reading be renamed, so this succeeds unless something really holds it; the new copy is
// then written to a free name. ssPostInstall deletes the .old copies, and DeinitializeSetup
// puts them back if setup did not finish.
function SetAside(const F: String): Boolean;
begin
  Result := True;
  if not FileExists(F) then exit;
  DeleteFile(F + '.old');
  Result := RenameFile(F, F + '.old');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var I: Integer; Dir, Busy: String;
begin
  Result := '';
  Dir := ExpandConstant('{app}');
  DeskConsoleClosed := DeskConsoleClosed + CloseDeskConsole;
  repeat
    Busy := '';
    for I := 0 to AppFileCount - 1 do
      if not SetAside(Dir + '\' + AppFile(I)) then Busy := Busy + #13#10 + '      ' + AppFile(I);
    if Busy = '' then exit;
    if MsgBox('Setup needs to replace these Desk Console files, but another program has them open:' + Busy + #13#10#13#10 +
        'Close Desk Console and any PowerShell windows on this PC (Task Manager > Details > powershell.exe), ' +
        'then click Retry.' + #13#10 + 'Cancel stops setup and leaves this PC as it was.',
        mbError, MB_RETRYCANCEL) = IDCANCEL then begin
      Result := 'These Desk Console files are open in another program:' + Busy + #13#10#13#10 +
        'Close Desk Console / PowerShell on this PC, or restart it, then run setup again. Nothing was changed.';
      exit;
    end;
    DeskConsoleClosed := DeskConsoleClosed + CloseDeskConsole;
  until False;
end;

procedure RestoreSetAside(Restore: Boolean);
var I: Integer; F: String;
begin
  for I := 0 to AppFileCount - 1 do begin
    F := ExpandConstant('{app}') + '\' + AppFile(I);
    if FileExists(F + '.old') then begin
      if Restore and not FileExists(F) then RenameFile(F + '.old', F)
      else DeleteFile(F + '.old');
    end;
  end;
end;

procedure DeinitializeSetup;
begin
  RestoreSetAside(True);   // after a finished install there are no .old files left to restore
end;

// ---- Finished page (C-1, U1, E3, R4): what the three setup steps reported
procedure AddLine(var A: TArrayOfString; const S: String);
var N: Integer;
begin
  N := GetArrayLength(A);
  SetArrayLength(A, N + 1);
  A[N] := S;
end;

// "<Phase>|OK|", "<Phase>|WARN|<text>", "<Phase>|FAIL|<text>" lines; read once the [Run] steps are done
procedure ReadSetupResult;
var L: TArrayOfString; I, P: Integer; Line, Phase, Kind: String;
begin
  if not LoadStringsFromFile(ExpandConstant('{tmp}\ds-result.txt'), L) then begin
    Log('No setup result file: no setup step reported back.');
    exit;
  end;
  for I := 0 to GetArrayLength(L) - 1 do begin
    Line := Trim(L[I]);
    P := Pos('|', Line);
    if P = 0 then continue;
    Phase := Copy(Line, 1, P - 1);
    Line := Copy(Line, P + 1, Length(Line));
    P := Pos('|', Line);
    if P = 0 then continue;
    Kind := Uppercase(Copy(Line, 1, P - 1));
    Line := Trim(Copy(Line, P + 1, Length(Line)));
    Log('Setup step ' + Phase + ': ' + Kind + ' ' + Line);
    if Kind = 'OK' then begin
      if CompareText(Phase, 'User') = 0 then ResUserOk := True
      else if CompareText(Phase, 'Admin') = 0 then ResAdminOk := True
      else if CompareText(Phase, 'Finish') = 0 then ResFinishOk := True;
    end
    else if Kind = 'FAIL' then AddLine(ResFails, '[' + Phase + '] ' + Line)
    else if Kind = 'WARN' then AddLine(ResWarns, '[' + Phase + '] ' + Line);
  end;
end;

procedure SetFinishedHeading(const S: String);
begin
  WizardForm.FinishedHeadingLabel.Caption := S + #13#10;
  WizardForm.AdjustLabelHeight(WizardForm.FinishedHeadingLabel);
  WizardForm.FinishedLabel.Top := WizardForm.FinishedHeadingLabel.Top + WizardForm.FinishedHeadingLabel.Height;
end;

// what Inno's own ChangeFinishedLabel does: the run list and restart choice move with the text
// (the run list keeps room for its one "Open Desk Console" line)
procedure SetFinishedText(const S: String);
var Y, D: Integer;
begin
  WizardForm.FinishedLabel.Caption := S + #13#10;
  WizardForm.AdjustLabelHeight(WizardForm.FinishedLabel);
  Y := WizardForm.FinishedLabel.Top + WizardForm.FinishedLabel.Height;
  D := Y - WizardForm.YesRadio.Top;
  if WizardForm.RunList.Height - D < ScaleY(22) then D := WizardForm.RunList.Height - ScaleY(22);
  WizardForm.IncTopDecHeight(WizardForm.RunList, D);
  WizardForm.YesRadio.Top := Y;
  WizardForm.NoRadio.Top := Y + ScaleY(22);
end;

// one problem line, short enough that a few of them fit on the page
function Clip(const S: String): String;
begin
  Result := S;
  if Length(Result) > 110 then Result := Copy(Result, 1, 107) + '...';
end;

function NextStepText: String;
begin
  Result := '';
  if KeepMode then Result := 'This PC kept its settings.'
  else if KvmPage.SelectedValueIndex = 2 then Result := ''
  else if RolePage.SelectedValueIndex = 1 then begin
    Result := 'This PC is a keyboard/mouse client';
    if (DefServer <> '') and not IsThisPc(DefServer) then Result := Result + ' of ' + DefServer;
    Result := Result + '. The server trusts it within 2 minutes; then move the mouse off the server''s screen edge to reach it.';
  end else
    Result := 'Next: run this installer on each other PC and choose Client there. This PC (the server) trusts ' +
      'each one within 2 minutes.';
end;

procedure ShowSetupResult;
var S, Head, Tail, Logs: String; I, N, Shown: Integer;
begin
  Head := ''; S := '';
  if not ResAdminOk then S := S + #13#10 + 'The admin step did not finish (Windows prompt declined or failed) -- run setup again.';
  if not ResUserOk then S := S + #13#10 + 'The share login step (User) did not finish -- run setup again.';
  if not ResFinishOk then S := S + #13#10 + 'The Deskflow settings step (Finish) did not finish -- run setup again.';
  if S <> '' then begin
    Head := 'Setup did not finish';
    S := Copy(S, 3, Length(S));
  end
  else if GetArrayLength(ResFails) > 0 then begin
    Head := 'Setup finished with problems';
    S := 'Desk Console is installed, but setup reported problems:';
  end
  else if GetArrayLength(ResWarns) > 0 then S := 'Desk Console is installed. Notes from setup:'
  else S := 'Desk Console is installed.';
  // problems first, then notes; the rest is in the logs (the page holds about four)
  N := GetArrayLength(ResFails) + GetArrayLength(ResWarns);
  Shown := 0;
  for I := 0 to GetArrayLength(ResFails) - 1 do
    if Shown < 4 then begin
      S := S + #13#10 + '- ' + Clip(ResFails[I]);
      Shown := Shown + 1;
    end;
  for I := 0 to GetArrayLength(ResWarns) - 1 do
    if Shown < 4 then begin
      S := S + #13#10 + '- ' + Clip(ResWarns[I]);
      Shown := Shown + 1;
    end;
  if N > Shown then S := S + #13#10 + '- and ' + IntToStr(N - Shown) + ' more in the logs';
  if (Head <> '') or (N > 0) then begin
    if ShareDir <> '' then Logs := ShareDir + '\logs\' + GetComputerNameString + '-User.log, -Admin.log and -Finish.log'
    else Logs := 'the logs folder in the shared folder';
    S := S + #13#10#13#10 + 'Setup logs: ' + Logs;
  end;
  if (Head = '') and (NextStepText <> '') then S := S + #13#10#13#10 + NextStepText;
  // a restart prompt (YesRadio) keeps Inno's own text below ours
  if WizardForm.YesRadio.Visible then Tail := Trim(WizardForm.FinishedLabel.Caption)
  else Tail := SetupMessage(msgClickFinish);
  if Head <> '' then SetFinishedHeading(Head);
  SetFinishedText(S + #13#10#13#10 + Tail);
end;

procedure CurPageChanged(CurPageID: Integer);
var Me: String;
begin
  if CurPageID = KvmPage.ID then SetOptionText(KvmPage, KvmText)
  else if CurPageID = RolePage.ID then SetOptionText(RolePage, RoleText)
  else if CurPageID = NasPage.ID then SetQueryText(NasPage, 2, NasText)
  else if CurPageID = AlCredPage.ID then begin
    // local account: just the name; domain account: DOMAIN\name
    if CompareText(GetEnv('USERDOMAIN'), GetComputerNameString) = 0 then Me := GetUserNameString
    else Me := GetEnv('USERDOMAIN') + '\' + GetUserNameString;
    if (AlPage.SelectedValueIndex = 1) and ((AlCredPage.Values[0] = '') or (AlCredPage.Values[0] = 'BuildRunner')) then
      AlCredPage.Values[0] := Me
    else if (AlPage.SelectedValueIndex = 2) and ((AlCredPage.Values[0] = '') or (AlCredPage.Values[0] = Me)) then
      AlCredPage.Values[0] := 'BuildRunner';
  end
  else if CurPageID = wpFinished then ShowSetupResult;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var RC: Integer;
begin
  // the script-installed copy registered its own Settings > Apps entry; this installer owns it now
  if CurStep = ssInstall then
    RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\DeskConsole');
  if CurStep = ssPostInstall then begin
    RestoreSetAside(False);   // new files are in place: drop the .old copies
    ReadSetupResult;          // the [Run] steps have finished
  end;
  // a silent update closed a running Desk Console and has no Finished page to reopen it: start it
  // again, in the notification area
  if (CurStep = ssDone) and WizardSilent and (DeskConsoleClosed > 0) then
    Exec(ExpandConstant('{sys}\conhost.exe'), '--headless ' + ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe') +
      ' -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + ExpandConstant('{app}\Desk-Console.ps1') + '" -Tray',
      ExpandConstant('{app}'), SW_HIDE, ewNoWait, RC);
end;

// ---- uninstall
// Automatic sign-in and its screen-lock task outlive Desk Console; say so before it is gone.
function InitializeUninstall: Boolean;
var Who: String;
begin
  Result := True;
  Who := ReadAutoLogon;
  if Who <> '' then
    Result := SuppressibleMsgBox('Automatic sign-in is ON on this PC (' + Who + '). Uninstalling Desk Console does not ' +
      'turn it off, and the screen lock after it stays too.' + #13#10#13#10 +
      'To turn it off first, choose No, then Desk Console > Automatic sign-in... > Turn off.' + #13#10#13#10 +
      'Uninstall Desk Console now?', mbConfirmation, MB_YESNO, IDYES) = IDYES;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  // a Desk Console in the tray keeps running from {app} and holds its files
  if CurUninstallStep = usUninstall then CloseDeskConsole;
  // the app's own per-user settings (window position). HKLM\SOFTWARE\DeskConsole is setup's
  // record of what it changed on the PC (parked sign-in entries, automatic sign-in): it stays.
  if CurUninstallStep = usPostUninstall then RegDeleteKeyIncludingSubkeys(HKCU, 'Software\DeskConsole');
end;
