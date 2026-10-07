import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// 全屏扫码页：识别到第一个二维码即返回其内容（pop 字符串）。
///
/// 用于 MyLanFiles 配对（扫码 → MlfPairingInfo JSON）。不依赖上游路由；
/// 文案走上游 i18n 的 mlf 命名空间（R8 起，t.mlf.*）。
class MlfQrScanPage extends StatefulWidget {
  const MlfQrScanPage({super.key});

  @override
  State<MlfQrScanPage> createState() => _MlfQrScanPageState();
}

class _MlfQrScanPageState extends State<MlfQrScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _popped = false;

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_popped || !mounted) {
      return;
    }
    final value = capture.barcodes.firstOrNull?.rawValue;
    if (value == null || value.isEmpty) {
      return;
    }
    _popped = true;
    debugPrint('[MLF] qr detected: $value');
    unawaited(_controller.stop());
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t.mlf.scanTitle)),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.camera_alt_outlined, size: 48),
                  const SizedBox(height: 12),
                  Text(t.mlf.cameraUnavailable(error: error), textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => unawaited(_controller.start()),
                    child: Text(t.mlf.retry),
                  ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 32),
              child: Text(t.mlf.scanHint),
            ),
          ),
        ],
      ),
    );
  }
}
