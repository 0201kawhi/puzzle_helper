import 'dart:io';
import 'package:flutter/material.dart';

/// 互動式四點透視校正裁切元件
///
/// 顯示拍攝或匯入的拼圖外盒照片，並允許使用者拖曳四個角點（左上、右上、右下、左下），
/// 以便將斜拍梯形拉正為標準矩形的全貌底圖。
class PerspectiveCropView extends StatefulWidget {
  final String imagePath;
  final List<Offset> initialCornersNormalized;
  final ValueChanged<List<Offset>> onCornersChanged;

  const PerspectiveCropView({
    super.key,
    required this.imagePath,
    required this.initialCornersNormalized,
    required this.onCornersChanged,
  });

  @override
  State<PerspectiveCropView> createState() => _PerspectiveCropViewState();
}

class _PerspectiveCropViewState extends State<PerspectiveCropView> {
  late List<Offset> _corners;
  int? _draggingIndex;

  @override
  void initState() {
    super.initState();
    _corners = List<Offset>.from(widget.initialCornersNormalized);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxW = constraints.maxWidth;
        final double maxH = constraints.maxHeight;

        return GestureDetector(
          onPanStart: (details) {
            final pos = details.localPosition;
            int? closestIdx;
            double minDist = 48.0; // 觸控吸附半徑
            for (int i = 0; i < _corners.length; i++) {
              final pt = Offset(_corners[i].dx * maxW, _corners[i].dy * maxH);
              final d = (pt - pos).distance;
              if (d < minDist) {
                minDist = d;
                closestIdx = i;
              }
            }
            setState(() => _draggingIndex = closestIdx);
          },
          onPanUpdate: (details) {
            if (_draggingIndex == null) return;
            final pos = details.localPosition;
            final nx = (pos.dx / maxW).clamp(0.0, 1.0);
            final ny = (pos.dy / maxH).clamp(0.0, 1.0);
            setState(() {
              _corners[_draggingIndex!] = Offset(nx, ny);
            });
            widget.onCornersChanged(_corners);
          },
          onPanEnd: (_) => setState(() => _draggingIndex = null),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.file(
                File(widget.imagePath),
                fit: BoxFit.fill,
              ),
              CustomPaint(
                painter: _PerspectiveQuadPainter(
                  cornersNormalized: _corners,
                  activeIndex: _draggingIndex,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PerspectiveQuadPainter extends CustomPainter {
  final List<Offset> cornersNormalized;
  final int? activeIndex;

  _PerspectiveQuadPainter({
    required this.cornersNormalized,
    required this.activeIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (cornersNormalized.length != 4) return;

    final pts = cornersNormalized
        .map((c) => Offset(c.dx * size.width, c.dy * size.height))
        .toList();

    final quadPath = Path()
      ..moveTo(pts[0].dx, pts[0].dy)
      ..lineTo(pts[1].dx, pts[1].dy)
      ..lineTo(pts[2].dx, pts[2].dy)
      ..lineTo(pts[3].dx, pts[3].dy)
      ..close();

    // 遮暗四邊形外部區域
    final fullPath = Path()..addRect(Offset.zero & size);
    final outsidePath =
        Path.combine(PathOperation.difference, fullPath, quadPath);
    canvas.drawPath(
      outsidePath,
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );

    // 繪製透視輔助九宮格線
    final gridPaint = Paint()
      ..color = Colors.cyanAccent.withValues(alpha: 0.35)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    for (int i = 1; i <= 2; i++) {
      final t = i / 3.0;
      final topPt = Offset.lerp(pts[0], pts[1], t)!;
      final botPt = Offset.lerp(pts[3], pts[2], t)!;
      canvas.drawLine(topPt, botPt, gridPaint);

      final leftPt = Offset.lerp(pts[0], pts[3], t)!;
      final rightPt = Offset.lerp(pts[1], pts[2], t)!;
      canvas.drawLine(leftPt, rightPt, gridPaint);
    }

    // 繪製主邊框
    final borderPaint = Paint()
      ..color = Colors.cyanAccent
      ..strokeWidth = 2.8
      ..style = PaintingStyle.stroke;
    canvas.drawPath(quadPath, borderPaint);

    // 繪製四個可拖曳角點控制柄
    const labels = ['左上', '右上', '右下', '左下'];
    for (int i = 0; i < 4; i++) {
      final isDragging = activeIndex == i;
      final radius = isDragging ? 16.0 : 12.0;

      canvas.drawCircle(
        pts[i],
        radius + 4,
        Paint()..color = Colors.black.withValues(alpha: 0.45),
      );
      canvas.drawCircle(
        pts[i],
        radius,
        Paint()
          ..color = isDragging ? Colors.amberAccent : Colors.cyanAccent
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        pts[i],
        radius,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 2.0
          ..style = PaintingStyle.stroke,
      );

      final tp = TextPainter(
        text: TextSpan(
          text: labels[i],
          style: const TextStyle(
            color: Colors.black87,
            fontSize: 9,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pts[i] - Offset(tp.width * 0.5, tp.height * 0.5));
    }
  }

  @override
  bool shouldRepaint(covariant _PerspectiveQuadPainter oldDelegate) => true;
}
