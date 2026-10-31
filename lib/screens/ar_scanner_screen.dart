import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/match_result.dart';
import '../models/puzzle_project.dart';
import '../services/cv_isolate_worker.dart';
import '../widgets/ar_camera_overlay.dart';
import '../widgets/reference_map_viewer.dart';
import 'project_setup_screen.dart';

/// 即時 AR 鏡頭掃描與原圖定位主畫面
///
/// 支援：
/// 1. 上下分割畫面 (Split View) 與 全螢幕 AR 相機 + 浮動子母畫面 (PiP) 一鍵切換
/// 2. 預設鎖定中央準星拼圖塊，並支援點擊畫面中其他拼圖塊切換鎖定目標
/// 3. 畫面定格 (Freeze Frame) 快照覆蓋機制：不呼叫 Android CameraX 有恢復異常的 pausePreview/resumePreview，
///    而是以獨立記憶體緩衝區擷取高畫質定格幀覆蓋顯示，不僅解除定格可 100% 瞬間恢復即時畫面，
///    更支援在定格畫面上任意點擊切換不同散落拼圖塊重新比對！
class ArScannerScreen extends StatefulWidget {
  final PuzzleProject project;

  const ArScannerScreen({super.key, required this.project});

  @override
  State<ArScannerScreen> createState() => _ArScannerScreenState();
}

