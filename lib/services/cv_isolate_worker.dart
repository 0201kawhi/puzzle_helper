import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import '../models/match_result.dart';
import '../models/puzzle_project.dart';
import 'vision/piece_segmenter.dart';
import 'vision/puzzle_matcher.dart';

/// 傳遞至背景視覺 Isolate 的相機串流幀封包
class CameraFramePacket {
  final int width;
  final int height;
  final int sensorOrientationDeg;
  final bool isBgra;
  final Uint8List yPlaneOrBgraBytes;
  final Uint8List? uPlaneBytes;
  final Uint8List? vPlaneBytes;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;
  final Offset targetPointNormalized;
  final bool encodeJpeg;

  const CameraFramePacket({
    required this.width,
    required this.height,
    required this.sensorOrientationDeg,
    required this.isBgra,
    required this.yPlaneOrBgraBytes,
    this.uPlaneBytes,
    this.vPlaneBytes,
    required this.yRowStride,
    this.uvRowStride = 0,
    this.uvPixelStride = 1,
    required this.targetPointNormalized,
    this.encodeJpeg = false,
  });

  /// 建立擁有獨立記憶體緩衝區的封包複本（避免 Android CameraX ImageProxy 緩衝區回收覆寫），
  /// 供「定格畫面 (Freeze Frame)」保存以及在定格狀態下自由點擊切換不同拼圖塊重新分析使用。
  CameraFramePacket cloneWithIndependentBuffers({
    Offset? targetPointNormalized,
    bool? encodeJpeg,
  }) {
    return CameraFramePacket(
      width: width,
      height: height,
      sensorOrientationDeg: sensorOrientationDeg,
      isBgra: isBgra,
      yPlaneOrBgraBytes: Uint8List.fromList(yPlaneOrBgraBytes),
      uPlaneBytes:
          uPlaneBytes != null ? Uint8List.fromList(uPlaneBytes!) : null,
      vPlaneBytes:
          vPlaneBytes != null ? Uint8List.fromList(vPlaneBytes!) : null,
      yRowStride: yRowStride,
      uvRowStride: uvRowStride,
      uvPixelStride: uvPixelStride,
      targetPointNormalized:
          targetPointNormalized ?? this.targetPointNormalized,
      encodeJpeg: encodeJpeg ?? this.encodeJpeg,
    );
  }

  /// 在已複製過緩衝區的定格封包上更換目標準星座標
  CameraFramePacket copyWithTarget({
    required Offset targetPointNormalized,
    bool encodeJpeg = false,
  }) {
    return CameraFramePacket(
      width: width,
      height: height,
      sensorOrientationDeg: sensorOrientationDeg,
      isBgra: isBgra,
      yPlaneOrBgraBytes: yPlaneOrBgraBytes,
      uPlaneBytes: uPlaneBytes,
      vPlaneBytes: vPlaneBytes,
      yRowStride: yRowStride,
      uvRowStride: uvRowStride,
      uvPixelStride: uvPixelStride,
      targetPointNormalized: targetPointNormalized,
      encodeJpeg: encodeJpeg,
    );
  }
}

/// 背景 Isolate 即時視覺運算調度器
///
/// 在獨立的 Dart Isolate 中常駐持有 [PuzzleMatcher] 的特徵索引與金字塔快取，
/// 接收相機串流幀進行非同步去背、直邊檢測與雙引擎比對，確保主執行緒 60fps 流暢度。
class CvIsolateWorker {
  Isolate? _isolate;
  SendPort? _workerSendPort;
  ReceivePort? _mainReceivePort;
  Completer<void>? _initCompleter;
  Completer<FrameAnalysisResult>? _pendingFrameCompleter;
  bool _isBusy = false;

  bool get isBusy => _isBusy;
  bool get isReady => _workerSendPort != null;

  /// 啟動背景 Isolate 並載入拼圖專案特徵索引
  Future<void> startAndInitialize(PuzzleProject project) async {
    await dispose();
    _initCompleter = Completer<void>();
    final receivePort = ReceivePort();
    _mainReceivePort = receivePort;

    receivePort.listen((message) {
      if (message is SendPort) {
        _workerSendPort = message;
        _workerSendPort!.send({
          'cmd': 'init',
          'project': project.toJson(),
        });
      } else if (message is Map<String, dynamic>) {
        final type = message['type'] as String?;
        if (type == 'initialized') {
          if (_initCompleter != null && !_initCompleter!.isCompleted) {
            _initCompleter!.complete();
          }
        } else if (type == 'frame_result') {
          _isBusy = false;
          final result = message['result'] as FrameAnalysisResult;
          if (_pendingFrameCompleter != null &&
              !_pendingFrameCompleter!.isCompleted) {
            _pendingFrameCompleter!.complete(result);
          }
        } else if (type == 'error') {
          _isBusy = false;
          if (_pendingFrameCompleter != null &&
              !_pendingFrameCompleter!.isCompleted) {
            _pendingFrameCompleter!.complete(FrameAnalysisResult.empty);
          }
          if (_initCompleter != null && !_initCompleter!.isCompleted) {
            _initCompleter!
                .completeError(message['message'] ?? 'Unknown error');
          }
        }
      }
    });

    _isolate = await Isolate.spawn(
      _isolateEntry,
      receivePort.sendPort,
      debugName: 'PuzzleVisionIsolate',
    );

    return _initCompleter!.future;
  }

