import 'dart:ffi';

import 'package:flutter/material.dart';
import 'package:flutter_client_sse/constants/sse_request_type_enum.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_client_sse/flutter_client_sse.dart';

String origin = 'https://hub.inlive.app';
String apiOrigin = 'https://api.inlive.app';
String apiVersion = 'v1';
String apiKey = '';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: VideoConferencePage(),
    );
  }
}

class VideoConferencePage extends StatefulWidget {
  const VideoConferencePage({super.key});

  @override
  _VideoConferencePageState createState() => _VideoConferencePageState();
}

class _VideoConferencePageState extends State<VideoConferencePage> {
  final List<RTCVideoRenderer> _videoRenderer = [];
  RTCPeerConnection? _peerConnection;

  String? accessToken = '';
  bool _isListening = false;

  final roomId = 'test';
  String? clientId = '';

  @override
  void initState() {
    super.initState();

    createAccessToken(apiKey, apiOrigin, apiVersion).then((tokens) async {
      if (tokens == null) {
        print('Failed to create access token');
        return;
      }

      if (tokens['access_token'] == null) {
        print('Failed to create access token');
        return;
      }

      accessToken = tokens['access_token']!;

      bool roomExists =
          await doesRoomExist(accessToken!, origin, apiVersion, roomId);
      if (!roomExists) {
        try {
          await createRoom(accessToken!, origin, apiVersion, roomId);
        } catch (e) {
          print('Failed to create room');
          return;
        }
      }

      clientId = await registerClient(accessToken!, roomId);
      if (clientId == null) {
        print('Failed to register client');
        return;
      }

      _peerConnection =
          await _createPeerConnection(accessToken!, roomId, clientId!);
      if (_peerConnection == null) {
        print('Failed to create peer connection');
        return;
      }

      connect(_peerConnection!);
    });
  }

  @override
  void reassemble() {
    super.reassemble();
    // Call your function here
    closeSession();
  }

  @override
  void dispose() {
    super.dispose();
    closeSession();
    _peerConnection?.dispose();
  }

  Future<void> closeSession() async {
    for (var renderer in _videoRenderer) {
      renderer.dispose();
      renderer.srcObject?.getTracks().forEach((track) {
        track.stop();
      });
      renderer.srcObject?.dispose();
    }

    await _peerConnection?.close();

    await leaveRoom(accessToken!, roomId, clientId!);
  }

