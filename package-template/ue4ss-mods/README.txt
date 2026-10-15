附加 UE4SS Mod（2.5.0 起）

把其他基于 UE4SS 的 Mod 文件夹整个放到这里，例如：
  ue4ss-mods\SomeMod\Scripts\main.lua   （Lua Mod）
  ue4ss-mods\SomeMod\dlls\main.dll      （C++ Mod）

每次启动时，这些 Mod 会和本整合包的 UE4SS 一起部署到游戏目录并启用；退出后随本包一起从游戏目录移走，
这里的原件保留不动。启动器“维护与恢复”中的“附加 Mod”按钮会打开本文件夹，并显示下次启动会加载哪些 Mod。

- 停用某个 Mod：把文件夹名改成以 _ 开头（例如 _SomeMod），或移出本文件夹。
- 文件夹名只能使用英文字母、数字和 _ . -；不能与 AC8MouseAim、AC8SourceInit、shared 同名。
- 已附带同版本 UE4SS 的 shared 库（UEHelpers），多数 Lua Mod 依赖它。
- 本包的 UE4SS 版本：3.0.1 实验版构建（e3ba1016）。其他 Mod 必须兼容这个版本，C++ Mod 尤其要用匹配的版本编译。
- 蓝图类 Mod（LogicMods）需要 BPModLoaderMod：从相同版本的 UE4SS 发布包中取出 BPModLoaderMod 文件夹放到这里，
  .pak 放到 Game\Content\Paks\LogicMods。
- 不要在游戏目录里另外安装 UE4SS（dwmapi.dll / ue4ss 文件夹），启动器会把它当作加载器冲突并拒绝启动。
- 仅限离线单人。
