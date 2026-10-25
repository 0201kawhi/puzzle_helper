import 'dart:math' as math;
import 'dart:ui';
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// 外盒/完成圖四點透視校正服務
///
/// 自動偵測拼圖外盒或完成圖的四個角點，並透過單應性透視變換
/// (Perspective Warp) 將傾斜變形的梯形影像拉正為標準矩形。
class PerspectiveCorrector {
  /// 自動偵測影像中拼圖外盒/海報的四個角點（回傳正規化座標 0.0 ~ 1.0，順序：左上、右上、右下、左下）
  static List<Offset> detectDefaultCorners(String imagePath) {
    cv.Mat? src;
    cv.Mat? gray;
    cv.Mat? blurred;
    cv.Mat? edges;
    cv.Mat? kernel;
    cv.Mat? closed;
    try {
      src = cv.imread(imagePath);
      if (src.isEmpty) {
        return _defaultInsetCorners();
      }
      final int w = src.cols;
      final int h = src.rows;

      gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
      blurred = cv.gaussianBlur(gray, (5, 5), 1.5);
      edges = cv.canny(blurred, 50, 150);
      kernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
      closed = cv.morphologyEx(edges, cv.MORPH_CLOSE, kernel);

      final (contours, _) =
          cv.findContours(closed, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);

      double maxArea = 0;
      List<Offset>? bestQuad;
      final double minValidArea = w * h * 0.20;

      for (int i = 0; i < contours.length; i++) {
        final contour = contours[i];
        final area = cv.contourArea(contour);
        if (area < minValidArea || area <= maxArea) continue;

        final peri = cv.arcLength(contour, true);
        final approx = cv.approxPolyDP(contour, 0.025 * peri, true);
        if (approx.length == 4 && cv.isContourConvex(approx)) {
          maxArea = area;
          final pts = <Offset>[];
          for (int j = 0; j < 4; j++) {
            final pt = approx[j];
            pts.add(Offset(pt.x / w, pt.y / h));
          }
          bestQuad = _orderCornersClockwise(pts);
        }
        approx.dispose();
      }
      contours.dispose();

      return bestQuad ?? _defaultInsetCorners();
    } catch (_) {
      return _defaultInsetCorners();
    } finally {
      src?.dispose();
      gray?.dispose();
      blurred?.dispose();
      edges?.dispose();
      kernel?.dispose();
      closed?.dispose();
    }
  }

  /// 將四個正規化角點（左上、右上、右下、左下）所圍區域拉正為標準矩形並存檔
  static ({int width, int height}) warpPerspectiveAndSave({
    required String inputPath,
    required String outputPath,
    required List<Offset> cornersNormalized,
    int maxDimension = 2048,
  }) {
    final src = cv.imread(inputPath);
    if (src.isEmpty) {
      throw Exception('無法讀取參考圖片：$inputPath');
    }

    try {
      final double w = src.cols.toDouble();
      final double h = src.rows.toDouble();
      final ordered = _orderCornersClockwise(cornersNormalized);

      final pTL = Offset(ordered[0].dx * w, ordered[0].dy * h);
      final pTR = Offset(ordered[1].dx * w, ordered[1].dy * h);
      final pBR = Offset(ordered[2].dx * w, ordered[2].dy * h);
      final pBL = Offset(ordered[3].dx * w, ordered[3].dy * h);

      final double widthTop = (pTR - pTL).distance;
      final double widthBottom = (pBR - pBL).distance;
      final double heightLeft = (pBL - pTL).distance;
      final double heightRight = (pBR - pTR).distance;

      double targetW = math.max(widthTop, widthBottom);
      double targetH = math.max(heightLeft, heightRight);

      if (targetW <= 10 || targetH <= 10) {
        targetW = w;
        targetH = h;
      }

      // 限制最大邊長以兼顧高畫質與手機記憶體效能
      final double longest = math.max(targetW, targetH);
      if (longest > maxDimension) {
        final scale = maxDimension / longest;
        targetW *= scale;
        targetH *= scale;
      }

      final int outW = targetW.round().clamp(320, maxDimension);
      final int outH = targetH.round().clamp(320, maxDimension);

      final srcPts = cv.VecPoint2f.fromList([
        cv.Point2f(pTL.dx, pTL.dy),
        cv.Point2f(pTR.dx, pTR.dy),
        cv.Point2f(pBR.dx, pBR.dy),
        cv.Point2f(pBL.dx, pBL.dy),
      ]);
      final dstPts = cv.VecPoint2f.fromList([
        cv.Point2f(0, 0),
        cv.Point2f(outW.toDouble(), 0),
        cv.Point2f(outW.toDouble(), outH.toDouble()),
        cv.Point2f(0, outH.toDouble()),
      ]);

      final transform = cv.getPerspectiveTransform2f(srcPts, dstPts);
      final warped = cv.warpPerspective(src, transform, (outW, outH));

      cv.imwrite(outputPath, warped);

      srcPts.dispose();
      dstPts.dispose();
      transform.dispose();
      warped.dispose();

      return (width: outW, height: outH);
    } finally {
      src.dispose();
    }
  }

  /// 將任意順序的四個點排序為：[左上, 右上, 右下, 左下]
  static List<Offset> _orderCornersClockwise(List<Offset> pts) {
    if (pts.length != 4) return _defaultInsetCorners();
    final sortedBySum = List<Offset>.from(pts)
      ..sort((a, b) => (a.dx + a.dy).compareTo(b.dx + b.dy));
    final tl = sortedBySum.first;
    final br = sortedBySum.last;

    final sortedByDiff = List<Offset>.from(pts)
      ..sort((a, b) => (a.dy - a.dx).compareTo(b.dy - b.dx));
    final tr = sortedByDiff.first;
    final bl = sortedByDiff.last;

    return [tl, tr, br, bl];
  }

  static List<Offset> _defaultInsetCorners() => const [
        Offset(0.06, 0.06),
        Offset(0.94, 0.06),
        Offset(0.94, 0.94),
        Offset(0.06, 0.94),
      ];
}
