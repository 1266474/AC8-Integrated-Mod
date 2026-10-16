# 与其他 UE4SS Mod 一起使用（2.5 起）

[返回说明首页](../README.md) · [安装](INSTALL.md) · [已知限制](LIMITATIONS.md)

整合包每次启动时，把自带的 UE4SS 部署到游戏目录；退出后再整个移走，让游戏目录恢复原版。因此不要在游戏目录里另外安装 UE4SS，其他 UE4SS Mod 请在启动器的 **附加 Mod** 中添加，由整合包一起加载。

## 在启动器中管理

在启动器“维护与恢复”中点击 **附加 Mod**，打开管理窗口：

- **添加**：点击“添加 zip…”选择下载的 Mod 压缩包，或点击“添加文件夹…”选择解压后的文件夹；也可以把 zip 或文件夹直接拖进窗口。
  - 会自动找到含 `Scripts\main.lua`（Lua Mod）或 `dlls\main.dll`（C++ Mod）的文件夹，常见的 `Mods\SomeMod\…`、`ue4ss\Mods\SomeMod\…` 打包方式都可以；一个压缩包里有多个 Mod 时一起添加。
  - 添加前会列出将要安装的 Mod 和注意事项，确认后才安装。压缩包里的 UE4SS 本体（`dwmapi.dll`、`UE4SS.dll`）和 `.pak` 资源不会安装。
  - 已有同名 Mod 时会替换，旧版本移到 `ue4ss-mods-removed`，原来的启用／停用状态保持不变。
  - 只支持 zip；7z、rar 请先解压，再用“添加文件夹…”。
- **启用／停用**：每个 Mod 右侧的按钮，停用就是在文件夹名前加 `_`。
- **删除**：Mod 移到 `ue4ss-mods-removed`，需要时可以移回 `ue4ss-mods` 恢复。
- **打开文件夹**：直接查看 `ue4ss-mods`（便携版在整合包目录下，安装版在安装目录的 `data` 下）。

列表会显示每个 Mod 下次启动是否加载，不加载时说明原因。改动在下次启动时生效。从 Steam 启动后，控制台会显示 `EXTRA UE4SS MODS: …`，这些 Mod 排在本包自带的 Mod 之后加载。

也可以手动把 Mod 文件夹放进 `ue4ss-mods`，保持 UE4SS 的标准结构（`SomeMod\Scripts\main.lua` 或 `SomeMod\dlls\main.dll`）。

退出游戏后，附加 Mod 和本包的 UE4SS 一起从游戏目录移走；`ue4ss-mods` 里的原件保留不动。

## 规则

- **停用**：把文件夹名改成以 `_` 开头（例如 `_SomeMod`），或者移出 `ue4ss-mods`。
- **文件夹名**：只能使用英文字母、数字和 `_ . -`，不能与 `AC8MouseAim`、`AC8SourceInit`、`shared` 同名。
- **跳过的情况**：缺少 `Scripts\main.lua` 和 `dlls\main.dll` 的文件夹，以及包含文件系统链接（符号链接、目录联接）的文件夹，都会被跳过，并说明原因。
- **共享库**：已附带同版本 UE4SS 的 `shared` 库（UEHelpers），多数 Lua Mod 依赖它。

## 兼容性

- **UE4SS 版本**：本包使用 UE4SS 3.0.1 实验版构建（`e3ba1016`）。其他 Mod 必须兼容这个版本；C++ Mod 尤其要用匹配的 UE4SS 版本编译，否则可能无法加载或导致游戏崩溃。
- **UE4SS 设置**：沿用本包的 `UE4SS-settings.ini`，控制台和 GUI 控制台默认关闭，热重载关闭。依赖这些功能的 Mod 可能表现不同。
- **蓝图类 Mod（LogicMods）**：需要 BPModLoaderMod，本包没有附带。可以把相同版本 UE4SS 发布包里的 `BPModLoaderMod` 用“添加文件夹…”添加；Mod 的 `.pak` 需要按其说明手动放到 `Game\Content\Paks\LogicMods`。
- **Pak Mod**：只替换资源的 `.pak`／`.utoc`／`.ucas`（例如 `~mods`）由游戏自身加载，不经过 UE4SS，整合包不会改动它们。
- **按键冲突**：其他 Mod 使用的快捷键可能与本包的 F1–F10、Alt+F7、Ctrl／Alt+PageUp 等冲突，请自行调整。
- **出现问题时**：先把附加 Mod 停用（文件夹名加 `_`）再试，以确认问题是否来自附加 Mod。反馈时请注明你加入了哪些 Mod。

仅限离线单人。
