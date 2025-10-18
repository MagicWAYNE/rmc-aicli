; RMC-AICLI 多工具安装器
; - Node：在线下载 MSI（PowerShell IWR），若已安装 Node ≥ 22.0.0 则跳过
; - npm：以当前登录用户上下文安装所选 CLI（例如 gemini-cli/iflow-cli），并把 {userappdata}\npm 追加到用户 PATH
; - 右键菜单（Win11 经典菜单，HKCR）：为每个安装成功的 CLI 注册独立菜单项（方案A）
; - 安装结束广播 PATH 变更（ChangesEnvironment=yes）

[Setup]
AppId={{A1A3B8C7-3E12-4F2E-9C2E-5C2D6D0B8F31}}
AppName=RMC-AICLI
AppVersion=0.2.0
DefaultDirName={pf}\RMC-AICLI
DisableDirPage=yes
DisableProgramGroupPage=yes
OutputBaseFilename=RMC-AICLI-Setup
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
ChangesEnvironment=yes

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Default.isl"



[Code]
const
  NodeMinVersion = '22.0.0';
  NodeUrl        = 'https://nodejs.org/dist/v22.20.0/node-v22.20.0-x64.msi';
  StepCount      = 7; // 0..6

var
  StepsPage: TWizardPage;
  StepLabels: array[0..StepCount-1] of TNewStaticText;
  StepNames: array[0..StepCount-1] of string;
  StepBar: TNewProgressBar;
  ViewLogBtn: TNewButton;
  NpmLogPath: string; // 保留旧变量（向后兼容），现作为占位不用
  StepsStarted: Boolean;
  ToolSelectPage: TInputOptionWizardPage;
  InstallGemini: Boolean;
  InstallIFlow: Boolean;
  AggLogPath: string;
  GeminiLogPath: string;
  IFlowLogPath: string;

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

