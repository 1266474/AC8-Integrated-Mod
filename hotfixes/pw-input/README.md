# PW-MkI RGL 与输入卡顿候选修订

此目录提供基于 AC8 Integrated v2.5.2 的本地兼容修订工具，适用于游戏构建 **25201480**。本次先交付部署补丁与源码，**真实游戏射击、伤害和性能对照留待后续单独验收**；这是候选修订，不是上游正式版。只用于离线单人。

## 改动

- PW-MkI 1.2.0 的磁轨炮 Lua 从普通 MSL 读取锁定半角。整合包完整增强将其改为160°，原来的0.1–60°检查会中断充能，随后原生输入门拒绝发射。
- 同步将 Lua 和匹配原生模块的上限改为180°，继续读取实际MSL角度，允许160°增强值；保留充能、装填、身份和弹药检查，地面圈内目标窗口保持原逻辑。
- 鼠标输入生产者与完整飞控锁分离，保留成对XY队列、生命周期清空与游戏帧消费。补充原生阶段和完整Lua回调耗时统计，用于定位整画面卡顿。
- 这些静态修复及诊断能力不能替代真实性能对照；没有实测数据时不宣称卡顿已消除或帧率提升。

## 获取原始文件与构建

1. 从原作者取得 PW-MkI 1.2.0，并使用自己的合法游戏及匹配的 v2.5.2 安装。此仓库不提供 PW DLL、资源包或完整载荷。
2. 在配置好 MSVC x64 C++20 与 Windows SDK 的终端运行仓库根目录下的 `native\build.cmd`。编译产物为 `native\build\ac8_mouse_aim_010.dll`，不提交到Git。
3. 安装 Python 3.11+。工具仅依赖标准库；可选的真实Lua测试另需 `python -m pip install -r hotfixes/pw-input/requirements-test.txt`。

## 本地部署与回滚

退出游戏并等待启动器清理后，在此目录运行：

```powershell
.\apply.ps1 -PrepareOnly
.\apply.ps1
.\rollback.ps1
```

默认适配用户目录中的安装版2.5.2；其他位置使用 `-PackageRoot` 和 `-ModsRoot` 指定。`-PrepareOnly` 仅生成外部备份和PW补丁并验证原生候选，不修改已安装Mod。

原生部署会同步重编译DLL、实际变化的C++源码和Lua载荷，以及本地 `payload-manifest.json`、`FILES.sha256` 和 `package-info.json`。原官方清单保存在此目录的 `backups/` 中，更新签名检查保持原样；本地修订不会冒充上游正式发布。更新或修复安装后应重新检查版本，不能盲目重复套用旧补丁。

PW定点补丁仅接受下列原DLL SHA-256：

```
BA01A751EA0F09F1B0A2F4A73C758389B59F8AD30973293D4AC7CEC0D48C9E28
```

仅修改浮点上限60→180，文件大小及其他字节保持不变；预期结果SHA-256：

```
54FC41B68ED8F83D8FD6051DC0DE06DA2495697B0EB46B0BE49DE4063DFE415D
```

版本不符、目标被用户修改、备份被改变或游戏仍在运行时，工具拒绝部署/回滚。不要对不匹配的DLL套用偏移。

## 验证

- 部署和帧分析测试：在此目录运行 `python -m unittest discover -s tests -p "test_*.py" -v`。PW测试需先使用自己的原Mod运行 `python tools/patch_railgun.py prepare`；缺少匹配载荷或可选Lua运行时会明确跳过相关集成测试，不伪造通过。
- 原生输入并发与生命周期测试位于 `native/input_inbox_tests.cpp`；可运行 `tests/native-run-tests.ps1`，或使用上游原生测试流程。
- 磁轨炮实机回归：充能、连续发射/装填、扣弹、空中大角度获取、地面目标、无目标射击、切换普通导弹后恢复，分别确认真实射击和伤害。
- 性能对照：固定任务、机型与画质，每轮40秒依次执行静止10秒、匀速拖动10秒、快速反向10秒、静止10秒，原版与候选各三轮。PresentMon采集显式使用 `--v1_metrics`；分析器同时识别旧式 `MsBetweenPresents` 和官方2.x的 `msBetweenPresents` 表头。
- 分析命令：`python tools/analyze_frames.py baseline.csv --compare candidate.csv --output results/comparison.json`。比较p95/p99及超过50/100ms的帧数，目标拖动p99改善至少30%；相机、自由观察、F7/F8、切后台、暂停和重生也必须回归。
- 如果多个交换链占比较大，工具会标记歧义并拒绝将结果作为验收通过，可使用 `--swapchain`、`--patched-swapchain` 指定已核实的游戏主交换链。

本地 `backups/`、`results/` 和生成的 `patches/` 包含私人/第三方内容，已加入忽略规则，**禁止上传**。自动工具测试范围见 [PUBLIC-VALIDATION.md](PUBLIC-VALIDATION.md)。

## 许可与来源

保留仓库根 [LICENSE](../../LICENSE) 和 [THIRD_PARTY_NOTICES.md](../../THIRD_PARTY_NOTICES.md)；本次新增原创修订工具沿用根MIT许可，既有第三方代码保留原许可。PW-MkI及其发行版文件的权利仍属于原作者；本工具不分发或重新许可其二进制、模型、音频、纹理或其他游戏资源。测试依赖Lupa单独安装，不随仓库分发。
