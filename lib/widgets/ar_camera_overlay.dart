import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/match_result.dart';

/// 即時 AR 相機疊加層 (AR Camera Overlay)
///
/// 負責在鏡頭畫面上繪製：
/// 1. 中央準星 (Crosshair) 與觸控鎖定點
/// 2. 畫面中所有分割出的拼圖塊輪廓（支援點擊任一拼圖塊切換鎖定目標）
/// 3. 鎖定拼圖塊上的「AR 正向箭頭 (↑)」與順/逆時針旋轉角度指示標籤
class ArCameraOverlay extends StatelessWidget {
  final List<DetectedPiece> detectedPieces;
  final DetectedPiece? activePiece;
  final CandidateLocation? selectedCandidate;
  final Offset targetPointNormalized;
  final ValueChanged<Offset> onTapTargetNormalized;

  const ArCameraOverlay({
    super.key,
    required this.detectedPieces,
    required this.activePiece,
    required this.selectedCandidate,
    required this.targetPointNormalized,
    required this.onTapTargetNormalized,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double w = constraints.maxWidth;
        final double h = constraints.maxHeight;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            final nx = (details.localPosition.dx / w).clamp(0.05, 0.95);
            final ny = (details.localPosition.dy / h).clamp(0.05, 0.95);
            onTapTargetNormalized(Offset(nx, ny));
          },
          child: CustomPaint(
            size: Size(w, h),
            painter: _ArOverlayPainter(
              detectedPieces: detectedPieces,
              activePiece: activePiece,
              selectedCandidate: selectedCandidate,
              targetPointNormalized: targetPointNormalized,
            ),
          ),
        );
      },
    );
  }
}

class _ArOverlayPainter extends CustomPainter {
  final List<DetectedPiece> detectedPieces;
  final DetectedPiece? activePiece;
  final CandidateLocation? selectedCandidate;
  final Offset targetPointNormalized;

  _ArOverlayPainter({
    required this.detectedPieces,
    required this.activePiece,
    required this.selectedCandidate,
    required this.targetPointNormalized,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. 繪製所有非鎖定的其他拼圖塊輪廓（半透明青色外框，供點擊切換）
    for (final piece in detectedPieces) {
      if (activePiece != null && piece.id == activePiece!.id) continue;
      _drawPieceContour(
        canvas: canvas,
        size: size,
        piece: piece,
        isLocked: false,
      );
    }

    // 2. 繪製準星 (Target Crosshair)
    final crosshairCenter = Offset(
      targetPointNormalized.dx * size.width,
      targetPointNormalized.dy * size.height,
    );
    _drawCrosshair(canvas, crosshairCenter);

    // 3. 繪製目前鎖定的目標拼圖塊輪廓與 AR 正向箭頭 (↑)
    if (activePiece != null) {
      _drawPieceContour(
        canvas: canvas,
        size: size,
        piece: activePiece!,
        isLocked: true,
      );

      if (selectedCandidate != null) {
        _drawArOrientationArrowAndBadge(
          canvas: canvas,
          size: size,
          piece: activePiece!,
          candidate: selectedCandidate!,
        );
      }
    }
  }

  void _drawCrosshair(Canvas canvas, Offset center) {
    final ringPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.65)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    canvas.drawCircle(center, 22, ringPaint);
    canvas.drawLine(
        center + const Offset(-32, 0), center + const Offset(-12, 0), ringPaint);
    canvas.drawLine(
        center + const Offset(12, 0), center + const Offset(32, 0), ringPaint);
    canvas.drawLine(
        center + const Offset(0, -32), center + const Offset(0, -12), ringPaint);
    canvas.drawLine(
        center + const Offset(0, 12), center + const Offset(0, 32), ringPaint);
  }

  void _drawPieceContour({
    required Canvas canvas,
    required Size size,
    required DetectedPiece piece,
    required bool isLocked,
  }) {
    if (piece.contourPointsNormalized.length < 3) return;

    final path = Path();
    for (int i = 0; i < piece.contourPointsNormalized.length; i++) {
      final pt = Offset(
        piece.contourPointsNormalized[i].dx * size.width,
        piece.contourPointsNormalized[i].dy * size.height,
      );
      if (i == 0) {
        path.moveTo(pt.dx, pt.dy);
      } else {
        path.lineTo(pt.dx, pt.dy);
      }
    }
    path.close();

    if (isLocked) {
      // 鎖定目標：發光外框與微透底色
      final fillPaint = Paint()
        ..color = const Color(0xFF00E676).withValues(alpha: 0.14)
        ..style = PaintingStyle.fill;
      final glowPaint = Paint()
        ..color = const Color(0xFF00E676).withValues(alpha: 0.45)
        ..strokeWidth = 6.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0)
        ..style = PaintingStyle.stroke;
      final strokePaint = Paint()
        ..color = const Color(0xFF00E676)
        ..strokeWidth = 2.6
        ..style = PaintingStyle.stroke;

      canvas.drawPath(path, fillPaint);
      canvas.drawPath(path, glowPaint);
      canvas.drawPath(path, strokePaint);
    } else {
      // 其他可點擊切換的散落拼圖塊
      final strokePaint = Paint()
        ..color = Colors.cyanAccent.withValues(alpha: 0.65)
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke;
      canvas.drawPath(path, strokePaint);

      final centerPx = Offset(
        piece.centerNormalized.dx * size.width,
        piece.centerNormalized.dy * size.height,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: '#${piece.id} 點擊鎖定',
          style: const TextStyle(
            color: Colors.cyanAccent,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            backgroundColor: Colors.black54,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, centerPx - Offset(tp.width * 0.5, tp.height * 0.5));
    }
  }