procedure LogToAgg(const S: string);
begin
  if AggLogPath = '' then exit;
  SaveStringToFile(AggLogPath, S + #13#10, True);
end;

function GetNpmCmd(): string;
begin
  Result := ExpandConstant('{pf}\nodejs\npm.cmd');
  if not FileExists(Result) then
    Result := 'npm.cmd';
end;

function ExecAsOriginalUserWait(const FileName, Params: string): Boolean;
var
  Code: Integer;
begin
  Result := ExecAsOriginalUser(FileName, Params, '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

// 已在上方定义 ExecAsOriginalUserWait，这里删除重复定义

function InstallNpmGlobalForTool(const PackageName, LogFile: string): Boolean;
var
  NpmCmd: string;
begin
  NpmCmd := GetNpmCmd();
  DeleteFile(LogFile);
  Result := ExecAsOriginalUserWait(ExpandConstant('{cmd}'),
    '/c ""' + NpmCmd + '" install -g ' + PackageName + ' > "' + LogFile + '" 2>&1"');
end;

function VerifyTool(const CmdName, VerifyCmd, VerifyFile, LogFile: string): Boolean;
var
  ExistsCmd: Boolean;
begin
  ExistsCmd := FileExists(VerifyFile);
  if ExistsCmd then begin
    Result := True;
  end else begin
    Result := ExecAsOriginalUserWait(ExpandConstant('{cmd}'),
      '/c ' + VerifyCmd + ' >> "' + LogFile + '" 2>&1');
  end;
end;

procedure RegisterContextMenuForTool(const KeyName, DisplayText, ExecCommand: string);
var
  BaseKey: string;
begin
  BaseKey := 'Directory\\Background\\shell\\' + KeyName;
  RegWriteStringValue(HKEY_CLASSES_ROOT, BaseKey, 'MUIVerb', DisplayText);
  RegWriteStringValue(HKEY_CLASSES_ROOT, BaseKey, 'Icon', 'powershell.exe');
  RegWriteStringValue(HKEY_CLASSES_ROOT, BaseKey + '\\command', '', ExecCommand);
end;

procedure InitStepNames();
begin
  StepNames[0] := '检测 Node 版本';
  StepNames[1] := '下载 Node（按需）';
  StepNames[2] := '安装 Node（按需）';
  StepNames[3] := '更新用户 PATH';
  StepNames[4] := '安装所选 CLI';
  StepNames[5] := '验证所选 CLI';
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
  if (AggLogPath <> '') and FileExists(AggLogPath) then begin
    ExecAsOriginalUser('notepad.exe', '"' + AggLogPath + '"', '', SW_SHOWNORMAL, ewNoWait, Code);
  end else begin
    MsgBox('暂未生成日志文件。', mbInformation, MB_OK);
  end;
end;

procedure InitializeWizard;
var
  i, TopPos: Integer;
begin
  InitStepNames();
  ; // 选择页（默认勾选 iFlow）
  ToolSelectPage := CreateInputOptionPage(wpWelcome, '选择要安装的 AI CLI 工具', '可多选', '请选择要安装的 CLI 工具：', False, False);
  ToolSelectPage.Add('iFlow CLI（需要 Node ≥ 22）');
  ToolSelectPage.Add('Gemini CLI（需要 Node ≥ 22）');
  ToolSelectPage.Values[0] := True;  ; // 默认勾选 iFlow

  StepsPage := CreateCustomPage(wpReady, '正在配置 AI CLI 环境', '将按步骤自动完成安装与配置');

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
  NpmLogPath := '';
  AggLogPath := ExpandConstant('{tmp}\aicli-install.log');
  GeminiLogPath := ExpandConstant('{tmp}\gemini-install.log');
  IFlowLogPath  := ExpandConstant('{tmp}\iflow-install.log');
  DeleteFile(AggLogPath);
  DeleteFile(GeminiLogPath);
  DeleteFile(IFlowLogPath);
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

// 重复定义清理：ExecAsOriginalUserWait 已在顶部附近定义

procedure EnsureUserPathSetup();
begin
  AppendToUserPath(ExpandConstant('{userappdata}\npm'));
  AppendToUserPath(ExpandConstant('{pf}\nodejs'));
end;

procedure ExecuteAllSteps();
var
  Msi: string;
  SkipNode: Boolean;
  AllInstallOk, AllVerifyOk: Boolean;
  OneSelected: Boolean;
begin
  if StepsStarted then Exit;
  StepsStarted := True;
  StepPendingAll();
  LogToAgg('开始执行安装流程');

  InstallIFlow := False;
  InstallGemini := False;
  if ToolSelectPage <> nil then begin
    InstallIFlow := ToolSelectPage.Values[0];
    InstallGemini := ToolSelectPage.Values[1];
  end;
  OneSelected := InstallIFlow or InstallGemini;
  if not OneSelected then
    LogToAgg('未选择任何 CLI 工具，后续步骤将跳过安装/验证/右键注册');

  ; // 0. 检测 Node 版本
  StepStart(0);
  SkipNode := ShouldSkipNodeInstall();
  if SkipNode then LogToAgg('已满足 Node 版本要求（≥ ' + NodeMinVersion + '）') else LogToAgg('未检测到合规 Node，将下载并安装');
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
  EnsureUserPathSetup();
  StepDone(3);

  ; // 4. 安装所选 CLI（写日志）
  StepStart(4);
  AllInstallOk := True;
  if OneSelected then begin
    if InstallIFlow then begin
      LogToAgg('开始安装 iFlow CLI');
      if not InstallNpmGlobalForTool('@iflow-ai/iflow-cli', IFlowLogPath) then begin
        AllInstallOk := False;
        LogToAgg('安装 iFlow CLI 失败，详见日志：' + IFlowLogPath);
      end else
        LogToAgg('安装 iFlow CLI 完成');
    end;
    if InstallGemini then begin
      LogToAgg('开始安装 Gemini CLI');
      if not InstallNpmGlobalForTool('@google/gemini-cli', GeminiLogPath) then begin
        AllInstallOk := False;
        LogToAgg('安装 Gemini CLI 失败，详见日志：' + GeminiLogPath);
      end else
        LogToAgg('安装 Gemini CLI 完成');
    end;
    if AllInstallOk then StepDone(4) else StepFail(4);
  end else begin
    StepSkip(4);
  end;

  ; // 5. 验证所选 CLI
  StepStart(5);
  AllVerifyOk := True;
  if OneSelected then begin
    if InstallIFlow then begin
      if not VerifyTool('iflow', '"%APPDATA%\\npm\\iflow.cmd" --version', ExpandConstant('{userappdata}\npm\iflow.cmd'), IFlowLogPath) then begin
        AllVerifyOk := False;
        LogToAgg('验证 iFlow CLI 失败，详见日志：' + IFlowLogPath);
      end;
    end;
    if InstallGemini then begin
      if not VerifyTool('gemini', '"%APPDATA%\\npm\\gemini.cmd" --version', ExpandConstant('{userappdata}\npm\gemini.cmd'), GeminiLogPath) then begin
        AllVerifyOk := False;
        LogToAgg('验证 Gemini CLI 失败，详见日志：' + GeminiLogPath);
      end;
    end;
    if AllVerifyOk then StepDone(5) else StepFail(5);
  end else begin
    StepSkip(5);
  end;

  ; // 6. 注册右键菜单（按工具选择与安装结果动态注册）
  if OneSelected then begin
    if InstallIFlow then
      RegisterContextMenuForTool('OpenIFlowCLI', '在此处打开 iFlow-CLI',
        'powershell.exe -NoLogo -NoProfile -NoExit -Command ""Set-Location -LiteralPath ''%V''; iflow""');
    if InstallGemini then
      RegisterContextMenuForTool('OpenGeminiCLI', '在此处打开 Gemini-CLI',
        'powershell.exe -NoLogo -NoProfile -NoExit -Command ""Set-Location -LiteralPath ''%V''; gemini""');
  end else begin
    StepSkip(6);
  end;
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

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then begin
    RegDeleteKeyIncludingSubkeys(HKEY_CLASSES_ROOT, 'Directory\\Background\\shell\\OpenIFlowCLI');
    RegDeleteKeyIncludingSubkeys(HKEY_CLASSES_ROOT, 'Directory\\Background\\shell\\OpenGeminiCLI');
  end;
end;