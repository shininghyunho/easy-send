import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'rust/api/easy_send.dart';

class SendProgress {
  const SendProgress({
    required this.targetAlias,
    required this.fileCount,
    required this.fileIndex,
    required this.currentFileName,
    required this.sentBytes,
    required this.totalBytes,
    required this.phase,
    this.message,
  });

  final String targetAlias;
  final int fileCount;
  final int fileIndex;
  final String currentFileName;
  final int sentBytes;
  final int totalBytes;
  final SendPhase phase;
  final String? message;

  bool get inFlight =>
      phase == SendPhase.waitingApproval || phase == SendPhase.uploading;

  SendProgress copyWith({
    int? fileIndex,
    String? currentFileName,
    int? sentBytes,
    SendPhase? phase,
    String? message,
  }) =>
      SendProgress(
        targetAlias: targetAlias,
        fileCount: fileCount,
        fileIndex: fileIndex ?? this.fileIndex,
        currentFileName: currentFileName ?? this.currentFileName,
        sentBytes: sentBytes ?? this.sentBytes,
        totalBytes: totalBytes,
        phase: phase ?? this.phase,
        message: message ?? this.message,
      );
}

/// 송신 1회의 실행자 — 전송 자체는 Rust(send_files)가 수행하고
/// 여기서는 이벤트 스트림을 UI 상태로 매핑만 한다. 동시 1건.
class SendController extends Notifier<SendProgress?> {
  StreamSubscription<SendEvent>? _sub;

  @override
  SendProgress? build() => null;

  Future<void> send(DeviceSnapshot target, List<File> files) async {
    if (state?.inFlight == true) return;
    state = SendProgress(
      targetAlias: target.alias,
      fileCount: files.length,
      fileIndex: 0,
      currentFileName: files.first.uri.pathSegments.last,
      sentBytes: 0,
      totalBytes: 0,
      phase: SendPhase.waitingApproval,
    );
    await _sub?.cancel();
    _sub = sendFiles(
      target: SendTarget(
        ip: target.ip,
        port: target.port,
        fingerprint: target.fingerprint,
        alias: target.alias,
      ),
      paths: files.map((f) => f.path).toList(),
    ).listen(_onEvent, onError: (Object e) {
      state = state?.copyWith(phase: SendPhase.failed, message: '$e');
    });
  }

  void _onEvent(SendEvent event) {
    final current = state;
    if (current == null) return;
    switch (event.phase) {
      case SendPhase.waitingApproval:
        break; // send()에서 이미 반영
      case SendPhase.uploading:
        state = SendProgress(
          targetAlias: current.targetAlias,
          fileCount: event.fileCount,
          fileIndex: event.fileIndex,
          currentFileName: event.fileName,
          sentBytes: event.sentBytes,
          totalBytes: event.totalBytes,
          phase: SendPhase.uploading,
        );
      case SendPhase.done:
        state = current.copyWith(
            phase: SendPhase.done, sentBytes: current.totalBytes);
      case SendPhase.failed:
        state = current.copyWith(
            phase: SendPhase.failed, message: event.message ?? '전송 실패');
      case SendPhase.canceled:
        state =
            current.copyWith(phase: SendPhase.canceled, message: '전송을 취소했습니다');
    }
  }

  Future<void> cancel() => sendCancel();

  void dismiss() {
    if (state?.inFlight == true) return;
    state = null;
  }
}
