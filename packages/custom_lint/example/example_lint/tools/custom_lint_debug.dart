import 'dart:io';
import 'package:custom_lint/basic_runner.dart';

Future<void> main() async {
  await customLint(Directory.current.parent);
}