  Future<RTCPeerConnection> _createPeerConnection(
      String accessToken, String roomId, String clientId) async {
    final configuration = {
      'iceServers': [
        {
          'urls': 'turn:turn.inlive.app:3478',
          'username': 'inlive',
          'credential': 'inlivesdkturn'
        },
      ]
    };

    final pc = await createPeerConnection(configuration);

    pc.onIceCandidate = (candidate) async {
      if (candidate != Null) {
        final resp = await http.post(
          Uri.parse('$origin/$apiVersion/rooms/$roomId/candidate/$clientId'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode(candidate.toMap()),
        );

        if (resp.statusCode > 299) {
          print('Failed to send ICE candidate: ${resp.statusCode}');
        }
      }
    };

    pc.onIceConnectionState = (state) {
      print('ICE connection state: $state');
    };

    pc.onRemoveTrack = (stream, track) {
      print('Track removed: ${track.id}');
      setState(() {
        for (var renderer in _videoRenderer) {
          if (renderer.srcObject?.id == stream.id) {
            stream.getTracks().forEach((track) {
              track.stop();
            });

            stream.dispose();

            renderer.srcObject = null;
            renderer.dispose();
            _videoRenderer.remove(renderer);
            break;
          }
        }
      });
    };

    pc.onTrack = (e) {
      print('New track added: ${e.track.id}');
      if (e.track.kind == 'video') {
        final renderer = RTCVideoRenderer();
        final stream = e.streams[0];

        renderer.initialize().then((_) {
          setState(() {
            _videoRenderer.add(renderer);
            renderer.srcObject = stream;
          });
        });
      }
    };

    pc.onRenegotiationNeeded = () async {
      final allowNegotiateResponse = await http.post(
        Uri.parse(
            '$origin/$apiVersion/rooms/$roomId/isallownegotiate/$clientId'),
      );

      if (allowNegotiateResponse.statusCode == 200) {
        final offer = await pc.createOffer();
        await pc.setLocalDescription(offer);

        final localDescription = await pc.getLocalDescription();

        final negotiateResponse = await http.put(
          Uri.parse('$origin/$apiVersion/rooms/$roomId/negotiate/$clientId'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode(localDescription!.toMap()),
        );

        final negotiateJSON = json.decode(negotiateResponse.body);
        final answer = negotiateJSON['data']['answer'];
        final sdpAnswer = RTCSessionDescription(answer['sdp'], answer['type']);
        await pc.setRemoteDescription(sdpAnswer);

        if (_isListening == false) {
          _listenEvents(accessToken, pc, roomId, clientId);
          _isListening = true;
        }
      }
    };

    return pc;
  }

  void connect(RTCPeerConnection pc) async {
    final mediaConstraints = {
      'audio': true,
      'video': {
        'facingMode': 'user',
      }
    };

    final stream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
    final localRenderer = RTCVideoRenderer();
    await localRenderer.initialize();
    setState(() {
      localRenderer.srcObject = stream;
      _videoRenderer.add(localRenderer);
    });

    stream.getTracks().forEach((track) {
      pc.addTrack(track, stream);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Video Conference'),
      ),
      body: Column(
        children: [
          Expanded(
            child: GridView.builder(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 16 / 9,
              ),
              itemCount: _videoRenderer.length,
              itemBuilder: (context, index) {
                return SizedBox(
                  height: 200,
                  child: RTCVideoView(_videoRenderer[index]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

Future<Map<String, String>?> createAccessToken(
    String apiKey, String tokenAPIOrigin, String apiVersion) async {
  if (apiKey.isEmpty) {
    print(
        'Please set your API key, you can get it from https://studio.inlive.app');
    return null;
  }

  final response = await http.post(
    Uri.parse('$tokenAPIOrigin/$apiVersion/keys/accesstoken'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    },
  );

  if (response.statusCode == 200) {
    final token = json.decode(response.body);
    return {
      'access_token': token['data']['access_token'],
      'refresh_token': token['data']['refresh_token'],
    };
  } else {
    print('Failed to create access token: ${response.statusCode}');
    return null;
  }
}

Future<bool> doesRoomExist(
    String accessToken, String origin, String apiVersion, String roomId) async {
  final response = await http.get(
    Uri.parse('$origin/$apiVersion/rooms/$roomId'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $accessToken',
    },
  );

  if (response.statusCode == 200) {
    return true;
  } else if (response.statusCode == 404) {
    return false;
  } else {
    print('Failed to check room existence: ${response.statusCode}');
    return false;
  }
}

Future createRoom(
    String apiKey, String apiOrigin, String apiVersion, String roomId) async {
  final response = await http.post(
    Uri.parse('$apiOrigin/$apiVersion/rooms/create'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
    },
    body: json.encode({
      'id': roomId,
      'name': roomId,
    }),
  );

  if (response.statusCode >= 300) {
    print('Failed to create room: ${response.statusCode}');
    throw Exception('Failed to create room: ${response.statusCode}');
  }
}

void _listenEvents(
    String accessToken, RTCPeerConnection pc, String roomId, String clientId) {
  final sse = SSEClient.subscribeToSSE(
    method: SSERequestType.GET,
    url: '$origin/$apiVersion/rooms/$roomId/events/$clientId',
    header: {
      'Authorization': 'Bearer $accessToken',
    },
  );

  sse.listen((e) {
    () async {
      print('event: ${e.event}');
      print('data: ${e.data}');
      switch (e.event) {
        case 'candidate':
          var map = json.decode(e.data!);
          final candidate = RTCIceCandidate(
            map['candidate'],
            map['sdpMid'],
            map['sdpMLineIndex'],
          );
          try {
            await pc.addCandidate(candidate);
          } catch (e) {
            print('Failed to add ICE candidate: $e');
          }
          break;
        case 'offer':
          print('offer event: ${e.data}');
          var map = json.decode(e.data!);
          final offer = RTCSessionDescription(map['sdp'], map['type']);

          await pc.setRemoteDescription(offer);
          final answer = await pc.createAnswer();
          await pc.setLocalDescription(answer);

          final offerSDP = await pc.getLocalDescription();

          await http.put(
            Uri.parse('$origin/$apiVersion/rooms/$roomId/negotiate/$clientId'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(offerSDP!.toMap()),
          );
          break;
        case 'tracks_added':
          print('tracks added event: ${e.data}');

          final tracks = json.decode(e.data!)['tracks'];
          print('tracks added event: $tracks');

          final tracksources = tracks.keys.map((key) {
            return {'track_id': key, 'source': 'media'};
          }).toList();

          await http.put(
            Uri.parse(
                '$origin/$apiVersion/rooms/$roomId/settracksources/$clientId'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(tracksources),
          );
          break;
        case 'tracks_available':
          print('tracks available event: ${e.data}');
          final tracks = json.decode(e.data!)['tracks'];
          print('tracks available event: $tracks');

          final subscribeRequests = tracks.keys.map((key) {
            return {'track_id': key, 'client_id': tracks[key]['client_id']};
          }).toList();

          await http.post(
            Uri.parse(
                '$origin/$apiVersion/rooms/$roomId/subscribetracks/$clientId'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(subscribeRequests),
          );
          break;
      }
    }();
  });
}

Future<void> leaveRoom(
    String accessToken, String roomId, String clientId) async {
  final response = await http.post(
    Uri.parse('$origin/$apiVersion/rooms/$roomId/leave/$clientId'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $accessToken',
    },
  );

  if (response.statusCode >= 200 && response.statusCode < 300) {
    print('Left the room successfully');
  } else {
    print('Failed to leave the room: ${response.statusCode}');
  }
}

Future<String?> registerClient(String accessToken, String roomId) async {
  final response = await http.post(
    Uri.parse('$origin/$apiVersion/rooms/$roomId/register'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $accessToken',
    },
  );

  if (response.statusCode >= 200 && response.statusCode < 300) {
    print('Client registered successfully');
    final client = json.decode(response.body);
    final clientId = client['data']['client_id'];
    return clientId;
  } else {
    print('Failed to register client: ${response.statusCode}');
    return null;
  }
}
