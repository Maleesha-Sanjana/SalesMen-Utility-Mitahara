import 'package:image/image.dart' as img;

void main() {
  final testImg = img.Image(width: 100, height: 100);
  img.fill(testImg, color: img.ColorRgb8(255, 255, 255));
  final srcImg = img.Image(width: 50, height: 50);
  img.compositeImage(testImg, srcImg);
  print("Success");
}
