library mjpeg.client;

import "dart:async";
import "dart:io";
import "dart:typed_data";

import "package:dslink/utils.dart" show Scheduler, Disposable;

import "package:typed_data/typed_data.dart";
import "package:dslink/worker.dart";

import "ffmpeg.dart";

class MotionJpegClient {
  final Uri uri;

  factory MotionJpegClient(String url) {
    return new MotionJpegClient.forUri(Uri.parse(url));
  }

  MotionJpegClient.forUri(this.uri);

  Stream<Uint8List> receive(int fps, {fpsCallback(int fps), bool enableBuffer: false}) {
    Stream<Uint8List> stream;

    if (uri.scheme == "http" || uri.scheme == "https") {
      stream = _receiveHttp(
        fps,
        fpsCallback: enableBuffer ? null : fpsCallback
      );
    } else if (uri.scheme == "rtsp") {
      stream = _receiveRTSP(
        fps,
        fpsCallback: enableBuffer ? null : fpsCallback
      );
    } else if (uri.scheme == "avfoundation") {
      stream = _receiveAVFoundation(
        fps,
        fpsCallback: enableBuffer ? null : fpsCallback
      );
    } else if (uri.scheme == "dshow") {
      stream = _receiveDirectShow(
        fps,
        fpsCallback: enableBuffer ? null : fpsCallback
      );
    } else if (uri.scheme == "v4l2") {
      stream = _receiveVideo4Linux(
        fps,
        fpsCallback: enableBuffer ? null : fpsCallback
      );
    } else if (uri.scheme == "gdigrab") {
      stream = _receiveGdiGrab(
        fps,
        fpsCallback: enableBuffer ? null : fpsCallback
      );
    } else if (uri.scheme == "fbdev") {
      stream = _receiveFbDev(
        fps,
        fpsCallback: enableBuffer ? null : fpsCallback
      );
    } else if (uri.scheme == "x11grab") {
      stream = _receiveX11Grab(
        fps,
        fpsCallback: enableBuffer ? null : fpsCallback
      );
    } else if (uri.scheme == "ffmpeg") {
      stream = _receiveCustomFfmpeg(
        fps,
        fpsCallback: enableBuffer ? null : fpsCallback
      );
    } else {
      stream = new Stream.empty();
    }

    if (enableBuffer) {
      JpegBufferTransformer bufferTransformer = new JpegBufferTransformer();
      bufferTransformer.fpsCallback = fpsCallback;
      stream = stream.transform(bufferTransformer);
    }
    return stream;
  }

  Stream<Uint8List> _receiveHttp(int fps, {fpsCallback(int fps)}) async* {
    HttpClient client;
    Socket socket;
    int frames = 0;
    Disposable disposable = Scheduler.safeEvery(const Duration(seconds: 1), () {
      if (fpsCallback != null) {
        fpsCallback(frames);
        frames = 0;
      }
    });

    try {
      client = new HttpClient();
      client.badCertificateCallback = (a, b, c) => true;

      var mjpegUrl = uri.toString();
      mjpegUrl = mjpegUrl.replaceAll("{fps}", fps.toString());

      var request = await client.openUrl("GET", Uri.parse(mjpegUrl));
      request.headers.removeAll(HttpHeaders.ACCEPT_ENCODING);

      var response = await request.close();
      socket = await response.detachSocket();

      await for (List<int> data in _getFrames(socket, fpsCallback: fpsCallback)) {
        yield data;
      }
    } finally {
      if (client != null) {
        client.close(force: true);
      }

      if (socket != null) {
        socket.close();
        socket.destroy();
      }

      if (disposable != null) {
        disposable.dispose();
        disposable = null;
      }
    }
  }

  Stream<Uint8List> _receiveRTSP(int fps, {fpsCallback(int fps)}) async* {
    var ffmpeg = new FFMPEG([
      "-i",
      uri.toString().replaceAll("{fps}", fps.toString()),
      "-r",
      "${fps}",
      "-f",
      "mjpeg",
      "-"
    ]);

    await for (Uint8List data in _getFrames(ffmpeg.receive(), fpsCallback: fpsCallback)) {
      yield data;
    }
  }

  Stream<Uint8List> _receiveAVFoundation(int fps, {fpsCallback(int fps)}) async* {
    String deviceName = uri.pathSegments.join(":");

    var args = [
      "-f",
      "avfoundation"
    ];

    for (String qs in uri.queryParameters.keys) {
      args.add("-${qs}");
      if (uri.queryParameters[qs] != "true") {
        args.add(uri.queryParameters[qs]);
      }
    }

    args.addAll([
      "-i",
      deviceName,
      "-r",
      "${fps}",
      "-f",
      "mjpeg",
      "-"
    ]);

    var ffmpeg = new FFMPEG(args);

    await for (Uint8List data in _getFrames(ffmpeg.receive(), fpsCallback: fpsCallback)) {
      yield data;
    }
  }

