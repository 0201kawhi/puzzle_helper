import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../models/puzzle_project.dart';
import '../services/project_storage.dart';
import '../services/vision/perspective_corrector.dart';
import '../services/vision/reference_mapper.dart';
import '../widgets/perspective_crop_view.dart';

/// 建立或編輯拼圖專案頁面
///
/// 支援：
/// 1. 拍攝/匯入 1 張全貌底圖並進行互動式四點透視拉正
/// 2. 拍攝/匯入多張高解析度局部特寫圖，自動透過 AKAZE + Homography 映射回全貌底圖
class ProjectSetupScreen extends StatefulWidget {
  final PuzzleProject? existingProject;

  const ProjectSetupScreen({super.key, this.existingProject});

  @override
  State<ProjectSetupScreen> createState() => _ProjectSetupScreenState();
}

class _ProjectSetupScreenState extends State<ProjectSetupScreen> {
  final ProjectStorageService _storage = ProjectStorageService();
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _nameController = TextEditingController();
  final Uuid _uuid = const Uuid();

  late String _projectId;
  String? _rawPickedOverviewPath;
  List<Offset> _perspectiveCorners = const [
    Offset(0.06, 0.06),
    Offset(0.94, 0.06),
    Offset(0.94, 0.94),
    Offset(0.06, 0.94),
  ];

  String? _warpedOverviewPath;
  int _overviewWidth = 0;
  int _overviewHeight = 0;
  List<DetailTile> _detailTiles = [];
  bool _isProcessing = false;
  String _processingStatus = '';

