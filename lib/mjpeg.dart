library mjpeg.client;

import "dart:async";
import "dart:io";
import "dart:typed_data";

import "package:dslink/utils.dart" show Scheduler, Disposable;

import "package:typed_data/typed_data.dart";
import "package:dslink/worker.dart";

class MotionJpegClient {
  final String url;

  MotionJpegClient(this.url);

  Stream<Uint8List> receive(int fps, {fpsCallback(int fps), bool enableBuffer: false}) {
    Stream<Uint8List> stream = _receive(
      fps,
      fpsCallback: enableBuffer ? null : fpsCallback
    );

    if (enableBuffer) {
      JpegBufferTransformer bufferTransformer = new JpegBufferTransformer();
      bufferTransformer.fpsCallback = fpsCallback;
      stream = stream.transform(bufferTransformer);
    }
    return stream;
  }

  Stream<Uint8List> _receive(int fps, {fpsCallback(int fps)}) async* {
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

      var mjpegUrl = url;
      mjpegUrl = mjpegUrl.replaceAll("{fps}", fps.toString());

      var request = await client.openUrl("GET", Uri.parse(mjpegUrl));
      request.headers.removeAll(HttpHeaders.ACCEPT_ENCODING);

      var response = await request.close();
      socket = await response.detachSocket();
      var buff = new Uint8Buffer();
      var isInside = false;

      await for (List<int> data in socket) {
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
