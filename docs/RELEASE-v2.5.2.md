# v2.5.2 — 附加 Mod 修复

**正式版。仅限离线单人，禁止带 Mod 进入线上或多人模式。** 飞控与 v2.5.1 相同（WAR v13.8 / PEACE）。

## 更新内容

- **附加 Mod 完整安装自带资源**：Mod 文件夹里自带的 `.pak`／`.utoc`／`.ucas` 资源现在随 Mod 一起安装。像 PW-MkI 这样由自身加载器挂载飞机资源的 Mod 可以直接用“附加 Mod”→“添加 zip…”安装。压缩包里的 UE4SS 本体仍不会安装，Mod 文件夹以外的游戏 Pak 仍需按 Mod 说明处理。
- **附加 Mod 不再重复备份**：退出游戏时，部署到游戏目录的附加 Mod 与 `ue4ss-mods` 中的原件逐个核对，一致的直接移除；只有 Mod 运行中新写或改动的文件进入 `cleanup-backups`。大型 Mod 不会再让备份每次增长。

## 安装与升级

- **安装版**：在启动器右上角点击“检查更新”。
- **新安装**：下载 **AC8-Integrated-Setup-v2.5.2.exe** 运行；便携版下载 **AC8-Integrated-v2.5.2-share.zip**。

## English summary

**Stable release. Offline single-player only.** Flight control is unchanged from v2.5.1.

- Extra UE4SS mods keep the `.pak`/`.utoc`/`.ucas` files inside their own folders (mods such as PW-MkI mount them through their own loader), so they can be added from a zip in the launcher. The zip's own UE4SS loader is still not installed.
- Deployed extra mods identical to the originals in `ue4ss-mods` are removed at the end of a session instead of being archived in `cleanup-backups`; only files the mod wrote or changed are kept.

Installed copies update from the launcher (check for updates).
