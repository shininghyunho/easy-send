import 'dart:async';

import 'package:easy_send_core/easy_send_core.dart';
import 'package:flutter/material.dart';

import 'format.dart';

Future<bool?> showApprovalDialog(BuildContext context, TransferRequest request) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ApprovalDialog(request: request),
  );
}

/// 수신 승인 다이얼로그 — 알던 기기여도 항상 뜬다 (PRD D4).
class ApprovalDialog extends StatefulWidget {
  const ApprovalDialog({super.key, required this.request});

  final TransferRequest request;

  @override
  State<ApprovalDialog> createState() => _ApprovalDialogState();
}

class _ApprovalDialogState extends State<ApprovalDialog> {
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    // 코어가 60초에 408로 응답하므로 다이얼로그도 함께 닫는다
    _timeout = Timer(const Duration(seconds: 60), () {
      if (mounted) Navigator.of(context).pop(false);
    });
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final totalBytes =
        request.files.values.fold(0, (sum, m) => sum + m.size);
    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text('${request.sender.alias}의 전송 요청')),
          if (request.isNewDevice)
            Chip(
              label: const Text('새 기기'),
              labelStyle: const TextStyle(fontSize: 12),
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('파일 ${request.files.length}개 · ${formatBytes(totalBytes)}'),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final meta in request.files.values)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.insert_drive_file_outlined),
                      title: Text(meta.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: Text(formatBytes(meta.size)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '지문 ${shortFingerprint(request.sender.fingerprint)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('거절'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('승인'),
        ),
      ],
    );
  }
}

/// 송신 측 최초 신뢰 확인 (PRD 4.4 TOFU 송신 규칙).
Future<bool?> showTrustConfirmDialog(
    BuildContext context, DeviceInfo target) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('새 기기'),
      content: Text(
          '${target.alias}에 처음 보냅니다.\n지문 ${shortFingerprint(target.fingerprint)}\n이 기기를 신뢰할까요?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('신뢰'),
        ),
      ],
    ),
  );
}
