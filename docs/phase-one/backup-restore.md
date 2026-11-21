# 备份与恢复：现状审计

**本次交付不提供生产用加密备份或宿主数据恢复。** 现有功能可导出本人有权读取的聊天记录（明文 JSON），并可在 Windows 本机校验和预览该导出文件。导出不是整库备份，文件也不受应用锁保护。以下不代表后续版本排期。

审计基线：本地提交 `38cd86c8f3a5c5e8b29a6d997bd02a2790400e96`，树 `3478ae317ae296f252ac44e7aade2aa0ca96fc93`，与交付计划记录的 `main` `d9dc55d5cad6042bc6f3b3fe7da9b38cf15606c3` 同树。本轮不访问远端、不修改生产代码或安装包，只对隔离夹具执行复核。

## 已有能力与证据

| 能力 | 已有行为与边界 |
|---|---|
| 聊天导出（FR-65 / AC-29 子集） | 在「设置 → 配额与生命周期状态 → 导出 → 保存到文件」保存 v1 JSON。宿主[导出数据源](../../apps/host/lib/src/lifecycle/chat_history_export_source.dart#L76-L92)只读取当前登录账号有权访问的聊天记录，包含会话 JSONL、清单和 SHA-256；超限拒绝而非截断，不含人格、记忆和附件内容。客户端本机保存上限 4 MiB；[保存证据](../../apps/client_flutter/evidence/export-save.md)不等于原生系统对话框或真机验收。 |
| 本机校验预览（FR-65 / AC-29 子集） | Windows 上校验本机 v1 导出文件的格式、声明的账号、清单和文件摘要，只展示摘要、不上传文件。校验和不证明文件来源，预览不解密、不导入、不恢复。见[预览证据](../../apps/client_flutter/evidence/backup-file-preview/README.md)。 |
| 内存导入 | 现有界面的「导入」使用内存中的导出包；默认宿主采用[内存导入落点](../../apps/host/lib/src/lifecycle/lifecycle_module.dart#L61-L73)，重启不保留。人格卡 JSON 导入是另一条流程，不是账号恢复。 |
| #170 隔离 tar+age 恢复演练（FR-64 / AC-15 子集，历史） | 提交 `6bde2769943043803eef20ed260ac2ca6ee7c562` 的[演练](../testing/age-sqlite-restore-drill.md)使用合成账号和单条消息，停止宿主后打包 SQLite 与 DPAPI 保护的 KEK，再以 age 加密。夹具不接受已存在的目标目录；错误 age 身份、坏摘要及重算摘要后的篡改密文均被拒绝，不创建目标目录。成功时在干净目录启动宿主，`PRAGMA integrity_check` 返回 `ok`，且经认证读回同一消息。历史记录为 Windows x64 / Dart 3.14 / age 1.3.2 下演练和相邻存储测试合跑 19 项通过，不是本轮运行结果。 |

## 尚未交付

- [FR-64](../../鲸言鲸语-需求规格-v4.2.md#L592-L595) 要求每日快照、tar+age 收件人公钥加密、离线保管私钥、第二块物理盘、30 天轮转，以及定期恢复演练；远端存储是可选项，若启用则须只上传密文并校验远端 SHA-256。当前没有对应的生产创建、轮转和恢复流程，媒体清理预览不等同备份轮转。
- #170 只验证停机快照和同一台机器、同一 Windows 用户下的恢复。解密归档不能让不同账号或机器解开 DPAPI 保护的 KEK。夹具未覆盖运行中快照、附件 blob、人格和记忆计数、或真实部署的恢复操作。既有夹具中的拒绝测试也不能替代生产恢复工具的非空目标、错误密钥和损坏包无写入验收。
- 完整账号导出与持久导入尚未交付，轮转后从快照中清除已删除账号数据也未验证。不应宣称达到 [AC-15](../../鲸言鲸语-需求规格-v4.2.md#L701) 或 [AC-29](../../鲸言鲸语-需求规格-v4.2.md#L715)。

## 本次定向复核

2026-11-21，Windows x64、Dart 3.14.0、Flutter 3.50.0。宿主 **39 通过、1 跳过**；Flutter **57 通过**；宿主和客户端分析均无问题。

```powershell
# apps/host
dart analyze --fatal-infos
dart test --reporter expanded test/age_sqlite_restore_drill_test.dart test/export_import_test.dart test/default_host_chat_export_test.dart test/chat_history_export_source_test.dart

# apps/client_flutter
flutter analyze --no-pub
flutter test --no-pub --reporter expanded test/lifecycle_api_export_test.dart test/lifecycle_export_file_test.dart test/backup_file_preview_test.dart test/backup_quota_screen_test.dart test/backup_quota_actions_test.dart test/lifecycle_backup_preview_route_test.dart
```

跳过项是 #170：未配置演练的 opt-in 环境且 PATH 无 `age`，工单工作区也未发现可执行文件；未安装或下载 age，未重跑恢复。此次只验证既有导出/导入和预览的定向用例，不是整仓或设备验收。
