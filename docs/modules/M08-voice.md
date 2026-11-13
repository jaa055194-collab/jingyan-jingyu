# M08 · voice：音色工作台、语音消息、通话、语音房

> 依据：v4.2 FR-19、FR-30～34、AC-11/13/21；口径 C-1。依赖：models、ai_core。

## 要写的文件

```text
apps/host/lib/src/voice/
  voice_module.dart        name 'voice'
  voice_profiles.dart      音色档案：导入质检、同意记录、revision、回滚
  voice_gateway.dart       TTS/ASR 统一入口；客户端只拿短期票据
  calls.dart               1v1 通话状态机：call_id 幂等、30s 未接、打断
  vision_guard.dart        抽帧脱敏管线入口（FR-33）
  voice_rooms.dart         群语音房：进出、旁听转写候选、点名
apps/host/test/voice_test.dart
```

## 规则

1. 不做本地 TTS。每个 AI 固定 `provider + model + voice_id + 参数`；厂商故障只降文字，**不换音色、不跨厂商**（FR-30）。
2. 音色导入：10–30s、单声道、≥16kHz；必须带 `consent_ref`；删除时保留同意记录，不保留音频明文（FR-31）。
3. 客户端永不接触厂商 key；试听与合成都走宿主，客户端只拿 5 分钟有效的会话票据（NFR-06）。
4. 通话：服务端只推音频 + 语义口型/表情参数，客户端本地渲染形象；原始音视频不落盘（FR-32）。
5. 打断：取消 LLM、清 TTS 队列、停播；被截断的话标"中途被打断"，不写成完整发言。
6. 视觉：只在开口、打断、帧差超阈值、用户说"你看这个"时抽 1–3 帧；先人脸像素化、文字 PII 抹除、去 EXIF，再送视觉模型；画面理解不落历史、不作事实（FR-33）。
7. 语音房：不录存音频；AI 旁听转写进群记忆候选（pending）；旁听范围与确认人由房主设定（口径 C-1）。

## 验收

- [ ] AC-11 同一 AI 只有一个音色档案；厂商故障时回复降为文字且 voice_id 不变。
- [ ] AC-11 参数变更产生新 revision，可回滚；变更只在句边界生效。
- [ ] AC-13 打断后 LLM 请求被取消、TTS 队列为空；被截断发言带标记。
- [ ] AC-13 关闭视觉理解后通话仍可纯语音；送出的帧都经过脱敏（用假视觉模型断言输入）。
- [ ] FR-32 30s 未接转未接来电；同一 `call_id` 重复发起不产生第二通。
- [ ] AC-21 语音房可进出；旁听转写进候选且为 pending；宿主磁盘上没有房内音频文件。
