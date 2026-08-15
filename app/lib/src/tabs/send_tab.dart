import 'dart:io';

import 'package:easy_send_core/easy_send_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../approval_dialog.dart';
import '../format.dart';
import '../providers.dart';
import '../send_controller.dart';

class SendTab extends ConsumerWidget {
  const SendTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    final discovered = ref.watch(discoveredDevicesProvider).value ??
        controller.currentDevices;
    final progress = ref.watch(sendControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final devices = _merge(discovered, controller.manualDevices);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (progress != null) _ProgressCard(progress: progress),
            Row(
              children: [
                Text('기기', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: '새로고침',
                  icon: const Icon(Icons.refresh),
                  onPressed: controller.refreshDiscovery,
                ),
              ],
            ),
            if (devices.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Text(
                  '같은 네트워크에서 easy-send를 실행 중인 기기가 없습니다.\n'
                  '안 보이면 설정 탭에서 IP를 직접 입력하세요.',
                  textAlign: TextAlign.center,
                ),
              ),
            for (final device in devices)
              ListTile(
                leading: Icon(device.info.deviceType == DeviceType.mobile
                    ? Icons.smartphone
                    : Icons.computer),
                title: Text(device.info.alias),
                subtitle:
                    Text('${device.address.address}:${device.info.port}'),
                trailing: const Icon(Icons.send),
                onTap: () => _pickAndSend(context, ref, device),
              ),
          ],
        );
      },
    );
  }

  /// 탐색 목록 우선(주소가 최신), 수동 추가분은 지문이 겹치지 않을 때만.
  List<DiscoveredDevice> _merge(
      List<DiscoveredDevice> discovered, List<DiscoveredDevice> manual) {
    final seen = discovered.map((d) => d.info.fingerprint).toSet();
    return [
      ...discovered,
      ...manual.where((d) => seen.contains(d.info.fingerprint) == false),
    ];
  }

  Future<void> _pickAndSend(
      BuildContext context, WidgetRef ref, DiscoveredDevice device) async {
    final controller = ref.read(appControllerProvider);
    final progress = ref.read(sendControllerProvider);
    if (progress?.inFlight == true) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('전송이 이미 진행 중입니다')));
      return;
    }
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    final files =
        (result?.paths ?? const []).whereType<String>().map(File.new).toList();
    if (files.isEmpty) return;

    if (controller.trustStore.contains(device.info.fingerprint) == false) {
      if (context.mounted == false) return;
      final trusted = await showTrustConfirmDialog(context, device.info);
      if (trusted != true) return;
      await controller.trustStore.add(
          device.info.fingerprint, device.info.alias);
    }
    ref.read(sendControllerProvider.notifier).send(device, files);
  }
}

class _ProgressCard extends ConsumerWidget {
  const _ProgressCard({required this.progress});

  final SendProgress progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ratio = progress.totalBytes > 0
        ? progress.sentBytes / progress.totalBytes
        : null;
    final (String title, Color? color) = switch (progress.phase) {
      SendPhase.waitingApproval =>
        ('${progress.targetAlias}의 승인 대기 중…', null),
      SendPhase.uploading => (
          '${progress.targetAlias}에 전송 중 '
              '(${progress.fileIndex + 1}/${progress.fileCount})',
          null
        ),
      SendPhase.done => ('전송 완료', Colors.green),
      SendPhase.canceled => ('전송 취소됨', null),
      SendPhase.error => (
          progress.message ?? '전송 실패',
          Theme.of(context).colorScheme.error
        ),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(color: color)),
                ),
                if (progress.inFlight)
                  TextButton(
                    onPressed:
                        ref.read(sendControllerProvider.notifier).cancel,
                    child: const Text('취소'),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed:
                        ref.read(sendControllerProvider.notifier).dismiss,
                  ),
              ],
            ),
            if (progress.phase == SendPhase.uploading) ...[
              const SizedBox(height: 8),
              Text(progress.currentFileName,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: ratio),
              const SizedBox(height: 4),
              Text(
                '${formatBytes(progress.sentBytes)} / ${formatBytes(progress.totalBytes)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