  /// 傳送單幀即時串流畫面至背景 Isolate（若上一幀尚未完成則自動略過，避免佇列堆積）
  Future<FrameAnalysisResult?> processCameraFrame(
      CameraFramePacket packet) async {
    if (_workerSendPort == null || _isBusy) return null;
    _isBusy = true;
    _pendingFrameCompleter = Completer<FrameAnalysisResult>();
    _workerSendPort!.send({
      'cmd': 'frame',
      'packet': packet,
    });
    return _pendingFrameCompleter!.future;
  }

  /// 保證執行的單幀分析（用於「定格畫面」擷取快照與定格後點擊切換不同拼圖塊）
  Future<FrameAnalysisResult?> processFrameGuaranteed(
      CameraFramePacket packet) async {
    if (_workerSendPort == null) return null;
    // 若剛好有一幀即時串流正在運算中，先等待其完成再立刻處理定格幀
    while (_isBusy && _pendingFrameCompleter != null) {
      try {
        await _pendingFrameCompleter!.future;
      } catch (_) {
        break;
      }
    }
    if (_workerSendPort == null) return null;
    _isBusy = true;
    _pendingFrameCompleter = Completer<FrameAnalysisResult>();
    _workerSendPort!.send({
      'cmd': 'frame',
      'packet': packet,
    });
    return _pendingFrameCompleter!.future;
  }

  Future<void> dispose() async {
    _workerSendPort?.send({'cmd': 'dispose'});
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _workerSendPort = null;
    _mainReceivePort?.close();
    _mainReceivePort = null;
    _isBusy = false;
  }

  /// 背景 Isolate 主迴圈
  static void _isolateEntry(SendPort mainSendPort) {
    final workerReceivePort = ReceivePort();
    mainSendPort.send(workerReceivePort.sendPort);

    PuzzleMatcher? matcher;

    workerReceivePort.listen((message) {
      if (message is! Map<String, dynamic>) return;
      final cmd = message['cmd'] as String?;

      if (cmd == 'init') {
        try {
          final projectJson = message['project'] as Map<String, dynamic>;
          final project = PuzzleProject.fromJson(projectJson);
          matcher?.dispose();
          matcher = PuzzleMatcher(project)..initializeIndex();
          mainSendPort.send({'type': 'initialized'});
        } catch (e) {
          mainSendPort.send({
            'type': 'error',
            'message': e.toString(),
          });
        }
      } else if (cmd == 'frame') {
        final sw = Stopwatch()..start();
        try {
          if (matcher == null || !matcher!.isInitialized) {
            mainSendPort.send({
              'type': 'frame_result',
              'result': FrameAnalysisResult.empty,
            });
            return;
          }

          final packet = message['packet'] as CameraFramePacket;

          // 若需要定格快照 (encodeJpeg == true)，先以原解析度轉換並編碼出清晰 JPEG 供 UI 覆蓋顯示
          Uint8List? encodedJpeg;
          if (packet.encodeJpeg) {
            final fullResBgr =
                _convertCameraPacketToBgrMat(packet, fullResolution: true);
            if (fullResBgr != null && !fullResBgr.isEmpty) {
              final (ok, bytes) = cv.imencode('.jpg', fullResBgr);
              if (ok) {
                encodedJpeg = bytes;
              }
            }
            fullResBgr?.dispose();
          }

          final frameBgr =
              _convertCameraPacketToBgrMat(packet, fullResolution: false);
          if (frameBgr == null || frameBgr.isEmpty) {
            frameBgr?.dispose();
            mainSendPort.send({
              'type': 'frame_result',
              'result': FrameAnalysisResult(
                detectedPieces: const [],
                activePieceId: null,
                candidates: const [],
                processingTimeMs: 0,
                frozenFrameJpeg: encodedJpeg,
              ),
            });
            return;
          }

          // 1. 自適應桌面去背與目標拼圖塊分割
          final segmented = PieceSegmenter.segmentFrame(
            frameBgr: frameBgr,
            targetPointNormalized: packet.targetPointNormalized,
          );
          frameBgr.dispose();

          // 2. 雙引擎拼圖落點比對
          final candidates = matcher!.matchPiece(segmented.targetPatch);
          final activeId = segmented.targetPatch.pieceInfo.id;
          segmented.targetPatch.dispose();

          sw.stop();
          mainSendPort.send({
            'type': 'frame_result',
            'result': FrameAnalysisResult(
              detectedPieces: segmented.allPieces,
              activePieceId: activeId,
              candidates: candidates,
              processingTimeMs: sw.elapsedMilliseconds,
              frozenFrameJpeg: encodedJpeg,
            ),
          });
        } catch (e) {
          mainSendPort.send({
            'type': 'frame_result',
            'result': FrameAnalysisResult.empty,
          });
        }
      } else if (cmd == 'dispose') {
        matcher?.dispose();
        matcher = null;
        workerReceivePort.close();
      }
    });
  }

