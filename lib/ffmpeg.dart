library ffmpeg.client;

import "dart:async";
import "dart:io";
import "dart:typed_data";

class FFMPEG {
  final List<String> args;

  FFMPEG(this.args);

  Stream<Uint8List> receive() async* {
    Process process;

    try {
      process = await Process.start("ffmpeg", args);

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
