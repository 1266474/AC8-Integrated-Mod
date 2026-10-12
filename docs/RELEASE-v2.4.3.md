# v2.4.3 — 飞行记录开关

**正式版。仅限离线单人，禁止带 Mod 进入线上或多人模式。** 本版包含 v2.4.2 的全部内容，飞控与 v2.4.2 相同。

## 更新内容

- **飞行记录开关**：
  - 启动器“维护与恢复”中新增“保存飞行记录”勾选框，对应 `MouseAim-Settings.ini` 的 `flight_recording`，下次启动生效。
  - **默认关闭**：只保留很小的文字日志。开启后，每次飞行会在 sessions 中保存 FE／Shadow 记录（约 10–15 MB／分钟，单次最多约 200 MB），用于问题分析。
  - 关闭时，退出后的可选分析会自动跳过，并提示原因。
- **会话不再复制 DLL**：每次启动不再把 UE4SS.dll 和飞控 DLL（约 28 MB）复制进 sessions，只在 `runtime-dll-hashes.json` 中记录它们的哈希。日志和设置照常保存。
- 启动器“游戏内功能”中 F2 头瞄的说明更正为“圆环加四角括号”。

## 升级

与 v2.4.2 相同：
- 下载完整的 **AC8-Integrated-v2.4.3-share.zip**，解压到游戏目录之外的新目录；
- 运行 Start-GUI.cmd 或 Setup.cmd，并把新生成的 Steam 启动选项替换进去；
- 不要复制旧版的 DLL、设置或 sessions。

以前版本留下的 sessions 不会被自动删除；不再需要时可以手动删除旧的会话文件夹，但其中含有存档备份，删除前请确认。

## English summary

**Stable release. Offline single-player only.** Contains everything from v2.4.2; flight control is unchanged.

- **Flight-record switch.**
  - A "save flight records" checkbox in the launcher (maintenance), stored as `flight_recording` in MouseAim-Settings.ini and applied at the next launch.
  - **Off by default**: only the small text log is kept. When on, every flight saves FE/Shadow records in sessions (about 10-15 MB per minute, at most about 200 MB per flight) for diagnostics.
  - With records off, the optional post-flight analysis is skipped with a note.
- **Sessions no longer copy the DLLs.** UE4SS.dll and the mod DLL (about 28 MB) are no longer copied into every session; their hashes are recorded in `runtime-dll-hashes.json`. Logs and settings are archived as before.
- The launcher's F2 HMD description now matches the bracketed ring.

Install as before: extract the complete AC8-Integrated-v2.4.3-share.zip to a new folder outside the game, run Start-GUI.cmd or Setup.cmd and replace the Steam launch option. Old sessions are not deleted automatically; they contain save backups, so check before removing them.