  Stream<Uint8List> _receiveDirectShow(int fps, {fpsCallback(int fps)}) async* {
    String deviceName = uri.path.replaceAll(r"$", " ").toString();

    var args = [
      "-f",
      "dshow"
    ];

    for (String qs in uri.queryParameters.keys) {
      args.add("-${qs}");
      if (uri.queryParameters[qs] != "true") {
        args.add(uri.queryParameters[qs]);
      }
    }

    args.addAll([
      "-i",
      'video="${deviceName}"',
      "-r",
      "${fps}",
      "-f",
      "mjpeg",
      "-"
    ]);

    var ffmpeg = new FFMPEG(args);

    await for (Uint8List data in _getFrames(ffmpeg.receive(), fpsCallback: fpsCallback)) {
      yield data;
    }
  }

  Stream<Uint8List> _receiveX11Grab(int fps, {fpsCallback(int fps)}) async* {
    String inputName = uri.queryParameters["in"];

    var args = [
      "-f",
      "x11grab"
    ];

    for (String qs in uri.queryParameters.keys) {
      if (qs == "in") {
        continue;
      }

      args.add("-${qs}");
      if (uri.queryParameters[qs] != "true") {
        args.add(uri.queryParameters[qs]);
      }
    }

    args.addAll([
      "-i",
      inputName.toString(),
      "-r",
      "${fps}",
      "-f",
      "mjpeg",
      "-"
    ]);

    var ffmpeg = new FFMPEG(args);

    await for (Uint8List data in _getFrames(ffmpeg.receive(), fpsCallback: fpsCallback)) {
      yield data;
    }
  }

  Stream<Uint8List> _receiveGdiGrab(int fps, {fpsCallback(int fps)}) async* {
    var args = [
      "-f",
      "gdigrab"
    ];

    String inputType = "desktop";

    if (uri.queryParameters.containsKey("window")) {
      inputType = 'title=${uri.queryParameters["window"]}';
    }

    for (String qs in uri.queryParameters.keys) {
      if (qs == "window") {
        continue;
      }
      args.add("-${qs}");
      if (uri.queryParameters[qs] != "true") {
        args.add(uri.queryParameters[qs]);
      }
    }

    args.addAll([
      "-i",
      inputType,
      "-r",
      "${fps}",
      "-f",
      "mjpeg",
      "-"
    ]);

    var ffmpeg = new FFMPEG(args);

    await for (Uint8List data in _getFrames(ffmpeg.receive(), fpsCallback: fpsCallback)) {
      yield data;
    }
  }

  Stream<Uint8List> _receiveVideo4Linux(int fps, {fpsCallback(int fps)}) async* {
    String deviceName = uri.path;

    var args = [
      "-f",
      "v4l2"
    ];

    for (String qs in uri.queryParameters.keys) {
      args.add("-${qs}");
      if (uri.queryParameters[qs] != "true") {
        args.add(uri.queryParameters[qs]);
      }
    }

    args.addAll([
      "-i",
      deviceName,
      "-r",
      "${fps}",
      "-f",
      "mjpeg",
      "-"
    ]);

    var ffmpeg = new FFMPEG(args);

    await for (Uint8List data in _getFrames(ffmpeg.receive(), fpsCallback: fpsCallback)) {
      yield data;
    }
  }

  Stream<Uint8List> _receiveCustomFfmpeg(int fps, {fpsCallback(int fps)}) async* {
    List<String> args = uri.queryParametersAll["arg"] != null ?
      uri.queryParametersAll["arg"].toList() :
      [];

    if (args.isNotEmpty && args.last != "-") {
      args.add("-");
    }

    var ffmpeg = new FFMPEG(args);

    await for (Uint8List data in _getFrames(ffmpeg.receive(), fpsCallback: fpsCallback)) {
      yield data;
    }
  }

  Stream<Uint8List> _receiveFbDev(int fps, {fpsCallback(int fps)}) async* {
    String deviceName = uri.path;

    var args = [
      "-f",
      "fbdev"
    ];

    for (String qs in uri.queryParameters.keys) {
      args.add("-${qs}");
      if (uri.queryParameters[qs] != "true") {
        args.add(uri.queryParameters[qs]);
      }
    }

    args.addAll([
      "-i",
      deviceName,
      "-r",
      "${fps}",
      "-f",
      "mjpeg",
      "-"
    ]);

    var ffmpeg = new FFMPEG(args);

    await for (Uint8List data in _getFrames(ffmpeg.receive(), fpsCallback: fpsCallback)) {
      yield data;
    }
  }

