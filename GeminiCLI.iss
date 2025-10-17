; RMC-AICLI-Gemini 安装器
; - Node：在线下载 MSI（PowerShell IWR），若已安装 Node ≥ 20.0.0 则跳过
; - npm：以当前登录用户上下文安装 gemini-cli（runasoriginaluser/ExecAsOriginalUser），并把 {userappdata}\npm 追加到用户 PATH
; - 右键菜单（Win11 经典菜单，HKCR）：PowerShell 图标，进入所点目录并运行 gemini
; - 安装结束广播 PATH 变更（ChangesEnvironment=yes）

[Setup]
AppId={{9FCE7DDD-6ECA-4E6E-A7C6-3C6E9C62D499}
AppName=RMC-AICLI-Gemini
AppVersion=0.1.4
DefaultDirName={pf}\RMC-AICLI-Gemini
DisableDirPage=yes
DisableProgramGroupPage=yes
OutputBaseFilename=RMC-AICLI-Gemini
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
ChangesEnvironment=yes

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Default.isl"

[Registry]
; 右键菜单（经典菜单，针对文件夹空白处）
; 文本与图标
Root: HKCR; Subkey: "Directory\Background\shell\OpenGeminiCLI"; ValueType: string; ValueName: "MUIVerb"; ValueData: "在此处打开 Gemini-CLI"; Flags: uninsdeletekey
Root: HKCR; Subkey: "Directory\Background\shell\OpenGeminiCLI"; ValueType: string; ValueName: "Icon";    ValueData: "powershell.exe"; Flags: uninsdeletevalue
; 使用 PowerShell 打开并定位到当前目录，然后执行 gemini；保留窗口
Root: HKCR; Subkey: "Directory\Background\shell\OpenGeminiCLI\command"; ValueType: string; ValueName: ""; ValueData: "powershell.exe -NoLogo -NoProfile -NoExit -Command ""Set-Location -LiteralPath '%V'; gemini"""; Flags: uninsdeletekey

[Code]
const
  NodeMinVersion = '20.0.0';
  NodeUrl        = 'https://nodejs.org/dist/v22.20.0/node-v22.20.0-x64.msi';
  StepCount      = 7; // 0..6

var
  StepsPage: TWizardPage;
  StepLabels: array[0..StepCount-1] of TNewStaticText;
  StepNames: array[0..StepCount-1] of string;
  StepBar: TNewProgressBar;
  ViewLogBtn: TNewButton;
  NpmLogPath: string;
  StepsStarted: Boolean;

function GetVersionPart(const S: string; PartIndex: Integer): Integer;
var
  i, startPos, curIndex, len: Integer;
  seg: string;
begin
  Result := 0;
  startPos := 1;
  curIndex := 0;
  len := Length(S);
  i := 1;
  while i <= len + 1 do begin
    if (i = len + 1) or (S[i] = '.') then begin
      if curIndex = PartIndex then begin
        seg := Copy(S, startPos, i - startPos);
        Result := StrToIntDef(seg, 0);
        exit;
      end;
      Inc(curIndex);
      startPos := i + 1;
    end;
    Inc(i);
  end;
end;

function NormalizeVersion(const S: string): string;
var
  T: string;
begin
  T := Trim(S);
  if (Length(T) > 0) and ((T[1] = 'v') or (T[1] = 'V')) then
    Delete(T, 1, 1);
  Result := T;
end;

function CompareSemver(const A, B: string): Integer;
var
  A0, A1, A2, B0, B1, B2: Integer;
  SA, SB: string;
begin
  SA := NormalizeVersion(A);
  SB := NormalizeVersion(B);
  A0 := GetVersionPart(SA, 0);
  A1 := GetVersionPart(SA, 1);
  A2 := GetVersionPart(SA, 2);
  B0 := GetVersionPart(SB, 0);
  B1 := GetVersionPart(SB, 1);
  B2 := GetVersionPart(SB, 2);

  if A0 <> B0 then begin
    if A0 > B0 then Result := 1 else Result := -1;
  end else if A1 <> B1 then begin
    if A1 > B1 then Result := 1 else Result := -1;
  end else if A2 <> B2 then begin
    if A2 > B2 then Result := 1 else Result := -1;
  end else
    Result := 0;
end;

function ReadAllText(const FilePath: string): string;
var
  Lines: TArrayOfString;
begin
  Result := '';
  if LoadStringsFromFile(FilePath, Lines) then begin
    if GetArrayLength(Lines) > 0 then
      Result := Trim(Lines[0]);
  end;
end;

procedure InitStepNames();
begin
  StepNames[0] := '检测 Node 版本';
  StepNames[1] := '下载 Node（按需）';
  StepNames[2] := '安装 Node（按需）';
  StepNames[3] := '更新用户 PATH';
  StepNames[4] := '安装 gemini-cli';
  StepNames[5] := '验证 gemini';
  StepNames[6] := '注册右键菜单';
end;

procedure SetStepState(Index: Integer; const State: string);
begin
  if (Index >= 0) and (Index < StepCount) then begin
    StepLabels[Index].Caption := State + ' ' + StepNames[Index];
  end;
end;

procedure StepPendingAll();
var
  i: Integer;
begin
  for i := 0 to StepCount-1 do
    SetStepState(i, '○');
end;

procedure StepStart(Index: Integer);
begin
  SetStepState(Index, '▶');
  if Assigned(StepBar) then begin
    StepBar.Style := npbstMarquee;
  end;
end;

procedure StepDone(Index: Integer);
begin
  SetStepState(Index, '✔');
  if Assigned(StepBar) then begin
    StepBar.Style := npbstNormal;
    StepBar.Position := 0;
  end;
end;

procedure StepSkip(Index: Integer);
begin
  SetStepState(Index, '✔(跳过)');
end;

procedure StepFail(Index: Integer);
begin
  SetStepState(Index, '✖');
  if Assigned(StepBar) then begin
    StepBar.Style := npbstNormal;
    StepBar.Position := 0;
  end;
end;

procedure OnViewLogClick(Sender: TObject);
var
  Code: Integer;
begin
  if (NpmLogPath <> '') and FileExists(NpmLogPath) then begin
    ExecAsOriginalUser('notepad.exe', '"' + NpmLogPath + '"', '', SW_SHOWNORMAL, ewNoWait, Code);
  end else begin
    MsgBox('暂未生成日志文件。', mbInformation, MB_OK);
  end;
end;

procedure InitializeWizard;
var
  i, TopPos: Integer;
begin
  InitStepNames();
  StepsPage := CreateCustomPage(wpReady, '正在配置 Gemini-CLI 环境', '将按步骤自动完成安装与配置');

  TopPos := ScaleY(8);
  for i := 0 to StepCount-1 do begin
    StepLabels[i] := TNewStaticText.Create(StepsPage);
    StepLabels[i].Parent := StepsPage.Surface;
    StepLabels[i].Left := ScaleX(12);
    StepLabels[i].Top := TopPos;
    StepLabels[i].AutoSize := True;
    StepLabels[i].Caption := '';
    TopPos := TopPos + ScaleY(18);
  end;

  StepBar := TNewProgressBar.Create(StepsPage);
  StepBar.Parent := StepsPage.Surface;
  StepBar.Left := ScaleX(12);
  StepBar.Top := TopPos + ScaleY(4);
  StepBar.Width := StepsPage.SurfaceWidth - ScaleX(24);
  StepBar.Style := npbstNormal;

  ViewLogBtn := TNewButton.Create(StepsPage);
  ViewLogBtn.Parent := StepsPage.Surface;
  ViewLogBtn.Left := StepBar.Left;
  ViewLogBtn.Top := StepBar.Top + ScaleY(28);
  ViewLogBtn.Width := ScaleX(120);
  ViewLogBtn.Caption := '查看安装日志';
  ViewLogBtn.OnClick := @OnViewLogClick;

  StepPendingAll();
  NpmLogPath := ExpandConstant('{tmp}\npm-install.log');
  StepsStarted := False;
end;

function TryGetNodeVersionViaCmd(const NodeExe: string; const OutFile: string): Boolean;
var
  Cmd, Params: string;
  Code: Integer;
begin
  if NodeExe = '' then begin
    Cmd := ExpandConstant('{cmd}');
    Params := '/c node -v > "' + OutFile + '" 2>nul';
  end else begin
    Cmd := ExpandConstant('{cmd}');
    Params := '/c "' + NodeExe + '" -v > "' + OutFile + '" 2>nul';
  end;
  Result := Exec(Cmd, Params, '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0) and FileExists(OutFile);
end;

function DetectInstalledNodeVersion(): string;
var
  TmpFile: string;
begin
  Result := '';
  TmpFile := ExpandConstant('{tmp}\node_ver.txt');
  DeleteFile(TmpFile);

  if TryGetNodeVersionViaCmd('', TmpFile) then begin
    Result := ReadAllText(TmpFile);
    if Result <> '' then exit;
  end;

  if TryGetNodeVersionViaCmd(ExpandConstant('{pf}\nodejs\node.exe'), TmpFile) then begin
    Result := ReadAllText(TmpFile);
  end;

  DeleteFile(TmpFile);
end;

function ShouldSkipNodeInstall(): Boolean;
var
  CurVer: string;
begin
  CurVer := DetectInstalledNodeVersion();
  if CurVer = '' then begin
    Log('Node not detected.');
    Result := False;
  end else begin
    Log('Detected Node version: ' + CurVer);
    Result := CompareSemver(CurVer, NodeMinVersion) >= 0;
  end;
end;

function DownloadNodeMsi(TargetFile: string): Boolean;
var
  PSParams: string;
  Code: Integer;
begin
  DeleteFile(TargetFile);

  PSParams :=
    '-NoLogo -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass ' +
    '-Command "$ProgressPreference=''SilentlyContinue''; ' +
    'Invoke-WebRequest -UseBasicParsing -Uri ''' + NodeUrl + ''' -OutFile ''' + TargetFile + '''; ' +
    'if (Test-Path ''' + TargetFile + ''') { exit 0 } else { exit 1 }"';

  Result := Exec('powershell.exe', PSParams, '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);

  if not Result then begin
    ; // 离线回退：安装器同目录存在同名 MSI 时，复制作为回退
    if FileExists(ExpandConstant('{src}\node-v22.20.0-x64.msi')) then
      Result := CopyFile(ExpandConstant('{src}\node-v22.20.0-x64.msi'), TargetFile, False);
  end;
end;

function InstallNodeFromMsi(const MsiFile: string): Boolean;
var
  Code: Integer;
begin
  Result := Exec('msiexec.exe',
    '/i "' + MsiFile + '" /qn /norestart',
    '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

procedure AppendToUserPath(const DirToAdd: string);
var
  CurPath, NewPath: string;
begin
  if not DirExists(DirToAdd) then
    CreateDir(DirToAdd);
  if RegQueryStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', CurPath) then begin
    if Pos(LowerCase(DirToAdd), LowerCase(CurPath)) = 0 then begin
      if (CurPath <> '') and (CurPath[Length(CurPath)] <> ';') then
        NewPath := CurPath + ';' + DirToAdd
      else
        NewPath := CurPath + DirToAdd;
      RegWriteStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', NewPath);
    end;
  end else begin
    RegWriteStringValue(HKEY_CURRENT_USER, 'Environment', 'Path', DirToAdd);
  end;
end;

function ExecAsOriginalUserWait(const FileName, Params: string): Boolean;
var
  Code: Integer;
begin
  Result := ExecAsOriginalUser(FileName, Params, '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

procedure InstallGeminiCliForCurrentUser();
var
  NpmCmd: string;
begin
  NpmCmd := ExpandConstant('{pf}\nodejs\npm.cmd');
  if not FileExists(NpmCmd) then
    NpmCmd := 'npm.cmd';  ; // 兜底依赖 PATH

  ; // 确保当前用户的 npm bin 在 PATH（右键菜单新开终端可直接用 gemini）
  AppendToUserPath(ExpandConstant('{userappdata}\npm'));
  ; // 保险起见，也把 Node 安装目录加入用户 PATH（Node MSI 通常已写入系统 PATH）
  AppendToUserPath(ExpandConstant('{pf}\nodejs'));

  ; // 记录 npm 安装日志
  DeleteFile(NpmLogPath);

  if not ExecAsOriginalUserWait(ExpandConstant('{cmd}'),
      '/c ""' + NpmCmd + '" install -g @google/gemini-cli > "' + NpmLogPath + '" 2>&1"') then begin
    MsgBox('安装 gemini-cli 失败，请检查网络后重试。', mbError, MB_OK);
  end else begin
    ; // 安装完成后校验：以原始用户运行，读取 %APPDATA%\npm 下的 gemini.cmd
    ExecAsOriginalUserWait(ExpandConstant('{cmd}'),
      '/c "%APPDATA%\npm\gemini.cmd" --version >> "' + NpmLogPath + '" 2>&1');
  end;
end;

procedure ExecuteAllSteps();
var
  Msi: string;
  SkipNode: Boolean;
begin
  if StepsStarted then Exit;
  StepsStarted := True;
  StepPendingAll();

  ; // 0. 检测 Node 版本
  StepStart(0);
  SkipNode := ShouldSkipNodeInstall();
  StepDone(0);

  ; // 1,2. Node 下载与安装（按需）
  if not SkipNode then begin
    StepStart(1);
    Msi := ExpandConstant('{tmp}\node.msi');
    if not DownloadNodeMsi(Msi) then begin
      StepFail(1);
      MsgBox('无法下载或找到 Node.js 安装包，请检查网络或将 MSI 与安装器放同目录后重试。', mbError, MB_OK);
      exit;
    end else
      StepDone(1);

    StepStart(2);
    if not InstallNodeFromMsi(Msi) then begin
      StepFail(2);
      MsgBox('Node.js 安装失败。', mbError, MB_OK);
      exit;
    end else
      StepDone(2);
  end else begin
    StepSkip(1);
    StepSkip(2);
  end;

  ; // 3. 更新 PATH（用户级）
  StepStart(3);
  AppendToUserPath(ExpandConstant('{userappdata}\npm'));
  AppendToUserPath(ExpandConstant('{pf}\nodejs'));
  StepDone(3);

  ; // 4. 安装 gemini-cli（写日志）
  StepStart(4);
  InstallGeminiCliForCurrentUser;
  StepDone(4);

  ; // 5. 验证 gemini
  StepStart(5);
  if FileExists(ExpandConstant('{userappdata}\npm\gemini.cmd')) then
    StepDone(5)
  else
    StepFail(5);

  ; // 6. 注册右键菜单（由 [Registry] 执行，这里标记完成）
  StepDone(6);
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (StepsPage <> nil) and (CurPageID = StepsPage.ID) then begin
    WizardForm.NextButton.Enabled := False;
    WizardForm.BackButton.Enabled := False;
    try
      ExecuteAllSteps();
    finally
      WizardForm.NextButton.Enabled := True;
      WizardForm.BackButton.Enabled := True;
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  { 不再在安装阶段切换页面或执行步骤，逻辑已迁移到 CurPageChanged }
end;