  /// 將 YUV420 (Android) 或 BGRA8888 (iOS) 相機原始緩衝區轉為已轉正的 BGR Mat
  static cv.Mat? _convertCameraPacketToBgrMat(
    CameraFramePacket p, {
    required bool fullResolution,
  }) {
    final int srcW = p.width;
    final int srcH = p.height;
    if (srcW <= 0 || srcH <= 0) return null;

    // 即時分析時將長邊降採樣至約 640px 以提升幀率；定格快照則保留完整解析度
    final int step = (!fullResolution && srcW > 960) ? 2 : 1;
    final int outW = srcW ~/ step;
    final int outH = srcH ~/ step;
    final bgrBytes = Uint8List(outW * outH * 3);

    if (p.isBgra) {
      final bytes = p.yPlaneOrBgraBytes;
      final stride = p.yRowStride;
      int dstIdx = 0;
      for (int y = 0; y < outH; y++) {
        final int sy = y * step;
        final int rowOffset = sy * stride;
        for (int x = 0; x < outW; x++) {
          final int sx = x * step;
          final int idx = rowOffset + sx * 4;
          if (idx + 2 < bytes.length) {
            bgrBytes[dstIdx++] = bytes[idx]; // B
            bgrBytes[dstIdx++] = bytes[idx + 1]; // G
            bgrBytes[dstIdx++] = bytes[idx + 2]; // R
          } else {
            dstIdx += 3;
          }
        }
      }
    } else {
      final yPlane = p.yPlaneOrBgraBytes;
      final uPlane = p.uPlaneBytes;
      final vPlane = p.vPlaneBytes;
      if (uPlane == null || vPlane == null) return null;

      final int yStride = p.yRowStride;
      final int uvStride = p.uvRowStride;
      final int uvPixelStride = p.uvPixelStride;
      int dstIdx = 0;

      for (int y = 0; y < outH; y++) {
        final int sy = y * step;
        final int yRow = sy * yStride;
        final int uvRow = (sy >> 1) * uvStride;

        for (int x = 0; x < outW; x++) {
          final int sx = x * step;
          final int yIdx = yRow + sx;
          final int uvIdx = uvRow + (sx >> 1) * uvPixelStride;

          final int yVal = yIdx < yPlane.length ? yPlane[yIdx] : 0;
          final int uVal = uvIdx < uPlane.length ? uPlane[uvIdx] - 128 : 0;
          final int vVal = uvIdx < vPlane.length ? vPlane[uvIdx] - 128 : 0;

          final int r = (yVal + ((359 * vVal) >> 8)).clamp(0, 255);
          final int g = (yVal - ((88 * uVal + 183 * vVal) >> 8)).clamp(0, 255);
          final int b = (yVal + ((454 * uVal) >> 8)).clamp(0, 255);

          bgrBytes[dstIdx++] = b;
          bgrBytes[dstIdx++] = g;
          bgrBytes[dstIdx++] = r;
        }
      }
    }

    final rawMat = cv.Mat.fromList(outH, outW, cv.MatType.CV_8UC3, bgrBytes);

    // 依據手機鏡頭感測器方向 (Sensor Orientation) 旋轉為直立畫面
    switch (p.sensorOrientationDeg % 360) {
      case 90:
        final rotated = cv.rotate(rawMat, cv.ROTATE_90_CLOCKWISE);
        rawMat.dispose();
        return rotated;
      case 180:
        final rotated = cv.rotate(rawMat, cv.ROTATE_180);
        rawMat.dispose();
        return rotated;
      case 270:
        final rotated = cv.rotate(rawMat, cv.ROTATE_90_COUNTERCLOCKWISE);
        rawMat.dispose();
        return rotated;
      default:
        return rawMat;
    }
  }
}
