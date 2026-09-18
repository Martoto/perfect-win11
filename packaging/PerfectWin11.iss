#ifndef AppVersion
  #error AppVersion must be supplied
#endif
#ifndef PayloadDir
  #error PayloadDir must be supplied
#endif
#ifndef OutputDir
  #error OutputDir must be supplied
#endif

[Setup]
AppId={{7D2A0B15-AD80-4E5E-BBB4-9F28B5C30D19}
AppName=Perfect Win11
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}.0
VersionInfoTextVersion={#AppVersion}
VersionInfoProductVersion={#AppVersion}.0
VersionInfoProductTextVersion={#AppVersion}
AppPublisher=Daniel Salles
VersionInfoCompany=Daniel Salles
VersionInfoProductName=Perfect Win11
VersionInfoDescription=Perfect Win11 Setup
LicenseFile={#PayloadDir}\LICENSE
DefaultDirName={localappdata}\Programs\PerfectWin11
DisableDirPage=yes
UsePreviousAppDir=no
DefaultGroupName=Perfect Win11
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.22000
UninstallDisplayName=Perfect Win11
UninstallDisplayIcon={app}\perfect-win11.exe
OutputDir={#OutputDir}
#ifdef ReleaseSigned
OutputBaseFilename=PerfectWin11-{#AppVersion}-Setup
SignTool=esigner
SignedUninstaller=yes
#else
OutputBaseFilename=PerfectWin11-{#AppVersion}-UNSIGNED-Setup
SignedUninstaller=no
#endif
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no
RestartIfNeededByRun=no
ChangesEnvironment=yes
SetupLogging=yes

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Perfect Win11"; Filename: "{app}\perfect-win11.exe"
Name: "{group}\Uninstall Perfect Win11"; Filename: "{uninstallexe}"

[Code]
const
  PackageKey = 'Software\PerfectWin11\Package';
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{7D2A0B15-AD80-4E5E-BBB4-9F28B5C30D19}_is1';
  ErrorAlreadyExists = 183;
  WaitAbandoned = $80;
var
  PackageMutex: THandle;
  MutexOwned: Boolean;

function CreateMutex(Security: Integer; InitialOwner: Boolean; Name: String): THandle;
  external 'CreateMutexW@kernel32.dll stdcall';
function WaitForSingleObject(Handle: THandle; Milliseconds: Cardinal): Cardinal;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function ReleaseMutex(Handle: THandle): Boolean;
  external 'ReleaseMutex@kernel32.dll stdcall';
function CloseHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
function RegOpenKeyEx(Key: THandle; SubKey: String; Options, Access: Cardinal; var OpenKey: THandle): Integer;
  external 'RegOpenKeyExW@advapi32.dll stdcall';
function RegQueryValueEx(Key: THandle; Name: String; Reserved: Integer; var Kind: Cardinal; Data: Integer; var Size: Cardinal): Integer;
  external 'RegQueryValueExW@advapi32.dll stdcall';
function RegCloseKey(Key: THandle): Integer;
  external 'RegCloseKey@advapi32.dll stdcall';

function FixedAppDir: String;
begin
  Result := ExpandConstant('{localappdata}\Programs\PerfectWin11');
end;

procedure UnlockPackage;
begin
  if PackageMutex <> 0 then begin
    if MutexOwned then ReleaseMutex(PackageMutex);
    CloseHandle(PackageMutex);
    PackageMutex := 0;
    MutexOwned := False;
  end;
end;

function LockPackage: Boolean;
var Name: String; LastError, WaitResult: Cardinal;
begin
  Name := Lowercase(ExpandConstant('{localappdata}'));
  StringChangeEx(Name, '\', '_', True);
  StringChangeEx(Name, ':', '_', True);
  PackageMutex := CreateMutex(0, True, 'Global\PerfectWin11.Package.' + Name);
  LastError := DLLGetLastError;
  Result := PackageMutex <> 0;
  if Result then begin
    if LastError = ErrorAlreadyExists then begin
      WaitResult := WaitForSingleObject(PackageMutex, 0);
      Result := (WaitResult = 0) or (WaitResult = WaitAbandoned);
    end;
    MutexOwned := Result;
  end;
  if not Result then begin
    UnlockPackage;
    SuppressibleMsgBox('Another Perfect Win11 operation is running, or its lock cannot be acquired. Close it and try again.', mbError, MB_OK, IDOK);
  end;
end;

function SupportedContext: Boolean;
var V: TWindowsVersion;
begin
  GetWindowsVersionEx(V);
  Result := (ProcessorArchitecture = paX64) and (V.Major = 10) and (V.Build >= 22000) and (V.ProductType = VER_NT_WORKSTATION) and not IsAdmin;
  if not Result then
    SuppressibleMsgBox('Perfect Win11 requires Windows 11 x64 and a non-elevated launch by the intended user. Do not run as administrator.', mbError, MB_OK, IDOK);
end;

function InitializeSetup: Boolean;
var Existing: String; OldVersion, NewVersion: Int64; I: Integer;
begin
  Result := False;
  if not SupportedContext then Exit;
  for I := 1 to ParamCount do begin
    if (CompareText(ParamStr(I), '/CLOSEAPPLICATIONS') = 0) or
       (CompareText(ParamStr(I), '/FORCECLOSEAPPLICATIONS') = 0) then begin
      SuppressibleMsgBox('Closing applications is forbidden. Close Perfect Win11 yourself and retry.', mbError, MB_OK, IDOK);
      Exit;
    end;
  end;
  if not LockPackage then Exit;
  if RegKeyExists(HKCU64, UninstallKey) then begin
    if not RegQueryStringValue(HKCU64, UninstallKey, 'DisplayVersion', Existing) then begin
      SuppressibleMsgBox('Cannot read the installed version; installation stopped.', mbError, MB_OK, IDOK);
      Exit;
    end;
    if not StrToVersion(Existing, OldVersion) or not StrToVersion('{#AppVersion}', NewVersion) then begin
      SuppressibleMsgBox('Cannot verify installed version; installation stopped.', mbError, MB_OK, IDOK);
      Exit;
    end;
    if ComparePackedVersion(OldVersion, NewVersion) > 0 then begin
      SuppressibleMsgBox('A newer Perfect Win11 version is installed. Downgrades are not supported.', mbError, MB_OK, IDOK);
      Exit;
    end;
  end;
  Result := True;
end;

function ReadUserPath(var Value: String; var Kind: Cardinal; var Exists: Boolean): Boolean;
var Key: THandle; Size: Cardinal; Code: Integer;
begin
  Value := ''; Kind := 2; Exists := False;
  Code := RegOpenKeyEx(HKCU, 'Environment', 0, 1, Key);
  Result := Code = 2;
  if Code <> 0 then Exit;
  Size := 0;
  Code := RegQueryValueEx(Key, 'Path', 0, Kind, 0, Size);
  RegCloseKey(Key);
  Result := Code = 2;
  if Code = 2 then begin Kind := 2; Exit; end;
  if Code <> 0 then Exit;
  Exists := True;
  Result := ((Kind = 1) or (Kind = 2)) and RegQueryStringValue(HKCU, 'Environment', 'Path', Value);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var Value: String; Kind: Cardinal; Exists: Boolean;
begin
  Result := '';
  if CompareText(RemoveBackslashUnlessRoot(ExpandConstant('{app}')), FixedAppDir) <> 0 then
    Result := 'Perfect Win11 must be installed in ' + FixedAppDir + '. /DIR overrides are not supported.'
  else if not ReadUserPath(Value, Kind, Exists) then
    Result := 'Cannot safely read the user PATH. Only REG_SZ and REG_EXPAND_SZ are supported.';
end;

function WriteUserPath(const Value: String; Kind: Cardinal): Boolean;
begin
  if Kind = 1 then Result := RegWriteStringValue(HKCU, 'Environment', 'Path', Value)
  else Result := RegWriteExpandStringValue(HKCU, 'Environment', 'Path', Value);
end;

function PathContains(const Value, Entry: String): Boolean;
var I, Start: Integer; Part: String;
begin
  Result := False; Start := 1;
  for I := 1 to Length(Value) + 1 do begin
    if (I > Length(Value)) or (Value[I] = ';') then begin
      Part := Trim(Copy(Value, Start, I - Start));
      if (Length(Part) >= 2) and (Part[1] = '"') and (Part[Length(Part)] = '"') then
        Part := Copy(Part, 2, Length(Part) - 2);
      if CompareText(RemoveBackslashUnlessRoot(Part), Entry) = 0 then begin Result := True; Exit; end;
      Start := I + 1;
    end;
  end;
end;

procedure AddUserPath;
var BeforeValue, AfterValue: String; Kind: Cardinal; Exists: Boolean;
begin
  if not ReadUserPath(BeforeValue, Kind, Exists) then
    RaiseException('Cannot safely read the user PATH.');
  if PathContains(BeforeValue, FixedAppDir) then Exit;
  AfterValue := BeforeValue;
  if (AfterValue <> '') and (AfterValue[Length(AfterValue)] <> ';') then AfterValue := AfterValue + ';';
  AfterValue := AfterValue + FixedAppDir;
  { Persist the exact preimage first. A crash before the PATH write cannot remove a user entry. }
  if not RegWriteStringValue(HKCU, PackageKey, 'PathBefore', BeforeValue) or
     not RegWriteStringValue(HKCU, PackageKey, 'PathAfter', AfterValue) or
     not RegWriteDWordValue(HKCU, PackageKey, 'PathExisted', Ord(Exists)) or
     not RegWriteDWordValue(HKCU, PackageKey, 'PathOwned', 1) then
    RaiseException('Cannot persist PATH ownership.');
  if not WriteUserPath(AfterValue, Kind) then begin
    RegDeleteValue(HKCU, PackageKey, 'PathOwned');
    RaiseException('Cannot update the user PATH.');
  end;
end;

procedure RemoveUserPath;
var Value, BeforeValue, AfterValue, Entry: String;
    Kind, Owned, Existed: Cardinal;
    Exists: Boolean; I, Start, Found, Count, EntryLength: Integer;
begin
  if not RegQueryDWordValue(HKCU, PackageKey, 'PathOwned', Owned) or (Owned <> 1) then Exit;
  if not ReadUserPath(Value, Kind, Exists) then begin Log('PATH type unreadable; preserved.'); Exit; end;
  if not Exists then Exit;
  if not RegQueryStringValue(HKCU, PackageKey, 'PathBefore', BeforeValue) or
     not RegQueryStringValue(HKCU, PackageKey, 'PathAfter', AfterValue) or
     not RegQueryDWordValue(HKCU, PackageKey, 'PathExisted', Existed) then Exit;
  if Value = AfterValue then begin
    if Existed = 0 then RegDeleteValue(HKCU, 'Environment', 'Path')
    else WriteUserPath(BeforeValue, Kind);
    Exit;
  end;
  { If edited since install, remove exactly one owned token, without rebuilding PATH. }
  Entry := FixedAppDir; EntryLength := Length(Entry);
  Start := 1; Found := 0; Count := 0;
  for I := 1 to Length(Value) + 1 do begin
    if (I > Length(Value)) or (Value[I] = ';') then begin
      if Copy(Value, Start, I - Start) = Entry then begin Found := Start; Count := Count + 1; end;
      Start := I + 1;
    end;
  end;
  if Count <> 1 then begin Log('Owned PATH token changed or ambiguous; preserved.'); Exit; end;
  if (Found > 1) and (BeforeValue <> '') and (BeforeValue[Length(BeforeValue)] <> ';') then
    Delete(Value, Found - 1, EntryLength + 1)
  { A separator after our token was added by someone else. Preserve it, even
    if this leaves an empty PATH component. Only remove bytes we inserted. }
  else Delete(Value, Found, EntryLength);
  WriteUserPath(Value, Kind);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then AddUserPath;
end;

function InitializeUninstall: Boolean;
begin
  Result := SupportedContext;
  if Result then Result := LockPackage;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then begin
    RemoveUserPath;
    RegDeleteKeyIncludingSubkeys(HKCU, PackageKey);
  end;
end;

procedure DeinitializeSetup;
begin
  UnlockPackage;
end;

procedure DeinitializeUninstall;
begin
  UnlockPackage;
end;
