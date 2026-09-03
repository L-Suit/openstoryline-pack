; ============================================================
; OpenStoryline Windows Installer
; 使用 Inno Setup 7.x 64 位编译（2GB+ 素材必须 7.x 64 位，6.x 会 OOM）
;
; 与方案文档的差异说明：
; 1. resource 打入 {app}\app\resource\（config.toml 相对路径基于
;    config.toml 所在目录解析，放 app 目录下可零配置改动）
; 2. models 由启动器首次启动时下载到 {app}\app\.storyline\models\
; 3. Web 服务端口为 7860（与原项目 run.sh 一致，文档中 8005 为笔误）
; ============================================================

#define MyAppName "OpenStoryline"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "OpenStoryline"
#define MyAppURL "http://127.0.0.1:7860"
#define MyAppExeName "start.bat"

[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
OutputDir=..\..\build\windows
OutputBaseFilename=OpenStoryline-Setup-{#MyAppVersion}-win64
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; 安装包图标（assets/icon.ico 存在时启用）
#if FileExists("..\..\assets\icon.ico")
SetupIconFile=..\..\assets\icon.ico
#endif
; 许可协议（可选）
; LicenseFile=..\..\assets\LICENSE.txt

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
#if FileExists("compiler:Languages\ChineseSimplified.isl")
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式 / Create desktop shortcut"; GroupDescription: "附加选项 / Additional:"; Flags: checkedonce

[Files]
; Python 运行时（runtime/python-win/ 内为 python-build-standalone 解压内容）
Source: "..\..\runtime\python-win\*"; DestDir: "{app}\runtime\python"; Flags: ignoreversion recursesubdirs createallsubdirs
; FFmpeg + ffprobe
Source: "..\..\runtime\ffmpeg-win\*"; DestDir: "{app}\runtime\ffmpeg"; Flags: ignoreversion recursesubdirs createallsubdirs
; 项目源码（排除 .git 等）
Source: "..\..\source\*"; DestDir: "{app}\app"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: ".git,*.pyc,__pycache__,resource,.storyline\models"
; 静态资源（字体、BGM、emoji 等）打入 app\resource，与 config.toml 相对路径对齐
Source: "..\..\resources\*"; DestDir: "{app}\app\resource"; Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist
; 启动器
Source: "..\..\launcher\start.bat"; DestDir: "{app}\launcher"; Flags: ignoreversion
; GUI 启动器（托盘 + 原生窗口，快捷方式入口）与应用图标
Source: "..\..\launcher\app_tray.py"; DestDir: "{app}\launcher"; Flags: ignoreversion
Source: "..\..\assets\icon.ico"; DestDir: "{app}\assets"; Flags: ignoreversion skipifsourcedoesntexist

[Dirs]
; 运行期需要写入的目录（模型下载、输出），安装到 Program Files 时授予普通用户写权限
Name: "{app}\app\.storyline"; Permissions: users-modify
Name: "{app}\app\outputs"; Permissions: users-modify
Name: "{app}\app\outputs\media"; Permissions: users-modify

[Icons]
; GUI 启动器经 pythonw 运行，无控制台窗口
Name: "{group}\{#MyAppName}"; Filename: "{app}\runtime\python\pythonw.exe"; Parameters: """{app}\launcher\app_tray.py"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\icon.ico"
Name: "{group}\卸载 {#MyAppName} / Uninstall"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\runtime\python\pythonw.exe"; Parameters: """{app}\launcher\app_tray.py"""; WorkingDir: "{app}"; IconFilename: "{app}\assets\icon.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\runtime\python\pythonw.exe"; Parameters: """{app}\launcher\app_tray.py"""; WorkingDir: "{app}"; Description: "立即启动 {#MyAppName} / Launch now"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 清理运行期生成的模型和输出
Type: filesandordirs; Name: "{app}\app\.storyline\models"
Type: filesandordirs; Name: "{app}\app\outputs"
Type: filesandordirs; Name: "{app}\app\.storyline\logs"
