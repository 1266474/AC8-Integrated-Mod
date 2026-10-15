# v2.5.0 — 安装版、自动更新与默认 WAR

**正式版。仅限离线单人，禁止带 Mod 进入线上或多人模式。** 飞控与 v2.4.2 相同（WAR v13.8 / PEACE）。

## 更新内容

- **Windows 安装版**：
  - 新增安装程序 **AC8-Integrated-Setup-v2.5.0.exe**：按用户安装，不需要管理员权限；开始菜单有 AC8 Integrated 启动器，可在 Windows“应用”中卸载。
  - 可以直接导入正在使用的便携版的设置、键位、路径和附加 Mod。
  - Steam 启动选项固定指向安装目录，以后更新不用再改。
- **从 GitHub 自动更新**：启动器“检查更新”一键更新，也可以每天自动检查。安装前核对数字签名和 SHA-256，只接受更新的正式版；保留上一版本，可以回退。
- **自动修复**：
  - 每次启动前自动核对程序文件，损坏时从本地已校验的安装包恢复。
  - “检查并修复”还会处理设置文件损坏、未清理完的会话、Steam 启动选项等问题。
  - 安全软件隔离了刚部署的 DLL 时，在启动游戏前说明；出现 `[NOT READY]` 时显示具体原因。
- **默认飞控改为 WAR**：新安装和升级后，启动时都是 WAR。以前保存为 PEACE 的设置会改为 WAR 一次；之后按 F4 切回 PEACE，或设置 `control_mode=0`，都会保留。
- **与其他 UE4SS Mod 一起使用**：
  - 把其他 UE4SS Mod 的文件夹放进 `ue4ss-mods`，每次启动随本包的 UE4SS 一起部署并启用，退出后一起移走，原件保留。
  - 启动器“附加 Mod”按钮会打开该文件夹，并显示下次启动会加载哪些 Mod、哪些被跳过及原因；控制台也会列出。
  - 附带同版本 UE4SS 的 `shared` 库（UEHelpers）。文件夹名以 `_` 开头即停用。详见 [与其他 UE4SS Mod 一起使用](EXTRA-MODS.md)。
- **飞行记录开关**：启动器新增“保存飞行记录”（默认关闭）。关闭时只保留很小的文字日志；开启后每次飞行保存 FE／Shadow 记录（约 10–15 MB／分钟），用于问题分析。
- **会话更小**：每次启动不再把 UE4SS.dll 和飞控 DLL（约 28 MB）复制进 sessions，只记录它们的哈希。
- 启动器中 F2 头瞄的说明更正为“圆环加四角括号”。

## 安装与升级

- **推荐**：运行安装程序，按提示导入便携版设置，再把显示的一行替换进 Steam 启动选项。详见 [安装版说明](APP.md)。
- **便携版**：下载完整的 **AC8-Integrated-v2.5.0-share.zip**，解压到游戏目录之外的新目录，运行 Start-GUI.cmd 或 Setup.cmd，并替换 Steam 启动选项。

## English summary

**Stable release. Offline single-player only.** Flight control is unchanged from v2.4.2 (WAR v13.8 / PEACE).

- **Windows setup program** (AC8-Integrated-Setup-v2.5.0.exe): per-user install without administrator rights, Start menu launcher, uninstall from Windows Settings > Apps, import of the portable package in use; the Steam launch option stays the same across updates.
- **Updates from GitHub**: one click in the launcher, optional daily check; the signed manifest and SHA-256 are verified, only newer stable releases are installed, the previous version is kept for rollback.
- **Self-repair**: program files are checked before every launch and restored from the cached verified package; "check and repair" also fixes unreadable settings, unfinished sessions and reports the Steam launch option. DLLs removed by security software are reported before the game starts, and `[NOT READY]` now shows the reason.
- **WAR is the default flight control.** A saved PEACE selection moves to WAR once; switching back with F4 or `control_mode=0` is kept afterwards.
- **Other UE4SS mods** in `ue4ss-mods` load with this package's UE4SS (the UE4SS `shared` library is included; `_` prefix disables a mod).
- **Flight-record switch** in the launcher, off by default; sessions no longer copy the DLLs (about 28 MB per launch).

See [the installed app (Chinese, English summary at the end)](APP.md). The portable share.zip remains available.
