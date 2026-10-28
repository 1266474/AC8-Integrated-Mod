# BLMU：MSL 追踪与 QAAM 转向参数

2026-10-28 第三层修订，基于已部署第二版。当前完整导弹增强配置中 MSL 的 `HomingForesightAmount=1.0`；QAAM 的 `MaxRotationAngle=150`、`MaxHomingAngle=160`。BLMU 采用这三个参数，覆盖第二版的 0.9 预判值。此处沿用游戏原生转向限制，不将它解释为固定 G 值或新增严格比例导航制导律。

仅修改 PW 私有 BLMU 和其僚机变体；保留速度、弹药、装填、齐射和锁定选择设置。多字段写入前验证，任意写入/读回失败尝试恢复所有字段。初始化钩子、载荷 CDO 和低频池审计沿用第二版机制。

退出游戏、等待启动器清理，按 README 完成前两层后：

```powershell
python tools/deploy_blmu_qaam.py apply
python tools/deploy_blmu_qaam.py check
```

默认适配标准用户目录安装。工具校验第二版完整状态、备份原文件和第二版部署记录，再同步持久 Lua、包说明和校验清单。原生 DLL 无需重编译。

回退本层：`python tools/deploy_blmu_qaam.py rollback`。之后才可继续回退第二版和第一版；保留各层 results 与 backups。工具拒绝覆盖未知修改。

验证：本机共 62 项 Python 自动测试通过，包含未知字段拒绝、多字段写入失败恢复、池化重用、私有类范围和原有部署事务；实际本层回滚后重新应用检查通过，包校验通过。未启动游戏，实际弹道/命中验收待完成。本修订不表示 PW 卡顿已修复。