  @override
  void initState() {
    super.initState();
    final existing = widget.existingProject;
    if (existing != null) {
      _projectId = existing.id;
      _nameController.text = existing.name;
      _warpedOverviewPath = existing.overviewImagePath;
      _overviewWidth = existing.overviewWidth;
      _overviewHeight = existing.overviewHeight;
      _detailTiles = List<DetailTile>.from(existing.detailTiles);
    } else {
      _projectId = _uuid.v4();
      _nameController.text =
          '我的拼圖 (${DateTime.now().month}/${DateTime.now().day})';
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// 選擇或拍攝全貌原圖，並進入四點透視拉正預覽
  Future<void> _pickOverviewImage(ImageSource source) async {
    final xFile = await _picker.pickImage(
      source: source,
      imageQuality: 95,
      maxWidth: 3200,
      maxHeight: 3200,
    );
    if (xFile == null) return;

    setState(() {
      _isProcessing = true;
      _processingStatus = '正在偵測拼圖外盒四邊角點...';
    });

    final detected = PerspectiveCorrector.detectDefaultCorners(xFile.path);
    if (!mounted) return;
    setState(() {
      _rawPickedOverviewPath = xFile.path;
      _perspectiveCorners = detected;
      _isProcessing = false;
    });
  }

  /// 確認四點角點並執行透視變換拉正，儲存為全貌底圖
  Future<void> _applyPerspectiveWarp() async {
    if (_rawPickedOverviewPath == null) return;
    setState(() {
      _isProcessing = true;
      _processingStatus = '正在執行四點透視校正拉正...';
    });

    try {
      final projDir = await _storage.getProjectDirectory(_projectId);
      final outPath = p.join(
        projDir.path,
        'overview_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      final dims = PerspectiveCorrector.warpPerspectiveAndSave(
        inputPath: _rawPickedOverviewPath!,
        outputPath: outPath,
        cornersNormalized: _perspectiveCorners,
      );

      if (!mounted) return;
      setState(() {
        _warpedOverviewPath = outPath;
        _overviewWidth = dims.width;
        _overviewHeight = dims.height;
        _rawPickedOverviewPath = null;
        _isProcessing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('透視校正失敗：$e')),
      );
    }
  }

  /// 新增高解析局部特寫圖，自動透過特徵匹配對齊回全貌底圖
  Future<void> _addDetailTile(ImageSource source) async {
    if (_warpedOverviewPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('請先建立第 1 步的「全貌底圖」！')),
      );
      return;
    }

    final xFile = await _picker.pickImage(
      source: source,
      imageQuality: 98,
      maxWidth: 3200,
      maxHeight: 3200,
    );
    if (xFile == null) return;

    setState(() {
      _isProcessing = true;
      _processingStatus = '正在使用 AKAZE 特徵將局部高畫質圖映射至全貌底圖...';
    });

    try {
      final projDir = await _storage.getProjectDirectory(_projectId);
      final tileId = _uuid.v4();
      final savedTilePath = p.join(projDir.path, 'tile_$tileId.jpg');
      await File(xFile.path).copy(savedTilePath);

      final label = '局部特寫 #${_detailTiles.length + 1}';
      final alignedTile = ReferenceMapper.alignDetailTileToOverview(
        tileId: tileId,
        label: label,
        tileImagePath: savedTilePath,
        overviewImagePath: _warpedOverviewPath!,
      );

      if (!mounted) return;
      setState(() {
        _detailTiles.add(alignedTile);
        _isProcessing = false;
      });

      if (!alignedTile.isAligned) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Colors.orange,
            content: Text('提示：此局部圖特徵重疊點較少，建議拍攝時保留足夠圖案細節並避免嚴重反光。'),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF00C853),
            content: Text(
              '成功對齊「$label」！（共匹配 ${alignedTile.inlierCount} 個特徵內點）',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('新增局部特寫圖失敗：$e')),
      );
    }
  }

  Future<void> _saveAndStart() async {
    if (_warpedOverviewPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('請先完成全貌底圖設定')),
      );
      return;
    }

    final name = _nameController.text.trim().isEmpty
        ? '未命名拼圖'
        : _nameController.text.trim();

    final project = PuzzleProject(
      id: _projectId,
      name: name,
      createdAt: widget.existingProject?.createdAt ?? DateTime.now(),
      updatedAt: DateTime.now(),
      overviewImagePath: _warpedOverviewPath!,
      overviewWidth: _overviewWidth,
      overviewHeight: _overviewHeight,
      detailTiles: _detailTiles,
    );

    await _storage.saveProject(project);
    if (!mounted) return;
    Navigator.of(context).pop(project);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existingProject == null ? '建立拼圖參考圖' : '編輯拼圖參考圖'),
        actions: [
          if (_warpedOverviewPath != null && _rawPickedOverviewPath == null)
            Padding(
              padding: const EdgeInsets.only(right: 10.0),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF00E676),
                  foregroundColor: Colors.black,
                ),
                onPressed: _isProcessing ? null : _saveAndStart,
                icon: const Icon(Icons.check, size: 18),
                label: const Text(
                  '儲存並開始掃描',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          if (_rawPickedOverviewPath != null)
            _buildPerspectiveCropStep()
          else
            _buildMainSetupScroll(),
          if (_isProcessing)
            Container(
              color: Colors.black87,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Color(0xFF00E676)),
                    const SizedBox(height: 16),
                    Text(
                      _processingStatus,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 互動式四點透視校正畫面
  Widget _buildPerspectiveCropStep() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          color: const Color(0xFF1A202C),
          child: const Text(
            '請拖曳四個角點對齊拼圖外盒/完成圖的四個角落，系統將自動拉正透視變形：',
            style: TextStyle(color: Colors.cyanAccent, fontSize: 13),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: PerspectiveCropView(
              imagePath: _rawPickedOverviewPath!,
              initialCornersNormalized: _perspectiveCorners,
              onCornersChanged: (corners) => _perspectiveCorners = corners,
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () =>
                        setState(() => _rawPickedOverviewPath = null),
                    child: const Text('取消重選'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00E676),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _applyPerspectiveWarp,
                    icon: const Icon(Icons.crop_rotate),
                    label: const Text(
                      '套用四點透視拉正',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 主設定流程（步驟1：全貌底圖 + 步驟2：多張高畫質局部特寫圖）
  Widget _buildMainSetupScroll() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _nameController,
          decoration: InputDecoration(
            labelText: '拼圖專案名稱',
            prefixIcon: const Icon(Icons.extension),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            filled: true,
            fillColor: const Color(0xFF1A202C),
          ),
        ),
        const SizedBox(height: 20),

        // 步驟 1：1張全貌底圖
        _buildStepHeader(
          stepNumber: '1',
          title: '建立 1 張「全貌底圖」（必選）',
          subtitle: '拍攝拼圖外盒正面或完成圖，用於全圖座標導航與四邊外框定位。',
        ),
        const SizedBox(height: 10),
        if (_warpedOverviewPath != null)
          Card(
            color: const Color(0xFF1A202C),
            clipBehavior: Clip.antiAlias,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Column(
              children: [
                SizedBox(
                  height: 210,
                  width: double.infinity,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(
                        File(_warpedOverviewPath!),
                        fit: BoxFit.contain,
                      ),
                      // 繪製已對齊局部特寫圖在全貌圖上的覆蓋範圍
                      CustomPaint(
                        painter: _TileCoveragePainter(tiles: _detailTiles),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(10.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '已拉正全貌圖 ($_overviewWidth×$_overviewHeight)',
                        style: const TextStyle(
                            color: Color(0xFF00E676),
                            fontWeight: FontWeight.bold),
                      ),
                      TextButton.icon(
                        onPressed: () =>
                            _pickOverviewImage(ImageSource.camera),
                        icon: const Icon(Icons.camera_alt, size: 16),
                        label: const Text('重拍全貌圖'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          )
        else
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: const Color(0xFF00E676),
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () => _pickOverviewImage(ImageSource.camera),
                  icon: const Icon(Icons.camera_alt),
                  label: const Text(
                    '拍攝外盒/全貌圖',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () => _pickOverviewImage(ImageSource.gallery),
                  icon: const Icon(Icons.photo_library),
                  label: const Text('從相簿匯入'),
                ),
              ),
            ],
          ),

        const SizedBox(height: 26),

        // 步驟 2：多張高解析度局部特寫圖
        _buildStepHeader(
          stepNumber: '2',
          title: '補拍多張「高解析度局部特寫」（推薦）',
          subtitle:
              '解決單張照片解析度不足或盒子局部反光！近距離分成 4 宮格或 6 宮格拍攝局部圖，系統會獨立比對每張高畫質局部圖並自動換算回全貌底圖座標。',
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onPressed: _warpedOverviewPath == null
                    ? null
                    : () => _addDetailTile(ImageSource.camera),
                icon: const Icon(Icons.zoom_in_map),
                label: const Text('近距離拍攝局部特寫'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onPressed: _warpedOverviewPath == null
                    ? null
                    : () => _addDetailTile(ImageSource.gallery),
                icon: const Icon(Icons.add_photo_alternate),
                label: const Text('從相簿新增局部圖'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        if (_detailTiles.isNotEmpty)
          ...List.generate(_detailTiles.length, (idx) {
            final tile = _detailTiles[idx];
            return Card(
              color: const Color(0xFF1A202C),
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(
                    File(tile.imagePath),
                    width: 54,
                    height: 54,
                    fit: BoxFit.cover,
                  ),
                ),
                title: Text(
                  tile.label,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  tile.isAligned
                      ? '已自動映射至全貌底圖 · ${tile.inlierCount} 個特徵點對齊 (${tile.width}×${tile.height})'
                      : '未對齊全貌圖（特徵重疊不足，建議刪除此張重拍）',
                  style: TextStyle(
                    color:
                        tile.isAligned ? Colors.cyanAccent : Colors.orangeAccent,
                    fontSize: 12,
                  ),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white54),
                  onPressed: () {
                    setState(() => _detailTiles.removeAt(idx));
                  },
                ),
              ),
            );
          }),

        const SizedBox(height: 32),
        if (_warpedOverviewPath != null)
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF00E676),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
            onPressed: _saveAndStart,
            icon: const Icon(Icons.play_arrow),
            label: const Text(
              '完成設定，進入即時 AR 掃描定位',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
      ],
    );
  }

  Widget _buildStepHeader({
    required String stepNumber,
    required String title,
    required String subtitle,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 14,
          backgroundColor: const Color(0xFF00E676),
          foregroundColor: Colors.black,
          child: Text(
            stepNumber,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: const TextStyle(color: Colors.white70, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 在全貌圖預覽上畫出各張高畫質局部特寫圖的映射覆蓋框
class _TileCoveragePainter extends CustomPainter {
  final List<DetailTile> tiles;

  _TileCoveragePainter({required this.tiles});

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < tiles.length; i++) {
      final rectNorm = tiles[i].coverageRectNormalized;
      if (rectNorm == null) continue;

      final rectPx = Rect.fromLTRB(
        rectNorm.left * size.width,
        rectNorm.top * size.height,
        rectNorm.right * size.width,
        rectNorm.bottom * size.height,
      );

      canvas.drawRect(
        rectPx,
        Paint()
          ..color = Colors.cyanAccent.withValues(alpha: 0.15)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRect(
        rectPx,
        Paint()
          ..color = Colors.cyanAccent
          ..strokeWidth = 1.6
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TileCoveragePainter oldDelegate) => true;
}
