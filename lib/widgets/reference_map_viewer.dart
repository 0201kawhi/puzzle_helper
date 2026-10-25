import 'dart:io';
import 'package:flutter/material.dart';
import '../models/match_result.dart';
import '../models/puzzle_project.dart';

/// 參考原圖落點導航器 (Reference Map Viewer)
///
/// 支援：
/// 1. 雙指自由縮放與平移 (InteractiveViewer)
/// 2. 10x10 座標網格 (A1 ~ J10) 與高解析局部特寫覆蓋框顯示
/// 3. Top-3 候選落點標記（點擊切換第 1 / 2 / 3 名候選位置）与自動局部放大鏡檢視卡
class ReferenceMapViewer extends StatefulWidget {
  final PuzzleProject project;
  final List<CandidateLocation> candidates;
  final int selectedCandidateIndex;
  final ValueChanged<int> onSelectCandidate;
  final bool isCompactPip;

  const ReferenceMapViewer({
    super.key,
    required this.project,
    required this.candidates,
    required this.selectedCandidateIndex,
    required this.onSelectCandidate,
    this.isCompactPip = false,
  });

  @override
  State<ReferenceMapViewer> createState() => _ReferenceMapViewerState();
}

class _ReferenceMapViewerState extends State<ReferenceMapViewer> {
  final TransformationController _transformController =
      TransformationController();
  bool _showGrid = true;

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  void _resetZoom() {
    _transformController.value = Matrix4.identity();
  }

  static String _formatGridCoord(Offset norm) {
    const rows = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J'];
    final int r = (norm.dy * 10).floor().clamp(0, 9);
    final int c = (norm.dx * 10).floor().clamp(0, 9) + 1;
    return '${rows[r]}$c';
  }