  /// 在鎖定的拼圖塊中心直接畫出「AR 正向箭頭 (↑)」與旋轉提示文字
  void _drawArOrientationArrowAndBadge({
    required Canvas canvas,
    required Size size,
    required DetectedPiece piece,
    required CandidateLocation candidate,
  }) {
    final centerPx = Offset(
      piece.centerNormalized.dx * size.width,
      piece.centerNormalized.dy * size.height,
    );

    final double boxRadius = math
        .min(
          piece.boundingBoxNormalized.width * size.width,
          piece.boundingBoxNormalized.height * size.height,
        )
        .clamp(48.0, 140.0) *
        0.38;

    final double rad = candidate.upArrowAngleInCameraDeg * math.pi / 180.0;
    final Offset dir = Offset(math.cos(rad), math.sin(rad));
    final Offset tail = centerPx - dir * (boxRadius * 0.55);
    final Offset tip = centerPx + dir * (boxRadius * 0.75);

    // 繪製箭頭陰影與主幹
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.75)
      ..strokeWidth = 7.0
      ..strokeCap = StrokeCap.round;
    final arrowPaint = Paint()
      ..color = Colors.amberAccent
      ..strokeWidth = 4.2
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(tail, tip, shadowPaint);
    canvas.drawLine(tail, tip, arrowPaint);

    // 繪製箭頭尖端兩翼
    const double wingAngle = 2.6; // ~150 deg
    const double wingLen = 14.0;
    final Offset wing1 =
        tip + Offset(math.cos(rad + wingAngle), math.sin(rad + wingAngle)) * wingLen;
    final Offset wing2 =
        tip + Offset(math.cos(rad - wingAngle), math.sin(rad - wingAngle)) * wingLen;

    canvas.drawLine(tip, wing1, shadowPaint);
    canvas.drawLine(tip, wing2, shadowPaint);
    canvas.drawLine(tip, wing1, arrowPaint);
    canvas.drawLine(tip, wing2, arrowPaint);

    // 在箭頭尖端標註「正上方」
    final upLabel = TextPainter(
      text: const TextSpan(
        text: ' 正上方 ',
        style: TextStyle(
          color: Colors.black,
          backgroundColor: Colors.amberAccent,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final labelPos =
        tip + dir * 12.0 - Offset(upLabel.width * 0.5, upLabel.height * 0.5);
    upLabel.paint(canvas, labelPos);

    // 在拼圖塊上方繪製旋轉指引與邊緣類型膠囊標籤
    final String rotHint =
        _formatRotationInstruction(candidate.requiredClockwiseRotationDeg);
    final String badgeText =
        '${piece.edgeType.displayName} ｜ $rotHint ｜ ${(candidate.confidence * 100).round()}%';

    final badgeTp = TextPainter(
      text: TextSpan(
        text: badgeText,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final double topY = math.max(
      12.0,
      piece.boundingBoxNormalized.top * size.height - 32.0,
    );
    final Rect pillRect = Rect.fromCenter(
      center: Offset(
        centerPx.dx.clamp(badgeTp.width * 0.55 + 8, size.width - badgeTp.width * 0.55 - 8),
        topY,
      ),
      width: badgeTp.width + 18,
      height: badgeTp.height + 10,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(pillRect, const Radius.circular(14)),
      Paint()..color = Colors.black.withValues(alpha: 0.78),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(pillRect, const Radius.circular(14)),
      Paint()
        ..color = const Color(0xFF00E676)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke,
    );
    badgeTp.paint(
      canvas,
      pillRect.center - Offset(badgeTp.width * 0.5, badgeTp.height * 0.5),
    );
  }

  static String _formatRotationInstruction(double cwDeg) {
    final rounded = cwDeg.round();
    if (rounded.abs() <= 12) {
      return '方向已擺正 ✓';
    } else if ((rounded - 90).abs() <= 20) {
      return '順時針轉 90° ↻';
    } else if ((rounded + 90).abs() <= 20) {
      return '逆時針轉 90° ↺';
    } else if (rounded.abs() >= 160) {
      return '旋轉 180° ↻';
    } else if (rounded > 0) {
      return '順時針轉 $rounded° ↻';
    } else {
      return '逆時針轉 ${rounded.abs()}° ↺';
    }
  }

  @override
  bool shouldRepaint(covariant _ArOverlayPainter oldDelegate) => true;
}
