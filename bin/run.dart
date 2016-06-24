import "dart:async";
import "dart:typed_data";

import "package:dslink/dslink.dart";
import "package:dslink_mjpeg/mjpeg.dart";
import "package:dslink/worker.dart";

import "package:dslink/nodes.dart";

LinkProvider link;

main(List<String> args) async {
  link = new LinkProvider(
    args,
    "MJPEG-",
    isResponder: true,
    nodes: {
      "addFeedClient": {
        r"$is": "addFeedClient",
        r"$name": "Add Feed",
        r"$invokable": "write",
        r"$params": [
          {
            "name": "Name",
            "type": "string",
            "placeholder": "My Feed",
            "description": "Feed Name"
          },
          {
            "name": "Url",
            "type": "string",
            "placeholder": "http://my.feed/video.mjpeg?fps={fps}",
            "description": "Url to the Feed"
          }
        ]
      }
    },
    profiles: {
      "addFeedClient": (String path) => new AddFeedClientAction(path),
      "feedClient": (String path) => new FeedClientNode(path),
      "callback": (String path) => new CallbackNode(path),
      "remove": (String path) => new DeleteActionNode.forParent(
        path,
        link.provider as SimpleNodeProvider,
        onDelete: () {
          link.save();
        })
    },
    autoInitialize: false,
    encodePrettyJson: true
  );

  link.configure();
  link.init();
  link.connect();
  link.save();
}

class AddFeedClientAction extends SimpleNode {
  AddFeedClientAction(String path) : super(path);

  @override
  onInvoke(Map<String, dynamic> params) async {
    String feedName = params["Name"];
    String url = params["Url"];

    if (feedName == null) {
      throw new Exception("Feed name was not specified.");
    }

    if (url == null) {
      throw new Exception("Url to the feed was not specified.");
    }

    String realName = NodeNamer.createName(feedName);

    link.addNode("/${realName}", {
      r"$is": "feedClient",
      r"$type": "binary",
      r"$name": feedName,
      r"$url": url,
      "remove": {
        r"$name": "Remove",
        r"$is": "remove"
      }
    });

    link.save();
  }
}

const bool _useIsolate = false;

class FeedClientNode extends SimpleNode {
  FeedClientNode(String path) : super(path);

  MotionJpegClient client;
  SimpleNode currentFpsNode;
  SimpleNode highestFpsNode;
  CallbackNode requestedFpsNode;
  SimpleNode receivedFramesNode;

  int _currentRequestedFps = 0;
  int _maxFps = 0;
  int _receivedFrames = 0;

  @override
  void onCreated() {
    String url = configs[r"$url"];
    int fps = configs[r"$fps"];

    if (fps is! int) {
      fps = 30;
    }

    _currentRequestedFps = fps;

    if (url == null) {
      return;
    }

    client = new MotionJpegClient(url);

    currentFpsNode = link.addNode("${path}/currentFramesPerSecond", {
      r"$name": "Current FPS",
      "@unit": "fps",
      r"$type": "number"
    });
    currentFpsNode.serializable = false;

    highestFpsNode = link.addNode("${path}/highestFramesPerSecond", {
      r"$name": "Highest FPS",
      "@unit": "fps",
      r"$type": "number"
    });
    highestFpsNode.serializable = false;

    receivedFramesNode = link.addNode("${path}/receivedFramesCount", {
      r"$name": "Received Frames",
      r"$type": "number",
    });
    receivedFramesNode.serializable = false;

    requestedFpsNode = link.addNode("${path}/requestedFramesPerSecond", {
      r"$name": "Requested FPS",
      r"$type": "number",
      "@unit": "fps",
      r"$is": "callback",
      r"$writable": "write",
      "?value": _currentRequestedFps
    });
    requestedFpsNode.serializable = false;

    requestedFpsNode.onValueSetCallback = (value) {
      if (value is num) {
        var number = value.toInt();

        if (number > 0) {
          if (_subscribers > 0) {
            configs[r"$fps"] = number;
            link.save();

            _changeFps(fps);

            return false;
          }
        }
      }
      return true;
    };

    SimpleNode removeNode = link.addNode("${path}/remove", {
      r"$name": "Remove",
      r"$is": "remove",
      r"$invokable": "write"
    });
    removeNode.serializable = false;

    if (_useIsolate) {
      new Future(() async {
        _socket = await createMotionJpegWorker(url, enableBuffer: false);
      });
    }
  }

  @override
  void onSubscribe() {
    _subscribers++;
    _check();
  }

  @override
  void onUnsubscribe() {
    _subscribers--;
    _check();
  }

  void _check() {
    if (_subscribers >= 1) {
      if (_sub == null) {
        _start(_currentRequestedFps);
      }
    } else {
      _stop();
    }
  }

  void _onFpsUpdate(int fps) {
    currentFpsNode.updateValue(fps);
    if (_maxFps < fps) {
      _maxFps = fps;
      highestFpsNode.updateValue(_maxFps);
    }
  }

  void _handle(Uint8List list) {
    var data = list.buffer.asByteData(
      list.offsetInBytes,
      list.lengthInBytes
    );
    updateValue(data, force: true);
    _receivedFrames++;
    receivedFramesNode.updateValue(_receivedFrames);
  }

  void _start(int fps) {
    _changeFps(fps);
  }

  void _stop() {
    if (_socket != null) {
      if (_session != null) {
        _session.close();
        _session = null;
      }
    } else {
      if (_sub != null) {
        _sub.cancel();
        _sub = null;
      }
    }
    _receivedFrames = 0;
    _onFpsUpdate(0);
    receivedFramesNode.updateValue(0);
  }

  void _changeFps(int fps) {
    if (_sub != null) {
      _sub.cancel();
    }

    _currentRequestedFps = fps;

    if (_socket != null) {
      _socket.callMethod("updateFramesPerSecond", _currentRequestedFps);
      _socket.createSession().then((session) {
        _session = session;
        session.messages.listen(_handle);
      });
    } else {
      _sub = client.receive(
        fps,
        fpsCallback: _onFpsUpdate,
        enableBuffer: false
      ).listen(_handle);
    }
  }

  @override
  Map serialize(bool withChildren) {
    var out = super.serialize(withChildren);
    out.remove(r"?value");
    return out;
  }

  @override
  void onRemoving() {
    _stop();
    if (_socket != null) {
      _socket.kill();
      _socket = null;
    }
  }

  int _subscribers = 0;
  StreamSubscription<Uint8List> _sub;

  WorkerSocket _socket;
  WorkerSession _session;
}
