# 插件规范 v1

> 代码：`packages/jingyu_client_kit/lib/src/plugin.dart`、`plugin_host.dart`；测试：`test/client_kit_test.dart`。
> 宿主侧扩展不走插件，走 `HostModule`（见 `docs/architecture/01-layering.md` §5）。

## 1. 插件由什么组成

```text
plugins/<plugin-id>/
  plugin.json        清单（必需）
  lib/plugin.dart    导出一个 ClientPlugin 实现
  assets/            随插件分发的素材（可选，需署名，见 02-assets.md）
  test/              插件自测（必需）
  README.md          做什么、需要什么能力、怎么验收
```

## 2. plugin.json

```json
{
  "id": "jingyu.room.generator",
  "name": "房间生成",
  "version": "0.1.0",
  "apiVersion": 1,
  "capabilities": ["roomScene", "modelInvoke"],
  "platforms": ["android", "windows"],
  "hostOnly": false,
  "license": "MIT",
  "assetCredits": []
}
```

| 字段 | 规则 |
|---|---|
| `id` | 小写反向域名，至少两段，例如 `jingyu.slash.draw`。全局唯一。 |
| `version` | 语义化版本 `x.y.z`。 |
| `apiVersion` | 必须等于宿主 `pluginApiVersion`（当前 1），否则拒绝加载。 |
| `capabilities` | 只能从下表选。**没声明的能力运行时一律拿不到**。 |
| `platforms` | 只允许 `android`、`windows`。 |
| `hostOnly` | `true` 表示只在宿主机客户端加载（如 Live2D `.moc3` 导入，FR-38/39）。 |
| `assetCredits` | 每条第三方素材一行署名，CC 素材必填。 |

解析失败直接拒绝，不做宽松兜底。

## 3. 能力与扩展点

| 能力 | 解锁的登记方法 / 上下文方法 | 说明 |
|---|---|---|
| `slashCommands` | `addSlashCommand` | FR-60。`requiresAiCapability` 未绑定时自动隐藏。 |
| `messageRenderer` | `addMessageCard(cardType, renderer)` | 按消息 body 的 `cardType` 渲染。 |
| `settingsPage` | `addSettingsSection(title, builder)` | 设置页分区。 |
| `roomScene` | `addRoomGenerator` | 3D 房间生成与家具（FR-35，需求方第 13 条）。 |
| `sendMessage` | `context.sendText` | 以当前用户身份发送，仍走发件箱与幂等。 |
| `readConversation` | （M11 接入） | 只读，受服务端可见性约束。 |
| `modelInvoke` | （M05/M11 接入） | 调宿主模型能力，计入该 AI 预算（FR-48/58）。 |
| `localStorage` | `context.storage` | 按插件 id 隔离的键值存储。 |

## 4. 生命周期与隔离

1. 宿主读 `plugin.json` → 校验 API 版本、平台、`hostOnly`、id 是否重复。
2. 调 `activate(registrar)`。插件在这里登记贡献，不得做阻塞 IO。
3. 登记未声明的能力 → 抛错 → **本次已登记的贡献全部回滚**，插件不加载，错误进 `PluginHost.errors`。
4. 斜杠指令或消息卡片与已有的冲突 → 后加载者失败。
5. 一个插件失败不影响其他插件。
6. 退出时逆序 `deactivate()`，需幂等。

## 5. 插件不能做的事

- 不能直接访问网络。要出站，走宿主接口（宿主会过 `UrlGuard`，NFR-05）。
- 不能拿到 token、API key、其他插件的存储。
- 不能在闪照、私密动态、群消息上调用外部模型（需求方续表第 2 条）。
- 不能下载或执行代码。房间生成器只产出布局数据（`RoomLayout`）。

## 6. 写一个插件的最小例子

```dart
class DrawPlugin extends ClientPlugin {
  @override
  final manifest = const PluginManifest(
    id: 'jingyu.slash.draw',
    name: '画图指令',
    version: '0.1.0',
    apiVersion: pluginApiVersion,
    capabilities: {PluginCapability.slashCommands, PluginCapability.sendMessage},
  );

  @override
  Future<void> activate(PluginRegistrar r) async {
    r.addSlashCommand(SlashCommand(
      name: '画图',
      description: '让她画一张图',
      requiresAiCapability: 'image_gen',
      run: (args, ctx) async {
        await ctx.sendText('<当前会话>', '/画图 $args');
        return null;
      },
    ));
  }
}
```

验收：插件目录下 `dart test` 通过；在 `PluginHost` 上加载成功；去掉清单里任一能力后加载失败。