  Stream<Uint8List> _getFrames(Stream<List<int>> stream, {
    fpsCallback(int fps)
  }) async* {
    var buff = new Uint8Buffer();
    var isInside = false;
    int frames = 0;

    Disposable disposable = Scheduler.safeEvery(const Duration(seconds: 1), () {
      if (fpsCallback != null) {
        fpsCallback(frames);
        frames = 0;
      }
    });

    try {
      await for (List<int> data in stream) {
        var len = data.length;
        for (var i = 0; i < len; i++) {
          var b = data[i];

          if (isInside) {
            if (b == 0xff && (i + 1 < len)) {
              var nb = data[i + 1];
              if (nb == 0xd9) {
                isInside = false;
                frames++;
                buff.add(0xff);
                buff.add(0xd9);
                var byteData = buff.buffer
                  .asUint8List(buff.offsetInBytes, buff.lengthInBytes);
                buff = new Uint8Buffer();
                yield byteData;
              } else {
                buff.add(b);
              }
            } else {
              buff.add(b);
            }
          }

          if (b == 0xff && i + 1 < len) {
            var nb = data[i + 1];
            if (nb == 0xd8) {
              buff.add(b);
              isInside = true;
            }
          }
        }
      }
    } finally {
      if (disposable != null) {
        disposable.dispose();
        disposable = null;
      }
    }
  }
}

Future<WorkerSocket> createMotionJpegWorker(String url, {
bool enableBuffer: false
}) async {
  return await createWorker(_motionJpegWorker, metadata: {
    "url": url,
    "enableBuffer": enableBuffer
  }).init(methods: {
    "updateFramesPerSecond": (int fps) {}
  });
}

_motionJpegWorker(Worker worker) async {
  String url = worker.get("url");
  bool enableBuffer = worker.get("enableBuffer");
  MotionJpegClient client;
  StreamSubscription<Uint8List> sub;
  int currentFps = 30;
  WorkerSocket socket;
  StreamController<Uint8List> controller;

  updateFramesPerSecond(int fps) {
    currentFps = fps;

    if (sub != null) {
      sub.cancel();
    }

    sub = client.receive(currentFps, fpsCallback: (int fps) async {
      await socket.callMethod("updateFramesPerSecond", fps);
    }, enableBuffer: enableBuffer).listen((list) {
      controller.add(list);
    });
  }

  socket = await worker.init(methods: {
    "updateFramesPerSecond": (int fps) {
      currentFps = fps;

      if (sub != null) {
        updateFramesPerSecond(currentFps);
      }
    }
  });

  controller = new StreamController<Uint8List>.broadcast(
    onListen: () {
      if (sub != null) {
        sub.cancel();
      }

      client = new MotionJpegClient(url);
      updateFramesPerSecond(currentFps);
    },
    onCancel: () {
      if (sub != null) {
        sub.cancel();
      }
    }
  );

  socket.sessions.listen((WorkerSession session) {
    StreamSubscription sub = controller.stream.listen((data) {
      session.send(data);
    });

    session.done.then((_) {
      sub.cancel();
    });
  });
}

typedef UpdateFpsCallback(int fps);

class JpegFilterQueue {
  StreamController<Uint8List> _controller;
  List<Uint8List> _buffer = [];
  UpdateFpsCallback onFpsUpdate;

  Stream<Uint8List> get stream => _controller.stream;

  JpegFilterQueue() {
    _controller = new StreamController(
      onListen: () {
        start();
      },
      onCancel: () {
        stop();
      }
    );
  }

  void add(Uint8List data) {
    _buffer.add(data);
  }

  void start() {
    stop();

    _changeSpeed(30);

    _timer2 = new Timer.periodic(const Duration(seconds: 1), (_) {
      if (onFpsUpdate != null) {
        onFpsUpdate(_frames);
        _frames = 0;
      }
    });
  }

  void _changeSpeed(int fps) {
    if (_currentSpeed == fps) {
      return;
    }

    _currentSpeed = fps;

    if (_timer != null) {
      _timer.cancel();
      _timer = null;
    }

    _timer = new Timer.periodic(new Duration(
      milliseconds: (1000 / fps).round()
    ), _updateTimer);
  }

  int _currentSpeed = -1;

  void _updateTimer(_) {
    if (_isQueueReady) {
      if (_buffer.isNotEmpty) {
        _controller.add(_buffer.removeAt(0));
        _frames++;
      } else {
        _isQueueReady = false;
        _currentBufferThreshold = 60;
      }

      if (_buffer.length <= 60) {
        _changeSpeed(5);
      } else if (_buffer.length <= 120) {
        _changeSpeed(10);
      } else {
        _changeSpeed(30);
      }
    } else {
      if (_buffer.length >= _currentBufferThreshold) {
        _isQueueReady = true;
      }
    }
  }

  int _currentBufferThreshold = 360;
  int _frames = 0;
  bool _isQueueReady = false;

  void stop() {
    if (_timer != null) {
      _timer.cancel();
      _timer = null;
    }

    if (_timer2 != null) {
      _timer2.cancel();
      _timer2 = null;
    }

    _isQueueReady = false;
  }

  void close() {
    _controller.close();
  }

  Timer _timer;
  Timer _timer2;
}

class JpegBufferTransformer implements StreamTransformer<Uint8List, Uint8List> {
  UpdateFpsCallback fpsCallback;

  @override
  Stream<Uint8List> bind(Stream<Uint8List> stream) {
    var queue = new JpegFilterQueue();
    queue.onFpsUpdate = fpsCallback;
    stream.listen(queue.add);
    return queue.stream;
  }
}
