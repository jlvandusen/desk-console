; DeskConsoleSetup.exe -- one installer for every PC (the keyboard/mouse server and its clients).
; Build:  tools\Get-Redist.ps1            (downloads + hash-checks the bundled third-party installers)
;         "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" installer\DeskConsole.iss
;         -> dist\DeskConsoleSetup-<version>.exe
;
; Installs Desk Console for the current user (no admin), then runs Setup-Synergy.ps1:
;   User   phase (as you):  share login -> Credential Manager, optional drive mapping, kvm.json provider/server
;   Admin  phase (one UAC): Deskflow or Synergy (the other switched off), RustDesk + password,
;                           firewall, automatic sign-in, machines.csv
;   Finish phase (as you):  Deskflow settings + server layout, Deskflow trust sync task
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
LicenseFile=..\LICENSE
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
SetupLogging=yes
; let Windows Restart Manager name and close whatever holds our files (scripts included)
CloseApplications=yes
CloseApplicationsFilter=*.exe,*.dll,*.ps1,*.ico,*.txt
RestartApplications=no

[Tasks]
Name: desktopicon; Description: "Desktop shortcut"
Name: autostart;   Description: "Open Desk Console when I sign in"; Flags: unchecked
Name: autolock;    Description: "After an automatic sign-in, lock the screen straight away (recommended)"; Check: AutoLogonOn

[Files]
Source: "..\src\Desk-Console.ps1";        DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\Setup-Synergy.ps1";       DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\Install-DeskConsole.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\desk-console.ico";        DestDir: "{app}"; Flags: ignoreversion
Source: "..\src\version.txt";             DestDir: "{app}"; Flags: ignoreversion
Source: "..\THIRD-PARTY-NOTICES.md";      DestDir: "{app}"; Flags: ignoreversion
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
Name: "{userstartup}\Desk Console"; Filename: "{sys}\conhost.exe"; \
  Parameters: "--headless {sys}\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Desk-Console.ps1"""; \
  WorkingDir: "{app}"; IconFilename: "{app}\desk-console.ico"; Tasks: autostart

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Setup-Synergy.ps1"" -Phase User -FromInstaller -SecretsFile ""{tmp}\ds-secrets.txt"" {code:KvmArgs}"; \
  StatusMsg: "Saving the share login..."; Flags: runhidden waituntilterminated; BeforeInstall: WriteSecrets
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Setup-Synergy.ps1"" -Phase Admin -FromInstaller -SecretsFile ""{tmp}\ds-secrets.txt"" -InstallerDir ""{tmp}"" {code:AutoLogonArgs}"; \
  StatusMsg: "Installing keyboard/mouse sharing and RustDesk (approve the Windows prompt)..."; \
  Flags: shellexec waituntilterminated; Verb: runas
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Setup-Synergy.ps1"" -Phase Finish -FromInstaller"; \
  StatusMsg: "Configuring Deskflow..."; Flags: runhidden waituntilterminated; AfterInstall: DeleteSecrets
Filename: "{sys}\conhost.exe"; \
  Parameters: "--headless {sys}\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Desk-Console.ps1"""; \
  Description: "Open Desk Console"; Flags: postinstall nowait skipifsilent

[UninstallRun]
; the per-user Deskflow trust sync task (created by the Finish step, no admin needed to remove it)
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""DeskConsole Deskflow trust sync"" /F"; \
  Flags: runhidden; RunOnceId: "DeleteTrustSyncTask"

[UninstallDelete]
Type: files; Name: "{app}\machines.csv"
Type: files; Name: "{app}\site.json"

[Messages]
FinishedLabel=Desk Console is installed.%n%nRun this installer on every PC (the keyboard/mouse server first). Setup logs are in the shared folder's logs folder.

[Code]
var
  KvmPage, RolePage, AlPage: TInputOptionWizardPage;
  SitePage, NasPage, RdPage, AlCredPage: TInputQueryWizardPage;
  DefProvider, DefServer, ShareFromSite, UserFromSite: String;