  @override
  Widget build(BuildContext context) {
    final CandidateLocation? activeCandidate =
        widget.candidates.isNotEmpty &&
                widget.selectedCandidateIndex < widget.candidates.length
            ? widget.candidates[widget.selectedCandidateIndex]
            : null;

    return Container(
      color: const Color(0xFF10141D),
      child: Stack(
        children: [
          // 1. 可雙指縮放平移的全貌底圖與落點標記
          Positioned.fill(
            child: InteractiveViewer(
              transformationController: _transformController,
              minScale: 1.0,
              maxScale: 6.0,
              child: Center(
                child: AspectRatio(
                  aspectRatio: widget.project.overviewWidth /
                      (widget.project.overviewHeight > 0
                          ? widget.project.overviewHeight
                          : 1),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final double mapW = constraints.maxWidth;
                      final double mapH = constraints.maxHeight;

                      return GestureDetector(
                        onTapDown: (details) {
                          // 點擊地圖上的 Top-3 候選框可快速切換
                          final tapNorm = Offset(
                            details.localPosition.dx / mapW,
                            details.localPosition.dy / mapH,
                          );
                          for (int i = 0; i < widget.candidates.length; i++) {
                            final dist = (widget.candidates[i]
                                        .overviewCenterNormalized -
                                    tapNorm)
                                .distance;
                            if (dist < 0.08) {
                              widget.onSelectCandidate(i);
                              break;
                            }
                          }
                        },
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.file(
                              File(widget.project.overviewImagePath),
                              fit: BoxFit.fill,
                            ),
                            CustomPaint(
                              painter: _ReferenceMapOverlayPainter(
                                candidates: widget.candidates,
                                selectedIndex: widget.selectedCandidateIndex,
                                detailTiles: widget.project.detailTiles,
                                showGrid: _showGrid && !widget.isCompactPip,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),

          // 2. 右上角局部放大對比卡 (非 PiP 模式且有命中候選時顯示)
          if (!widget.isCompactPip && activeCandidate != null)
            Positioned(
              top: 8,
              right: 8,
              child: _ZoomedPatchPreviewCard(
                imagePath: widget.project.overviewImagePath,
                candidate: activeCandidate,
                gridCode:
                    _formatGridCoord(activeCandidate.overviewCenterNormalized),
              ),
            ),

          // 3. 左上角網格開關與重置縮放按鈕 (非 PiP 模式)
          if (!widget.isCompactPip)
            Positioned(
              top: 8,
              left: 8,
              child: Row(
                children: [
                  _MiniIconButton(
                    icon: _showGrid ? Icons.grid_on : Icons.grid_off,
                    tooltip: '切換座標網格',
                    onTap: () => setState(() => _showGrid = !_showGrid),
                  ),
                  const SizedBox(width: 6),
                  _MiniIconButton(
                    icon: Icons.center_focus_strong,
                    tooltip: '重置原圖縮放',
                    onTap: _resetZoom,
                  ),
                ],
              ),
            ),

          // 4. 底部 Top-3 候選落點切換列 (非 PiP 模式)
          if (!widget.isCompactPip && widget.candidates.isNotEmpty)
            Positioned(
              left: 8,
              right: 8,
              bottom: 6,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: List.generate(widget.candidates.length, (idx) {
                    final c = widget.candidates[idx];
                    final isSelected = idx == widget.selectedCandidateIndex;
                    final grid = _formatGridCoord(c.overviewCenterNormalized);
                    return Padding(
                      padding: const EdgeInsets.only(right: 6.0),
                      child: ChoiceChip(
                        selected: isSelected,
                        selectedColor: idx == 0
                            ? const Color(0xFF00E676)
                            : Colors.amberAccent,
                        backgroundColor: Colors.black87,
                        label: Text(
                          'Top ${c.rank}: 座標 $grid (${(c.confidence * 100).round()}% · ${c.matchedTileLabel})',
                          style: TextStyle(
                            color: isSelected ? Colors.black : Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        onSelected: (_) => widget.onSelectCandidate(idx),
                      ),
                    );
                  }),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 繪製原圖上的 10x10 座標網格、局部圖覆蓋區與 Top-3 候選落點標記
class _ReferenceMapOverlayPainter extends CustomPainter {
  final List<CandidateLocation> candidates;
  final int selectedIndex;
  final List<DetailTile> detailTiles;
  final bool showGrid;

  _ReferenceMapOverlayPainter({
    required this.candidates,
    required this.selectedIndex,
    required this.detailTiles,
    required this.showGrid,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. 繪製 10x10 座標網格 (A~J, 1~10)
    if (showGrid) {
      final gridPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.18)
        ..strokeWidth = 0.8;

      const rows = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J'];
      for (int i = 1; i < 10; i++) {
        final x = size.width * (i / 10.0);
        final y = size.height * (i / 10.0);
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
        canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      }

      for (int r = 0; r < 10; r++) {
        final tp = TextPainter(
          text: TextSpan(
            text: rows[r],
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(3, size.height * (r + 0.35) / 10.0));
      }
    }

    // 2. 繪製 Top-3 候選落點（先畫備選，最後畫目前選中的候選點）
    for (int i = candidates.length - 1; i >= 0; i--) {
      final c = candidates[i];
      final bool isSelected = i == selectedIndex;

      final centerPx = Offset(
        c.overviewCenterNormalized.dx * size.width,
        c.overviewCenterNormalized.dy * size.height,
      );
      final rectPx = Rect.fromCenter(
        center: centerPx,
        width: (c.overviewSizeNormalized.width * size.width).clamp(18.0, 96.0),
        height:
            (c.overviewSizeNormalized.height * size.height).clamp(18.0, 96.0),
      );

      final Color mainColor = isSelected
          ? const Color(0xFF00E676)
          : (i == 0 ? Colors.amberAccent : Colors.cyanAccent);

      if (isSelected) {
        // 繪製十字導引線直達原圖邊界，讓眼睛一秒定位
        final guidePaint = Paint()
          ..color = mainColor.withValues(alpha: 0.45)
          ..strokeWidth = 1.2;
        canvas.drawLine(
            Offset(centerPx.dx, 0), Offset(centerPx.dx, size.height), guidePaint);
        canvas.drawLine(
            Offset(0, centerPx.dy), Offset(size.width, centerPx.dy), guidePaint);

        // 發光外環
        canvas.drawCircle(
          centerPx,
          rectPx.longestSide * 0.72,
          Paint()
            ..color = mainColor.withValues(alpha: 0.28)
            ..style = PaintingStyle.fill,
        );
      }

      canvas.drawRRect(
        RRect.fromRectAndRadius(rectPx, const Radius.circular(6)),
        Paint()
          ..color = mainColor.withValues(alpha: isSelected ? 0.25 : 0.12)
          ..style = PaintingStyle.fill,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rectPx, const Radius.circular(6)),
        Paint()
          ..color = mainColor
          ..strokeWidth = isSelected ? 2.8 : 1.8
          ..style = PaintingStyle.stroke,
      );

      // 標註排名徽章 (#1, #2, #3)
      final badgeTp = TextPainter(
        text: TextSpan(
          text: ' #${c.rank} ',
          style: TextStyle(
            color: Colors.black,
            backgroundColor: mainColor,
            fontSize: isSelected ? 11 : 9.5,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      badgeTp.paint(
        canvas,
        Offset(rectPx.left, (rectPx.top - badgeTp.height - 2).clamp(0.0, size.height)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ReferenceMapOverlayPainter oldDelegate) => true;
}

/// 右上角原圖落點局部放大對比卡
class _ZoomedPatchPreviewCard extends StatelessWidget {
  final String imagePath;
  final CandidateLocation candidate;
  final String gridCode;

  const _ZoomedPatchPreviewCard({
    required this.imagePath,
    required this.candidate,
    required this.gridCode,
  });

  @override
  Widget build(BuildContext context) {
    final Alignment focalAlignment = Alignment(
      (candidate.overviewCenterNormalized.dx * 2.0 - 1.0).clamp(-1.0, 1.0),
      (candidate.overviewCenterNormalized.dy * 2.0 - 1.0).clamp(-1.0, 1.0),
    );

    return Container(
      width: 108,
      height: 124,
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF00E676), width: 1.8),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 8),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 6),
            color: const Color(0xFF00E676),
            child: Text(
              '局部放大 ($gridCode)',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.black,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: ClipRect(
              child: Transform.scale(
                scale: 4.5,
                alignment: focalAlignment,
                child: Image.file(
                  File(imagePath),
                  fit: BoxFit.cover,
                  alignment: focalAlignment,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _MiniIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6.0),
          child: Icon(icon, size: 18, color: Colors.white),
        ),
      ),
    );
  }
}