class _ArScannerScreenState extends State<ArScannerScreen>
    with WidgetsBindingObserver {
  late PuzzleProject _project;
  final CvIsolateWorker _cvWorker = CvIsolateWorker();

  CameraController? _cameraController;
  bool _isInitializing = true;
  String _statusMessage = '正在初始化 OpenCV 雙引擎與高畫質局部圖索引...';
  String? _errorMessage;

  /// 版面模式：false = 上下分割 (預設), true = 全螢幕相機 + 浮動子母畫面 (PiP)
  bool _isPipMode = false;

  /// 定格狀態與定格快照緩衝區（避開 Android CameraX resumePreview 無法恢復畫面的原生 Bug）
  bool _isFrozen = false;
  bool _isCapturingFreeze = false;
  bool _wantsFreezeCapture = false;
  Uint8List? _frozenFrameJpeg;
  CameraFramePacket? _frozenPacket;

  /// 手電筒補光開關
  bool _isTorchOn = false;

  /// 目前準星鎖定目標座標（預設為畫面正中央 0.5, 0.5；點擊其他拼圖塊時更新）
  Offset _targetPointNormalized = const Offset(0.5, 0.5);

  /// 最新一幀視覺分析結果
  FrameAnalysisResult _analysisResult = FrameAnalysisResult.empty;

  /// 目前在 Top-3 候選中選中的索引 (0 = Top 1, 1 = Top 2, 2 = Top 3)
  int _selectedCandidateIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _project = widget.project;
    _initVisionAndCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final controller = _cameraController;
    _cameraController = null;
    controller?.dispose();
    _cvWorker.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _disposeCameraOnly();
    } else if (state == AppLifecycleState.resumed) {
      if (_cameraController == null && !_isInitializing) {
        _initCameraOnly();
      }
    }
  }

  Future<void> _disposeCameraOnly() async {
    final controller = _cameraController;
    if (controller == null) return;
    if (mounted) {
      setState(() {
        _cameraController = null;
        _isTorchOn = false;
      });
    } else {
      _cameraController = null;
    }
    try {
      if (controller.value.isInitialized &&
          controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {}
    try {
      await controller.dispose();
    } catch (_) {}
  }

  Future<void> _initVisionAndCamera() async {
    setState(() {
      _isInitializing = true;
      _errorMessage = null;
      _isFrozen = false;
      _isCapturingFreeze = false;
      _wantsFreezeCapture = false;
      _frozenFrameJpeg = null;
      _frozenPacket = null;
      _statusMessage = '正在建立全貌圖與 ${_project.detailTiles.length} 張局部圖特徵索引...';
    });

    try {
      await _disposeCameraOnly();
      await _cvWorker.startAndInitialize(_project);
      await _initCameraOnly();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _errorMessage = '初始化失敗：$e';
      });
    }
  }

  Future<void> _initCameraOnly() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _errorMessage = '需要相機權限才能進行即時 AR 拼圖掃描';
      });
      return;
    }

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _errorMessage = '找不到可用的相機鏡頭';
      });
      return;
    }

    final backCamera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    final controller = CameraController(
      backCamera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
    );

    try {
      await controller.initialize();
      await controller.startImageStream(_onCameraFrame);
    } catch (e) {
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _errorMessage = '啟動相機串流失敗：$e';
      });
      return;
    }

    if (!mounted) {
      await controller.dispose();
      return;
    }

    setState(() {
      _cameraController = controller;
      _isInitializing = false;
    });
  }

  CameraFramePacket _buildPacketFromCameraImage(
    CameraImage image,
    CameraController controller, {
    bool encodeJpeg = false,
  }) {
    final bool isBgra = image.format.group == ImageFormatGroup.bgra8888 ||
        image.planes.length == 1;

    return CameraFramePacket(
      width: image.width,
      height: image.height,
      sensorOrientationDeg: controller.description.sensorOrientation,
      isBgra: isBgra,
      yPlaneOrBgraBytes: image.planes[0].bytes,
      uPlaneBytes: image.planes.length > 1 ? image.planes[1].bytes : null,
      vPlaneBytes: image.planes.length > 2 ? image.planes[2].bytes : null,
      yRowStride: image.planes[0].bytesPerRow,
      uvRowStride: image.planes.length > 1 ? image.planes[1].bytesPerRow : 0,
      uvPixelStride:
          image.planes.length > 1 ? (image.planes[1].bytesPerPixel ?? 1) : 1,
      targetPointNormalized: _targetPointNormalized,
      encodeJpeg: encodeJpeg,
    );
  }

  void _onCameraFrame(CameraImage image) {
    final controller = _cameraController;
    if (controller == null || !_cvWorker.isReady) return;

    // 1. 若使用者剛按下「定格畫面」，立即深拷貝此幀緩衝區並產生高畫質定格快照與分析結果
    if (_wantsFreezeCapture) {
      _wantsFreezeCapture = false;
      final rawPacket =
          _buildPacketFromCameraImage(image, controller, encodeJpeg: true);
      final clonedFreezePacket = rawPacket.cloneWithIndependentBuffers(
        targetPointNormalized: _targetPointNormalized,
        encodeJpeg: true,
      );
      _frozenPacket = clonedFreezePacket;

      _cvWorker.processFrameGuaranteed(clonedFreezePacket).then((result) {
        if (!mounted || !_isCapturingFreeze) return;
        setState(() {
          _isCapturingFreeze = false;
          _isFrozen = true;
          if (result != null) {
            if (result.frozenFrameJpeg != null) {
              _frozenFrameJpeg = result.frozenFrameJpeg;
            }
            _analysisResult = result;
            if (_selectedCandidateIndex >= result.candidates.length) {
              _selectedCandidateIndex = 0;
            }
          }
        });
      });
      return;
    }

    // 2. 定格狀態或擷取定格快照期間，不處理即時串流幀（底層 CameraPreview 保持連線不中斷）
    if (_isFrozen || _isCapturingFreeze || _cvWorker.isBusy) return;

    // 3. 一般即時 AR 串流分析
    final packet = _buildPacketFromCameraImage(image, controller);
    _cvWorker.processCameraFrame(packet).then((result) {
      if (result == null || !mounted || _isFrozen || _isCapturingFreeze) return;
      setState(() {
        _analysisResult = result;
        if (_selectedCandidateIndex >= result.candidates.length) {
          _selectedCandidateIndex = 0;
        }
      });
    });
  }

  /// 切換「定格畫面 / 解除定格」：
  /// 完全不呼叫 CameraController.pausePreview / resumePreview，徹底避免 Android CameraX 畫面卡死 Bug！
  void _toggleFreezeFrame() {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    if (_isFrozen || _isCapturingFreeze) {
      // 解除定格：清除覆蓋的 JPEG 快照，底層保持活耀的 CameraPreview 瞬間無縫恢復即時畫面
      setState(() {
        _isFrozen = false;
        _isCapturingFreeze = false;
        _wantsFreezeCapture = false;
        _frozenFrameJpeg = null;
        _frozenPacket = null;
      });
    } else {
      // 啟動定格：由下一幀 (約 16~33ms 內) 擷取完整獨立緩衝區與高畫質 JPEG 覆蓋層
      setState(() {
        _isCapturingFreeze = true;
        _wantsFreezeCapture = true;
      });
    }
  }

  /// 更新準星目標座標（若處於「已定格」狀態，也會自動針對定格畫面上的新點擊位置重新分割與比對！）
  void _updateTargetPoint(Offset newTarget) {
    setState(() {
      _targetPointNormalized = newTarget;
    });

    if (_isFrozen && _frozenPacket != null) {
      final updatedPacket = _frozenPacket!.copyWithTarget(
        targetPointNormalized: newTarget,
        encodeJpeg: false,
      );
      _frozenPacket = updatedPacket;
      _cvWorker.processFrameGuaranteed(updatedPacket).then((result) {
        if (result == null || !mounted || !_isFrozen) return;
        setState(() {
          _analysisResult = result;
          _selectedCandidateIndex = 0;
        });
      });
    }
  }

  Future<void> _toggleTorch() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      final nextMode = _isTorchOn ? FlashMode.off : FlashMode.torch;
      await controller.setFlashMode(nextMode);
      setState(() => _isTorchOn = !_isTorchOn);
    } catch (_) {}
  }

  Future<void> _openProjectEdit() async {
    // 進入編輯頁前先釋放相機，避免在編輯頁使用相機補拍局部圖時發生硬體衝突
    setState(() {
      _isFrozen = false;
      _isCapturingFreeze = false;
      _wantsFreezeCapture = false;
      _frozenFrameJpeg = null;
      _frozenPacket = null;
    });
    await _disposeCameraOnly();

    if (!mounted) return;
    final updated = await Navigator.of(context).push<PuzzleProject>(
      MaterialPageRoute(
        builder: (_) => ProjectSetupScreen(existingProject: _project),
      ),
    );
    if (!mounted) return;
    if (updated != null) {
      setState(() => _project = updated);
      await _initVisionAndCamera();
    } else {
      await _initCameraOnly();
    }
  }

  @override
  Widget build(BuildContext context) {
    final CandidateLocation? selectedCandidate =
        _analysisResult.candidates.isNotEmpty &&
                _selectedCandidateIndex < _analysisResult.candidates.length
            ? _analysisResult.candidates[_selectedCandidateIndex]
            : null;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF10141D),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _project.name,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            Text(
              _isFrozen
                  ? '已定格畫面（可點擊畫面其他拼圖塊切換比對）'
                  : selectedCandidate != null
                      ? '${selectedCandidate.engineUsed} · ${_analysisResult.processingTimeMs}ms'
                      : '將拼圖塊置於準星中央或點擊任意散片 (${_analysisResult.processingTimeMs}ms)',
              style: TextStyle(
                fontSize: 11,
                color: _isFrozen ? Colors.amberAccent : Colors.cyanAccent,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              _isPipMode ? Icons.splitscreen : Icons.picture_in_picture_alt,
              color: const Color(0xFF00E676),
            ),
            tooltip: _isPipMode ? '切換為上下分割畫面' : '切換為全螢幕相機 + 浮動小地圖',
            onPressed: () => setState(() => _isPipMode = !_isPipMode),
          ),
          IconButton(
            icon: Icon(
              _isTorchOn ? Icons.flash_on : Icons.flash_off,
              color: _isTorchOn ? Colors.amberAccent : Colors.white70,
            ),
            tooltip: '補光燈開關',
            onPressed: _toggleTorch,
          ),
          IconButton(
            icon: const Icon(Icons.add_photo_alternate_outlined),
            tooltip: '補拍高解析度局部特寫圖',
            onPressed: _openProjectEdit,
          ),
        ],
      ),
      body: _isInitializing
          ? _buildLoadingView()
          : _errorMessage != null
              ? _buildErrorView()
              : _isPipMode
                  ? _buildPipLayout(selectedCandidate)
                  : _buildSplitViewLayout(selectedCandidate),
    );
  }

  /// 預設版面：上下分割模式 (上方 46% 原圖落點與局部放大卡，下方 54% 即時 AR 鏡頭)
  Widget _buildSplitViewLayout(CandidateLocation? selectedCandidate) {
    return Column(
      children: [
        Expanded(
          flex: 46,
          child: ReferenceMapViewer(
            project: _project,
            candidates: _analysisResult.candidates,
            selectedCandidateIndex: _selectedCandidateIndex,
            onSelectCandidate: (idx) =>
                setState(() => _selectedCandidateIndex = idx),
            isCompactPip: false,
          ),
        ),
        Container(
          height: 2,
          color: const Color(0xFF00E676).withValues(alpha: 0.5),
        ),
        Expanded(
          flex: 54,
          child: _buildCameraSection(selectedCandidate),
        ),
      ],
    );
  }

  /// 一鍵切換版面：全螢幕 AR 相機 + 右上角浮動子母畫面 (PiP)
  Widget _buildPipLayout(CandidateLocation? selectedCandidate) {
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildCameraSection(selectedCandidate),
        Positioned(
          top: 12,
          right: 12,
          width: 165,
          height: 135,
          child: GestureDetector(
            onTap: () => setState(() => _isPipMode = false),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF00E676), width: 2),
                boxShadow: const [
                  BoxShadow(color: Colors.black87, blurRadius: 10),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ReferenceMapViewer(
                    project: _project,
                    candidates: _analysisResult.candidates,
                    selectedCandidateIndex: _selectedCandidateIndex,
                    onSelectCandidate: (idx) =>
                        setState(() => _selectedCandidateIndex = idx),
                    isCompactPip: true,
                  ),
                  Positioned(
                    bottom: 4,
                    right: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        '點擊展開上下分割',
                        style: TextStyle(fontSize: 9, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 相機即時串流預覽 + 定格快照覆蓋層 + AR 疊加層 + 底部控制列
  Widget _buildCameraSection(CandidateLocation? selectedCandidate) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    final Size rawPreviewSize = controller.value.previewSize!;
    final int sensorDeg = controller.description.sensorOrientation % 360;
    final bool isSwapped = sensorDeg == 90 || sensorDeg == 270;
    final double uprightW =
        isSwapped ? rawPreviewSize.height : rawPreviewSize.width;
    final double uprightH =
        isSwapped ? rawPreviewSize.width : rawPreviewSize.height;
    final double uprightAspectRatio =
        uprightH > 0 ? (uprightW / uprightH) : (9.0 / 16.0);

    final bool isCustomTarget =
        (_targetPointNormalized - const Offset(0.5, 0.5)).distance > 0.03;
    final bool showFrozenState = _isFrozen || _isCapturingFreeze;

    return Stack(
      fit: StackFit.expand,
      children: [
        // 1. 底層即時相機畫面（定格時維持掛載不呼叫 pausePreview，確保解除定格 100% 零延遲恢復）
        ClipRect(
          child: OverflowBox(
            alignment: Alignment.center,
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: uprightW,
                height: uprightH,
                child: CameraPreview(controller),
              ),
            ),
          ),
        ),

        // 2. 定格快照覆蓋層（與底層 CameraPreview 採用相同 BoxFit.cover 與置中對齊，畫面零跳動）
        if (_isFrozen && _frozenFrameJpeg != null)
          Positioned.fill(
            child: Image.memory(
              _frozenFrameJpeg!,
              fit: BoxFit.cover,
              alignment: Alignment.center,
              gaplessPlayback: true,
            ),
          ),

        // 3. AR 疊加層（準星、多片輪廓框、點擊切換、正向旋轉箭頭 ↑）
        ArCameraOverlay(
          detectedPieces: _analysisResult.detectedPieces,
          activePiece: _analysisResult.activePiece,
          selectedCandidate: selectedCandidate,
          targetPointNormalized: _targetPointNormalized,
          cameraAspectRatio: uprightAspectRatio,
          onTapTargetNormalized: _updateTargetPoint,
        ),

        // 4. 畫面定格狀態提示邊框與標籤
        if (showFrozenState)
          IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.amberAccent, width: 3.5),
              ),
              alignment: Alignment.topLeft,
              padding: const EdgeInsets.all(10),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.amberAccent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _isCapturingFreeze ? '正在定格畫面...' : '已定格 · 可點擊任一拼圖塊查看位置',
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),

        // 5. 底部操作列：回到中央準星 + 定格 (Freeze Frame) 按鈕
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isCustomTarget)
                Padding(
                  padding: const EdgeInsets.only(right: 10.0),
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.black87,
                      foregroundColor: Colors.cyanAccent,
                    ),
                    onPressed: () =>
                        _updateTargetPoint(const Offset(0.5, 0.5)),
                    icon: const Icon(Icons.filter_center_focus, size: 18),
                    label: const Text('回到中央準星'),
                  ),
                ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: showFrozenState
                      ? Colors.amberAccent
                      : const Color(0xFF00E676),
                  foregroundColor: Colors.black,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
                ),
                onPressed: _toggleFreezeFrame,
                icon: Icon(showFrozenState ? Icons.play_arrow : Icons.pause),
                label: Text(
                  showFrozenState ? '解除定格 (恢復即時追蹤)' : '定格畫面 (仔細對照落點)',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLoadingView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFF00E676)),
            const SizedBox(height: 18),
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 54, color: Colors.redAccent),
            const SizedBox(height: 14),
            Text(
              _errorMessage ?? '發生未知錯誤',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _initVisionAndCamera,
              icon: const Icon(Icons.refresh),
              label: const Text('重試'),
            ),
          ],
        ),
      ),
    );
  }
}
