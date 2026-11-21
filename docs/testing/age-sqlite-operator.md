# Windows 停机数据库备份与验证恢复

这是手动运维命令，覆盖 [FR-64](../../鲸言鲸语-需求规格-v4.2.md#L592-L595) / [AC-15](../../鲸言鲸语-需求规格-v4.2.md#L701) 的一部分。它不连接宿主 API、不安装工具、不启动或停止服务，也不改宿主配置。已有[聊天导出和预览](../phase-one/backup-restore.md)是独立功能，不可用来恢复数据库。

**恢复仅支持制作备份时的同一台 Windows 电脑和同一 Windows 用户。** `age` 解密不解除 Windows DPAPI 绑定。输入只包括 `host.sqlite` 与 `host.sqlite.kek`；附件/媒体、其他文件和运行环境不在归档中。这不是整机灾备，也没有自动调度、第二盘、云备份、30 天轮转、删除后清除或客户端入口。

## 准备

- Windows x64、项目宿主源码及其 Dart 依赖，使用与数据目录匹配的版本。命令从 `apps/host` 运行。准备自行核验过的官方 `age.exe`（测试使用 [age 1.3.2](https://github.com/FiloSottile/age/releases/tag/v1.3.2)）和 Windows 系统自带的 `tar.exe`；命令不下载这些工具，也不随安装包分发。既有 [#170 演练](age-sqlite-restore-drill.md)记录了该版本的官方 Windows x64 ZIP 摘要。`--age` 必须是可信可执行文件的绝对路径；`--tar` 默认为 `%SystemRoot%\System32\tar.exe`，只在使用其他可信 bsdtar 时显式指定。
- 先在离线位置妥善保管一个原生 age X25519 身份，并核对对应 `age1…` 收件人公钥。备份只接收公钥，支持一个收件人；不接受口令、SSH 私钥或插件身份。恢复私钥只从重定向的标准输入读取，不要粘贴到命令行、环境变量或日志，也不要把身份文件与备份打包。
- **先正常停止宿主并保持停机**，确认使用的是正确数据目录。若有 WAL、SHM 或回滚 journal 文件（即便为空），或者 SQLite/KEK 无法独占读取，备份会拒绝。不要手工删除 SQLite sidecar 来绕过检查；请先处理数据库关闭/恢复问题再重试。
- 使用由当前 Windows 用户控制、其他用户/进程不可改写的本地目录（含系统临时目录及目标的父目录）。命令拒绝 UNC、设备、重解析点、ADS 和相对路径。准备已存在的输出父目录；备份文件与恢复目标必须是全新路径，连已存在的空恢复目录也会拒绝。SQLite 文件上限 64 MiB、KEK 文件上限 64 KiB，归档以有界内存处理，需留出内存和磁盘余量。

## 备份：仅停机 SQLite 和 DPAPI 密钥文件

从 `apps/host` 在 PowerShell 运行；替换示例目录，不要把真实身份或资料写入命令记录。

```powershell
$age = 'C:\VerifiedTools\age.exe'
$source = 'D:\JingyuClosed\data'
$archive = 'D:\JingyuBackups\db-001.tar.age'
$recipient = Read-Host '输入已核验的 age 收件人公钥'
dart run tool/age_sqlite_recovery.dart backup --host-stopped `
  --data-dir $source --output $archive --recipient $recipient --age $age
if ($LASTEXITCODE -ne 0) { throw '备份未成功，保留源目录' }
```

成功输出 `integrity_check=ok` 和 `sha256=…`。把 SHA-256 **另存于可信的离线记录**，不要在恢复时把待恢复文件自己现算的哈希当作可信值。SHA-256 比较能发现文件变化，但不能在记录本身被替换时证明来源。备份用保留的只读、零共享 Windows 文件句柄取得闭合 SQLite/KEK 字节并阻止并发打开，验证 SQLite 完整性及 KEK 可解开其主 DEK，然后以标准 USTAR 和 age 收件人加密写单一密文文件。密文先写临时文件并摘要复核，再以同卷不覆盖的重命名发布。

## 恢复：仅发布到从未存在的目录

仍在同一 Windows 用户、同一电脑操作，不把目标设为现有数据目录。用离线保管的身份文件经 PowerShell 管道提供内容（不要单独运行 `Get-Content` 或把内容输出到屏幕）。只提供一个 age-keygen 原生身份，允许其 ASCII 注释行及 PowerShell 管道可能添加的一个开头 UTF-8 BOM。

```powershell
$target = 'D:\JingyuRecovery\verified-001'
$knownSha256 = Read-Host '输入建档时独立保存的原始 SHA-256'
$identityFile = Read-Host '输入离线 age 身份文件路径（不要输入私钥）'
Get-Content -LiteralPath $identityFile | dart run tool/age_sqlite_recovery.dart restore `
  --archive $archive --sha256 $knownSha256 --target $target --age $age
if ($LASTEXITCODE -ne 0) { throw '恢复未成功；不要启动或移动旧数据目录' }
```

命令先校验归档密文摘要，再验证解密结果是恰好两个已知名称的普通 USTAR 文件，不按归档路径解包。SQLite `PRAGMA integrity_check` 及 DPAPI / 主 DEK 验证通过后才把两个文件一起发布。任何已存在的目标不会被替换；身份错误、坏摘要、损坏/截断归档、非预期成员或 KEK 不匹配不发布目标目录。恢复输出 `integrity_check=ok` 时也不要覆盖旧目录；由运维人员确认内容后另行决定是否以新路径启动宿主。若遇 `sqlite_sidecar_present` 或 `source_open_or_unavailable`，先核实停机和路径，不要强删侧车文件；若遇 `digest_mismatch` 或 `age_decrypt_failed`，请核对原始记录及身份；`key_unavailable_or_mismatch` 表示当前用户/机器无法解开 KEK，或 KEK 与数据库不配套。

正常失败会清理本次创建的已知临时文件，不删除源文件、已有备份或已有目标。工具不将未加密的 tar 写到磁盘；校验时有暂存的 SQLite 与 DPAPI 保护文件（保护范围与宿主原库相同，不能当作整库密文）。异常中止可遗留 `.jingyu-age-*` 暂存；使用私有且受保护的目录，并由运维人员确认归属后按本地安全流程处理，不将暂存对外分享。普通删除不等于安全擦除。

## 隔离验证复现

从 `apps/host` 运行。使用核验过的工具路径；不需要启动现有宿主。默认套件运行前置拒绝、Windows 文件句柄、归档格式等测试；真实 age 流程为 opt-in。夹具生成短期合成身份，只用内存/管道，不落盘，不打印身份或消息；完全不使用真实用户数据。

```powershell
$env:JINGYU_TEST_AGE = 'C:\VerifiedTools\age.exe'
$env:JINGYU_TEST_AGE_KEYGEN = 'C:\VerifiedTools\age-keygen.exe'
$env:JINGYU_TEST_TAR = Join-Path $env:SystemRoot 'System32\tar.exe'
$env:JINGYU_RUN_AGE_OPERATOR_DRILL = '1'
$env:JINGYU_RUN_AGE_RESTORE_DRILL = '1'
dart pub get --offline
dart analyze --fatal-infos
dart test --concurrency=1 --reporter expanded test/age_sqlite_operator_test.dart test/age_sqlite_restore_drill_test.dart test/storage_crypto_test.dart
```

2026-11-21，在 Windows x64、Dart 3.14.0、age 1.3.2、系统 bsdtar 3.8.9 下，宿主静态分析无问题，上述定向套件 **18 项通过、无跳过**（9 项新运维测试、1 项 #170、8 项既有存储加密测试）。

[运维命令测试](../../apps/host/test/age_sqlite_operator_test.dart)用真实临时宿主的停机数据创建密文，恢复到全新目录，比较两个成员的 SHA-256，重开宿主验证 `integrity_check=ok` 与认证同步读回唯一一条合成消息。反例覆盖错误身份、错误摘要、重算摘要的篡改密文、截断密文、额外成员及来自同一用户另一数据库的 DPAPI KEK；检查目标目录始终未出现。独立前置检查使用真实 SQLite 打开但无 WAL 的连接，以及零字节 WAL；还检查既有文件/目录保护、发布时目标被抢占、加密失败不发布，以及 USTAR 路径/链接/尾部内容拒绝。这些是合成环境的手动数据库快照验证，不是实际部署恢复或完整 AC-15 验收。
