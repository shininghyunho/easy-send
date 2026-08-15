import 'dart:io';

import 'package:easy_send_core/easy_send_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

enum SendPhase { waitingApproval, uploading, done, error, canceled }

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

/// 송신 1회의 실행자 — 동시 1건, 진행률과 결과를 상태로 노출한다.
class SendController extends Notifier<SendProgress?> {
  SendClient? _client;
  PreparedSession? _session;
  DiscoveredDevice? _target;
  bool _cancelRequested = false;

  @override
  SendProgress? build() => null;

  Future<void> send(DiscoveredDevice target, List<File> files) async {
    if (state?.inFlight == true) return;
    final controller = ref.read(appControllerProvider);
    final metas = <String, FileMeta>{
      for (var i = 0; i < files.length; i++)
        'f$i': FileMeta(
          name: files[i].uri.pathSegments.last,
          size: files[i].lengthSync(),
          mime: 'application/octet-stream',
        ),
    };
    final totalBytes = metas.values.fold(0, (sum, m) => sum + m.size);
    final client = SendClient(
      address: target.address.address,
      port: target.info.port,
      expectedFingerprint: target.info.fingerprint,
    );
    _client = client;
    _session = null;
    _target = target;
    _cancelRequested = false;
    state = SendProgress(
      targetAlias: target.info.alias,
      fileCount: files.length,
      fileIndex: 0,
      currentFileName: metas['f0']!.name,
      sentBytes: 0,
      totalBytes: totalBytes,
      phase: SendPhase.waitingApproval,
    );

    try {
      final session = await client.prepareUpload(controller.self, metas);
      _session = session;
      var completedBytes = 0;
      var lastEmitted = 0;
      for (var i = 0; i < files.length; i++) {
        final meta = metas['f$i']!;
        state = state!.copyWith(
          phase: SendPhase.uploading,
          fileIndex: i,
          currentFileName: meta.name,
        );
        await client.uploadFile(session, 'f$i', files[i],
            onProgress: (sent, total) {
          final overall = completedBytes + sent;
          // 청크마다 리빌드하지 않도록 1MB 단위로만 반영
          if (overall - lastEmitted >= 1 << 20 || sent == total) {
            lastEmitted = overall;
            state = state!.copyWith(sentBytes: overall);
          }
        });
        completedBytes += meta.size;
      }
      state = state!.copyWith(phase: SendPhase.done, sentBytes: totalBytes);
    } on TransferException catch (e) {
      if (_cancelRequested) {
        state = state!.copyWith(phase: SendPhase.canceled, message: '전송을 취소했습니다');
      } else {
        state = state!.copyWith(phase: SendPhase.error, message: _messageFor(e));
      }
    } on FingerprintMismatchException {
      state = state!.copyWith(
          phase: SendPhase.error,
          message: '기기 지문이 광고된 값과 다릅니다 — 연결을 차단했습니다');
    } catch (e) {
      if (_cancelRequested) {
        state = state!.copyWith(phase: SendPhase.canceled, message: '전송을 취소했습니다');
      } else {
        state = state!.copyWith(phase: SendPhase.error, message: '$e');
      }
    } finally {
      client.close();
      _client = null;
      _session = null;
      _target = null;
    }
  }

  Future<void> cancel() async {
    _cancelRequested = true;
    final session = _session;
    final target = _target;
    _client?.close();
    // 세션이 이미 열렸으면 수신 측 상태도 정리 (닫힌 클라이언트로는 못 보냄)
    if (session != null && target != null) {
      final cleanup = SendClient(
        address: target.address.address,
        port: target.info.port,
        expectedFingerprint: target.info.fingerprint,
      );
      try {
        await cleanup.cancel(session);
      } catch (_) {}
      cleanup.close();
    }
  }

  void dismiss() {
    if (state?.inFlight == true) return;
    state = null;
  }

  String _messageFor(TransferException e) {
    if (e.declined) return '상대가 거절했습니다';
    if (e.busy) return '상대가 다른 전송을 진행 중입니다';
    if (e.approvalTimedOut) return '승인 대기 시간(60초)을 초과했습니다';
    if (e.invalidSession) return '세션이 취소되었습니다';
    return '수신 측 오류 (HTTP ${e.statusCode})';
  }
}