// value of "key": "value" in a small JSON file; '' when absent (JSON \\ unescaped)
function JsonStr(const S, Key: String): String;
var p, q: Integer; T: String;
begin
  Result := '';
  p := Pos('"' + Key + '"', S); if p = 0 then exit;
  T := Copy(S, p + Length(Key) + 2, Length(S));
  p := Pos(':', T); if p = 0 then exit;
  T := Copy(T, p + 1, Length(T));
  p := Pos('"', T); if p = 0 then exit;
  T := Copy(T, p + 1, Length(T));
  q := Pos('"', T); if q = 0 then exit;
  Result := Copy(T, 1, q - 1);
  StringChangeEx(Result, '\\', '\', True);
end;

function SrcHasSite: Boolean;
begin
  Result := FileExists(ExpandConstant('{src}\site.json'));
end;

// the shared folder: the site.json beside setup, else the Shared folder page, else where setup runs
function ShareDir: String;
begin
  if ShareFromSite <> '' then Result := ShareFromSite
  else if (SitePage <> nil) and (Trim(SitePage.Values[0]) <> '') then Result := Trim(SitePage.Values[0])
  else Result := ExpandConstant('{src}');
  if (Length(Result) > 3) and (Result[Length(Result)] = '\') then Result := Copy(Result, 1, Length(Result) - 1);
end;

procedure ReadDefaults;
var A: AnsiString;
begin
  DefProvider := 'Deskflow'; DefServer := ''; ShareFromSite := ''; UserFromSite := '';
  if LoadStringFromFile(ExpandConstant('{src}\site.json'), A) then begin
    ShareFromSite := JsonStr(String(A), 'shareRoot');
    UserFromSite := JsonStr(String(A), 'credentialUser');
  end;
  if LoadStringFromFile(ShareDir + '\kvm.json', A) then begin
    if JsonStr(String(A), 'provider') <> '' then DefProvider := JsonStr(String(A), 'provider');
    DefServer := JsonStr(String(A), 'server');
  end;
end;

procedure InitializeWizard;
var ServerText: String;
begin
  ReadDefaults;

  SitePage := CreateInputQueryPage(wpWelcome, 'Shared folder',
    'Where do your PCs keep their shared settings?',
    'A network folder every PC can reach, for example \\server\share\DeskConsole. It holds the ' +
    'PC list, the keyboard/mouse layout, Deskflow fingerprints and setup logs. Use the same folder on every PC.');
  SitePage.Add('Shared folder:', False);
  SitePage.Values[0] := ExpandConstant('{src}');

  KvmPage := CreateInputOptionPage(SitePage.ID, 'Keyboard and mouse sharing',
    'Which program shares one keyboard and mouse across your PCs?',
    'Saved in kvm.json in the shared folder, so it applies to EVERY PC the next time its setup runs. ' +
    'The program not chosen is switched off on this PC, not uninstalled.', True, False);
  KvmPage.Add('Deskflow  -  free, open source (the project Synergy 3 is built on)');
  KvmPage.Add('Synergy 3  -  paid licence; its installer must be in the shared folder''s installer\ folder');
  KvmPage.Add('None  -  no keyboard/mouse sharing');
  if CompareText(DefProvider, 'Synergy') = 0 then KvmPage.SelectedValueIndex := 1
  else if CompareText(DefProvider, 'None') = 0 then KvmPage.SelectedValueIndex := 2
  else KvmPage.SelectedValueIndex := 0;

  if DefServer <> '' then ServerText := 'The server right now is ' + DefServer + '.'
  else ServerText := 'No server is set yet.';
  RolePage := CreateInputOptionPage(KvmPage.ID, 'This PC''s role',
    'Are the keyboard and mouse plugged into this PC?',
    'One PC is the server; every other PC is a client. ' + ServerText, True, False);
  RolePage.Add('Server  -  the keyboard and mouse are plugged in here');
  RolePage.Add('Client  -  use another PC''s keyboard and mouse');
  if (DefServer = '') or (CompareText(DefServer, GetComputerNameString) = 0) then RolePage.SelectedValueIndex := 0
  else RolePage.SelectedValueIndex := 1;

  NasPage := CreateInputQueryPage(RolePage.ID, 'Shared folder login',
    'The login for the shared folder''s server',
    'Saved in Windows Credential Manager so this PC reaches the shared folder at every sign-in. ' +
    'Leave the password blank to keep the login already saved on this PC.');
  NasPage.Add('User name:', False);
  NasPage.Add('Password:', True);
  NasPage.Values[0] := UserFromSite;

  RdPage := CreateInputQueryPage(NasPage.ID, 'RustDesk password',
    'The password other PCs use to view and control this one',
    'Use the same password on every PC. Leave both blank to keep the current one.');
  RdPage.Add('Password:', True);
  RdPage.Add('Confirm password:', True);

  // Automatic sign-in: your own account, or a dedicated local standard user. The password goes
  // to the LSA secret store, not the registry.
  AlPage := CreateInputOptionPage(RdPage.ID, 'Automatic sign-in',
    'Should this PC sign in by itself when it starts?',
    'Useful for PCs you reach only through RustDesk. The password is stored encrypted ' +
    '(the same way as Sysinternals Autologon), not in the registry as plain text, and Windows ' +
    'checks it before anything changes. Anyone at the keyboard after a restart gets this ' +
    'account, so a later page lets you lock the screen right after.', True, False);
  AlPage.Add('Leave it as it is');
  AlPage.Add('Turn on with an existing account  (e.g. your own)');
  AlPage.Add('Turn on with a dedicated local account  (created if missing, standard user)');
  AlPage.Add('Turn off');
  AlPage.SelectedValueIndex := 0;

  AlCredPage := CreateInputQueryPage(AlPage.ID, 'Automatic sign-in account',
    'Which account signs in, and its password',
    'Existing account: yours is filled in (a local account is just its name; a domain ' +
    'account is DOMAIN\user). Dedicated account: just a name; ' +
    'it is created, or its password reset, on this PC.');
  AlCredPage.Add('Account:', False);
  AlCredPage.Add('Password:', True);
  AlCredPage.Add('Confirm password:', True);
end;

function AutoLogonOn: Boolean;
begin
  Result := (AlPage <> nil) and ((AlPage.SelectedValueIndex = 1) or (AlPage.SelectedValueIndex = 2));
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := ((PageID = SitePage.ID) and SrcHasSite) or
            ((PageID = RolePage.ID) and (KvmPage.SelectedValueIndex = 2)) or
            ((PageID = AlCredPage.ID) and not AutoLogonOn);
end;

procedure CurPageChanged(CurPageID: Integer);
var Me: String;
begin
  if CurPageID = AlCredPage.ID then begin
    // local account: just the name; domain account: DOMAIN\name
    if CompareText(GetEnv('USERDOMAIN'), GetComputerNameString) = 0 then Me := GetUserNameString
    else Me := GetEnv('USERDOMAIN') + '\' + GetUserNameString;
    if (AlPage.SelectedValueIndex = 1) and ((AlCredPage.Values[0] = '') or (AlCredPage.Values[0] = 'BuildRunner')) then
      AlCredPage.Values[0] := Me
    else if (AlPage.SelectedValueIndex = 2) and ((AlCredPage.Values[0] = '') or (AlCredPage.Values[0] = Me)) then
      AlCredPage.Values[0] := 'BuildRunner';
  end;
end;

function AutoLogonArgs(Param: String): String;
begin
  case AlPage.SelectedValueIndex of
    1, 2: begin
      Result := '-AutoLogon Enable';
      if WizardIsTaskSelected('autolock') then Result := Result + ' -AutoLogonLock';
    end;
    3: Result := '-AutoLogon Disable';
  else Result := '';
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var A: AnsiString;
begin
  Result := True;
  if CurPageID = SitePage.ID then begin
    if Trim(SitePage.Values[0]) = '' then begin
      MsgBox('Enter the shared folder, for example \\server\share\DeskConsole.', mbError, MB_OK);
      Result := False;
    end else begin
      if not DirExists(ShareDir) then
        MsgBox('This PC cannot open ' + ShareDir + ' right now.' + #13#10 +
          'That is fine if its login is entered on a later page; otherwise check the path.', mbInformation, MB_OK);
      if LoadStringFromFile(ShareDir + '\kvm.json', A) then begin   // pick up the existing layout
        DefServer := JsonStr(String(A), 'server');
        if JsonStr(String(A), 'provider') <> '' then DefProvider := JsonStr(String(A), 'provider');
        if CompareText(DefProvider, 'Synergy') = 0 then KvmPage.SelectedValueIndex := 1
        else if CompareText(DefProvider, 'None') = 0 then KvmPage.SelectedValueIndex := 2
        else KvmPage.SelectedValueIndex := 0;
        if (DefServer <> '') and (CompareText(DefServer, GetComputerNameString) <> 0) then RolePage.SelectedValueIndex := 1;
      end;
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
    if (AlCredPage.Values[0] = '') or (AlCredPage.Values[1] = '') then begin
      MsgBox('Automatic sign-in needs an account and its password.', mbError, MB_OK);
      Result := False;
    end else if AlCredPage.Values[1] <> AlCredPage.Values[2] then begin
      MsgBox('The two passwords are different.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function KvmArgs(Param: String): String;
begin
  case KvmPage.SelectedValueIndex of
    0: Result := '-Kvm Deskflow';
    1: Result := '-Kvm Synergy';
  else Result := '-Kvm None';
  end;
  if KvmPage.SelectedValueIndex <> 2 then begin
    if RolePage.SelectedValueIndex = 0 then Result := Result + ' -Role Server'
    else Result := Result + ' -Role Client';
  end;
end;

// site.json for the installed copy when setup did not run from a folder that has one
procedure WriteSite;
var L: TArrayOfString; S: String;
begin
  if FileExists(ExpandConstant('{app}\site.json')) then exit;
  S := ShareDir;
  StringChangeEx(S, '\', '\\', True);
  SetArrayLength(L, 3);
  L[0] := '{';
  L[1] := '  "shareRoot": "' + S + '"';
  L[2] := '}';
  SaveStringsToFile(ExpandConstant('{app}\site.json'), L, False);
end;

procedure WriteSecrets;
var L: TArrayOfString;
begin
  WriteSite;
  SetArrayLength(L, 6);
  L[0] := 'nas_user=' + NasPage.Values[0];
  L[1] := 'nas_pass=' + NasPage.Values[1];
  L[2] := 'rd_pass=' + RdPage.Values[0];
  L[3] := 'al_user=' + AlCredPage.Values[0];
  L[4] := 'al_pass=' + AlCredPage.Values[1];
  if AlPage.SelectedValueIndex = 2 then L[5] := 'al_new=1' else L[5] := 'al_new=0';
  SaveStringsToUTF8File(ExpandConstant('{tmp}\ds-secrets.txt'), L, False);
end;

procedure DeleteSecrets;
begin
  DeleteFile(ExpandConstant('{tmp}\ds-secrets.txt'));
end;

// A running Desk Console can be updating itself from the share (version.txt) at the same
// moment, which locks Desk-Console.ps1 ("Access is denied"). Close it before copying;
// the [Run] step reopens it.
procedure CloseDeskConsole;
var RC: Integer;
begin
  Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.Name -eq ''powershell.exe'' -and ' +
    '$_.CommandLine -match ''Desk-Console\.ps1'' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }; Start-Sleep 2"',
    '', SW_HIDE, ewWaitUntilTerminated, RC);
end;

// the files [Files] replaces in the app folder
function AppFile(I: Integer): String;
begin
  case I of
    0: Result := 'Desk-Console.ps1';
    1: Result := 'Setup-Synergy.ps1';
    2: Result := 'Install-DeskConsole.ps1';
    3: Result := 'desk-console.ico';
    4: Result := 'version.txt';
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
  CloseDeskConsole;
  repeat
    Busy := '';
    for I := 0 to 4 do
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
    CloseDeskConsole;
  until False;
end;

procedure RestoreSetAside(Restore: Boolean);
var I: Integer; F: String;
begin
  for I := 0 to 4 do begin
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

procedure CurStepChanged(CurStep: TSetupStep);
begin
  // the script-installed copy registered its own Settings > Apps entry; this installer owns it now
  if CurStep = ssInstall then
    RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\DeskConsole');
  if CurStep = ssPostInstall then
    RestoreSetAside(False);   // new files are in place: drop the .old copies
end;
