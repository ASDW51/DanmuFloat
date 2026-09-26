import 'dart:io';
import 'dart:typed_data';

import 'package:danmu_float/danmu/dedup.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/danmu/proto/im_decoder.dart';

/// 单帧处理结果：本次解出的事件 + 需要回发的回执帧。
class PipelineOutput {
  const PipelineOutput({required this.events, this.ackFrame});

  final List<DanmakuEvent> events;

  /// Response.need_ack 为真时构造的回执帧，调用方负责立即回发。
  final Uint8List? ackFrame;

  bool get isEmpty => events.isEmpty && ackFrame == null;
}

/// 弹幕帧处理流水线：二进制帧 → PushFrame → gzip 解压 → Response → 事件 + 回执。
///
/// 全程不涉及网络与平台能力，可离线单测（design.md 第 4 章步骤 8~11）。
class PushFramePipeline {
  PushFramePipeline({MsgIdDeduplicator? deduplicator, this.maxMessageBytes = 1024})
      : deduplicator = deduplicator ?? MsgIdDeduplicator();

  final MsgIdDeduplicator deduplicator;

  /// 单条消息丢弃阈值：超过整条丢弃，不做部分保留（prd.md F1）
  final int maxMessageBytes;

  // 埋点计数（design.md 第 10 章，仅内存统计）
  int receivedFrames = 0;
  int receivedMessages = 0;
  int parseFailures = 0;
  int oversizedDropped = 0;
  int duplicates = 0;

  /// 处理一帧 WS 二进制报文。
  ///
  /// 任何一层解析失败只丢弃当前帧并计入 [parseFailures]，不抛出异常，
  /// 保证单条脏数据不会中断连接。
  PipelineOutput process(Uint8List frame) {
    receivedFrames++;

    final PushFrameData pushFrame;
    try {
      pushFrame = decodePushFrame(frame);
    } on Object {
      parseFailures++;
      return const PipelineOutput(events: <DanmakuEvent>[]);
    }
    if (pushFrame.payload.isEmpty) {
      return const PipelineOutput(events: <DanmakuEvent>[]);
    }

    final Uint8List decompressed;
    try {
      decompressed = Uint8List.fromList(gzip.decode(pushFrame.payload));
    } on Object {
      parseFailures++;
      return const PipelineOutput(events: <DanmakuEvent>[]);
    }

    final ResponseData response;
    try {
      response = decodeResponse(decompressed);
    } on Object {
      parseFailures++;
      return const PipelineOutput(events: <DanmakuEvent>[]);
    }

    final events = <DanmakuEvent>[];
    for (final message in response.messages) {
      receivedMessages++;
      if (message.payload.length > maxMessageBytes) {
        oversizedDropped++;
        continue;
      }
      final event = buildDanmakuEvent(
        method: message.method,
        payload: message.payload,
        envelopeMsgId: message.envelopeMsgId,
      );
      if (event == null) {
        parseFailures++;
        continue;
      }
      if (deduplicator.isDuplicate(event.msgId)) {
        duplicates++;
        continue;
      }
      if (event.text.isEmpty) continue;
      events.add(event);
    }

    return PipelineOutput(
      events: events,
      ackFrame: response.needAck
          ? encodeAckFrame(logId: pushFrame.logId, internalExt: response.internalExt)
          : null,
    );
  }
}