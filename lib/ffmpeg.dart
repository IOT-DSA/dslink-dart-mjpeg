library ffmpeg.client;

import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:logging/logging.dart";
import "package:dslink/utils.dart";

class FFMPEG {
  final List<String> args;

  FFMPEG(this.args);

  Stream<Uint8List> receive() async* {
    Process process;

    try {
      process = await Process.start("ffmpeg", args);

      process.stderr.listen((bytes) {
        if (logger.isLoggable(Level.FINE)) {
          var msg = const Utf8Decoder(allowMalformed: true)
            .convert(bytes)
            .trim();
          if (msg.isNotEmpty) {
            logger.fine("[ffmpeg] ${msg}");
          }
        }
      });

      await for (List<int> data in process.stdout) {
        if (data is Uint8List) {
          yield data;
        } else {
          yield new Uint8List.fromList(data);
        }
      }
    } finally {
      if (process != null) {
        process.kill();
      }
    }
  }
}
