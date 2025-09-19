import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // لالتقاط أي أخطاء Flutter مبكّرة في اللوج
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    dev.log(
      'FlutterError: ${details.exceptionAsString()}\n${details.stack}',
      name: 'VarPlayer',
    );
  };

  // حبس أي استثناء غير مضبوط على مستوى الزون
  runZonedGuarded(() {
    runApp(const VarPlayerApp());
  }, (error, stack) {
    dev.log('ZonedError: $error\n$stack', name: 'VarPlayer');
  });
}

class VarPlayerApp extends StatelessWidget {
  const VarPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: PlayerScreen(),
    );
  }
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  static const _channel = MethodChannel('com.varplayerios/links');

  VideoPlayerController? _ctrl;
  String? _currentUrl;
  Map<String, String> _currentHeaders = {};

  int _epoch = 0;
  Timer? _retryTimer;
  Duration _retryDelay = const Duration(seconds: 3);
  static const Duration _retryDelayMax = Duration(seconds: 15);

  String _status = 'No stream loaded';

  bool _showUi = true;
  Timer? _autoHideTimer;
  double _volume = 1.0;
  bool _fitCover = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // نخلي تغييرات الـ UI بعد أول فريم لتفادي مشاكل iOS
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);

      _initLinksSafe();
      // للاختبار فقط (احذفها بعد التأكد):
      // _handleIncomingLink('https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8');
    });
  }

  Future<void> _initLinksSafe() async {
    try {
      await _initLinks();
    } catch (e, st) {
      dev.log('initLinks crashed: $e\n$st', name: 'VarPlayer');
      if (mounted) setState(() => _status = 'Init links failed');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _ctrl?.pause();
    }
  }

  Future<void> _initLinks() async {
    try {
      final initial = await _channel.invokeMethod<String>('getInitialLink');
      if (initial != null && initial.isNotEmpty) {
        _handleIncomingLink(initial);
        try {
          await _channel.invokeMethod('clearInitialLink');
        } catch (_) {}
      }
    } catch (e, st) {
      dev.log('getInitialLink error: $e\n$st', name: 'VarPlayer');
    }

    // استقبال الروابط أثناء التشغيل
    _channel.setMethodCallHandler((call) async {
      try {
        if (call.method == 'onNewIntent') {
          final link = call.arguments as String?;
          if (link != null && link.isNotEmpty) {
            _handleIncomingLink(link);
          }
        }
      } catch (e, st) {
        dev.log('onNewIntent handler error: $e\n$st', name: 'VarPlayer');
      }
      return null;
    });
  }

  // ---------------- Parse & headers ----------------
  String? _normalizeLink(String raw) {
    try {
      if (raw.startsWith('varplayer://')) {
        final uri = Uri.parse(raw);
        if (uri.host == 'play') {
          final t = uri.queryParameters['t'];
          if (t != null && t.isNotEmpty) {
            try {
              var norm = t.replaceAll('-', '+').replaceAll('_', '/');
              final pad = norm.length % 4;
              if (pad > 0) norm = norm.padRight(norm.length + (4 - pad), '=');
              final decoded = utf8.decode(base64.decode(norm));
              final u = _extractUrlFromPayload(decoded) ?? decoded;
              if (u.startsWith('http')) return u;
            } catch (_) {
              if (t.startsWith('http')) return t;
            }
          }
          _currentHeaders = _mergeHeaders(
            _defaultHeaders(null),
            _headersFromQuery(uri.queryParametersAll),
          );
        }
        return null;
      }

      if (raw.startsWith('http://') || raw.startsWith('https://')) {
        final uri = Uri.parse(raw);
        _currentHeaders = _mergeHeaders(
          _defaultHeaders(uri),
          _headersFromQuery(uri.queryParametersAll),
        );
        return raw;
      }

      final maybe = _extractUrlFromPayload(raw);
      if (maybe != null) return maybe;
    } catch (e) {
      dev.log('normalize error: $e', name: 'VarPlayer');
    }
    return null;
  }

  String? _extractUrlFromPayload(String payload) {
    try {
      final data = json.decode(payload);
      if (data is Map) {
        final u = (data['url'] ?? data['main'] ?? data['m'])?.toString();
        final hRaw = data['headers'] ?? data['h'];
        final fromJson = <String, String>{};
        if (hRaw is Map) {
          hRaw.forEach((k, v) {
            if (k != null && v != null) {
              fromJson[k.toString()] = v.toString();
            }
          });
        }
        if (u != null && (u.startsWith('http://') || u.startsWith('https://'))) {
          final uri = Uri.tryParse(u);
          _currentHeaders = _mergeHeaders(_defaultHeaders(uri), fromJson);
          return u;
        }
      }
    } catch (_) {}
    return null;
  }

  Map<String, String> _defaultHeaders(Uri? uri) {
    final referer = uri != null ? '${uri.scheme}://${uri.host}/' : null;
    return {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124 Safari/537.36',
      'Accept': '*/*',
      'Accept-Language': 'en-US,en;q=0.9,ar;q=0.8',
      'Connection': 'keep-alive',
      if (referer != null) 'Referer': referer,
      if (referer != null) 'Origin': referer.substring(0, referer.length - 1),
      'Icy-MetaData': '1',
    };
  }

  Map<String, String> _headersFromQuery(Map<String, List<String>> all) {
    final out = <String, String>{};
    String? firstOf(List<String>? l) => (l != null && l.isNotEmpty) ? l.first : null;

    final ua = firstOf(all['ua']);
    final referer = firstOf(all['referer']) ?? firstOf(all['ref']);
    final origin = firstOf(all['origin']);

    if (ua != null && ua.isNotEmpty) out['User-Agent'] = ua;
    if (referer != null && referer.isNotEmpty) out['Referer'] = referer;
    if (origin != null && origin.isNotEmpty) out['Origin'] = origin;

    final hs = all['header'] ?? all['h'];
    if (hs != null) {
      for (final item in hs) {
        final idx = item.indexOf(':');
        if (idx > 0) {
          final k = item.substring(0, idx).trim();
          final v = item.substring(idx + 1).trim();
          if (k.isNotEmpty) out[k] = v;
        }
      }
    }
    return out;
  }

  Map<String, String> _mergeHeaders(
      Map<String, String> base, Map<String, String> override) {
    final res = Map<String, String>.from(base);
    override.forEach((k, v) => res[k] = v);
    return res;
  }

  void _handleIncomingLink(String link) {
    _currentHeaders = _defaultHeaders(null);
    final url = _normalizeLink(link);
    if (url == null) {
      setState(() => _status = 'Bad link');
      return;
    }
    if (_currentHeaders.isEmpty) {
      final uri = Uri.tryParse(url);
      _currentHeaders = _defaultHeaders(uri);
    }

    setState(() {
      _currentUrl = url;
      _status = 'Resolving...';
      _retryDelay = const Duration(seconds: 3);
    });

    _openResolved(url, _currentHeaders);
  }

  // ===================== Resolver =====================
  Future<void> _openResolved(String url, Map<String, String> headers) async {
    try {
      final res = await _resolveStream(url, headers);
      dev.log('Resolved -> ${res.url}', name: 'VarPlayer');
      setState(() {
        _currentUrl = res.url;
        _currentHeaders = res.headers;
        _status = 'Loading...';
      });
      await _openSafe(res.url, res.headers);
    } catch (e, st) {
      dev.log('resolve failed: $e\n$st', name: 'VarPlayer');
      setState(() => _status = 'Resolve failed. Retrying...');
      _scheduleRetry(url, _epoch, headers, forceResolve: true);
    }
  }

  // Raw-triple-quoted regex
  static final RegExp _absM3u8 = RegExp(
    r'''https?:\/\/[^\s"'<>]+\.m3u8[^\s"'<>]*''',
    caseSensitive: false,
  );
  static final RegExp _srcM3u8 = RegExp(
    r'''src\s*=\s*["']([^"']+\.m3u8[^"']*)["']''',
    caseSensitive: false,
  );
  static final RegExp _anyAttrM3u8 = RegExp(
    r'''(data-file|data-src|href)\s*=\s*["']([^"']+\.m3u8[^"']*)["']''',
    caseSensitive: false,
  );
  static final RegExp _metaRefresh = RegExp(
    r'''<meta[^>]+http-equiv=["']refresh["'][^>]+content=["'][^"']*url=([^"']+)["']''',
    caseSensitive: false,
  );

  Future<_Resolved> _resolveStream(
      String rawUrl, Map<String, String> baseHeaders) async {
    final client = http.Client();
    final headers = Map<String, String>.from(baseHeaders);
    Uri start = Uri.parse(rawUrl);

    // 1) HEAD
    try {
      final head =
          await client.head(start, headers: headers).timeout(const Duration(seconds: 8));
      _mergeSetCookieInto(headers, head.headers);
      final reqUrl = head.request?.url ?? start;
      final ct = head.headers['content-type'] ?? '';
      if (_looksLikeStream(reqUrl.toString(), ct)) {
        client.close();
        return _Resolved(reqUrl.toString(), headers);
      }
    } catch (_) {}

    // 2) GET
    final resp =
        await client.get(start, headers: headers).timeout(const Duration(seconds: 12));
    _mergeSetCookieInto(headers, resp.headers);
    final finalUrl = resp.request?.url ?? start;
    final ct2 = resp.headers['content-type'] ?? '';

    if (_looksLikeStream(finalUrl.toString(), ct2)) {
      client.close();
      return _Resolved(finalUrl.toString(), headers);
    }

    final body = resp.body;
    final mAbs = _absM3u8.firstMatch(body);
    if (mAbs != null) {
      client.close();
      return _Resolved(mAbs.group(0)!, headers);
    }

    final mSrc = _srcM3u8.firstMatch(body);
    if (mSrc != null) {
      client.close();
      return _Resolved(finalUrl.resolve(mSrc.group(1)!).toString(), headers);
    }

    final mAny = _anyAttrM3u8.firstMatch(body);
    if (mAny != null) {
      client.close();
      return _Resolved(finalUrl.resolve(mAny.group(2)!).toString(), headers);
    }

    final mMeta = _metaRefresh.firstMatch(body);
    if (mMeta != null) {
      final maybe = finalUrl.resolve(mMeta.group(1)!);
      if (maybe.toString().toLowerCase().contains('.m3u8')) {
        client.close();
        return _Resolved(maybe.toString(), headers);
      }
    }

    client.close();
    return _Resolved(finalUrl.toString(), headers);
  }

  bool _looksLikeStream(String url, String contentType) {
    final u = url.toLowerCase();
    final ct = contentType.toLowerCase();
    if (u.contains('.m3u8') || u.contains('.mp4') || u.contains('.mpd') || u.contains('.ts')) {
      return true;
    }
    if (ct.contains('application/vnd.apple.mpegurl') ||
        ct.contains('application/x-mpegurl') ||
        ct.contains('application/dash+xml') ||
        ct.contains('video/')) {
      return true;
    }
    return false;
  }

  void _mergeSetCookieInto(
      Map<String, String> headers, Map<String, String> respHeaders) {
    final cookies = respHeaders.entries
        .where((e) => e.key.toLowerCase() == 'set-cookie')
        .map((e) => e.value.split(';').first.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (cookies.isNotEmpty) {
      final existing = headers['Cookie'];
      final merged = <String>[];
      if (existing != null && existing.isNotEmpty) merged.add(existing);
      merged.addAll(cookies);
      headers['Cookie'] = merged.join('; ');
    }
  }

  // ================== Open + Retry ==================
  Future<void> _openSafe(String url, Map<String, String> headers) async {
    final int myEpoch = ++_epoch;

    _retryTimer?.cancel();

    try {
      await _ctrl?.dispose();
    } catch (_) {}

    final ctrl = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: headers,
      videoPlayerOptions: const VideoPlayerOptions(
        mixWithOthers: true,
        allowBackgroundPlayback: false,
      ),
    );
    _ctrl = ctrl;

    try {
      await ctrl.initialize();
      if (!mounted || myEpoch != _epoch) return;

      await ctrl.setLooping(true);
      await ctrl.setVolume(_volume);
      await ctrl.play();

      ctrl.addListener(() {
        final v = ctrl.value;
        if (v.hasError) {
          if (mounted && myEpoch == _epoch) {
            setState(() => _status = 'Error. Retrying...');
            _scheduleRetry(url, myEpoch, headers);
          }
        }
      });

      setState(() => _status = 'Playing');
      _kickAutoHide();
    } catch (e, st) {
      dev.log('initialize failed: $e\n$st', name: 'VarPlayer');
      if (mounted && myEpoch == _epoch) {
        setState(() => _status = 'Init failed. Retrying...');
        _scheduleRetry(url, myEpoch, headers);
      }
    }
  }

  void _scheduleRetry(String url, int myEpoch, Map<String, String> headers,
      {bool forceResolve = false}) {
    if (!mounted || myEpoch != _epoch) return;

    _retryDelay = _retryDelay * 2;
    if (_retryDelay > _retryDelayMax) _retryDelay = _retryDelayMax;

    _retryTimer?.cancel();
    _retryTimer = Timer(_retryDelay, () async {
      if (!mounted || myEpoch != _epoch) return;
      if (forceResolve) {
        await _openResolved(url, headers);
      } else {
        await _openSafe(url, headers);
      }
    });
  }

  void _kickAutoHide() {
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _showUi = false);
    });
  }

  bool get _isVod {
    final d = _ctrl?.value.duration;
    return d != null && d.inMilliseconds > 0 && d != Duration.zero;
  }

  String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  void dispose() {
    _epoch++;
    _retryTimer?.cancel();
    _autoHideTimer?.cancel();
    try {
      _ctrl?.dispose();
    } catch (_) {}
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initialized = _ctrl?.value.isInitialized == true;
    final buffering = _ctrl?.value.isBuffering == true;
    final playing = _ctrl?.value.isPlaying == true;
    final aspect = (_ctrl?.value.aspectRatio ?? 0) == 0
        ? 16 / 9
        : _ctrl!.value.aspectRatio;

    final duration = _ctrl?.value.duration ?? Duration.zero;
    final position = _ctrl?.value.position ?? Duration.zero;
    final buffered = _ctrl?.value.buffered ?? const <DurationRange>[];

    return GestureDetector(
      onTap: () {
        setState(() => _showUi = !_showUi);
        if (_showUi) _kickAutoHide();
      },
      onDoubleTapDown: (details) {
        if (!_isVod || _ctrl == null) return;
        final w = MediaQuery.of(context).size.width;
        final dx = details.localPosition.dx;
        final back = dx < w / 2;
        final delta = const Duration(seconds: 10);
        final newPos = back ? position - delta : position + delta;
        _ctrl!.seekTo(newPos < Duration.zero ? Duration.zero : newPos);
        setState(() => _showUi = true);
        _kickAutoHide();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // FULLSCREEN video
            Positioned.fill(
              child: Center(
                child: (initialized && _ctrl != null)
                    ? FittedBox(
                        fit: _fitCover ? BoxFit.cover : BoxFit.contain,
                        child: SizedBox(
                          width: 1280,
                          height: 720,
                          child: AspectRatio(
                            aspectRatio: aspect,
                            child: VideoPlayer(_ctrl!),
                          ),
                        ),
                      )
                    : Text(
                        _status,
                        style: const TextStyle(color: Colors.white70),
                      ),
              ),
            ),

            if (initialized && buffering)
              const Positioned.fill(
                child: IgnorePointer(
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),

            if (initialized && _showUi)
              Positioned.fill(
                child: Container(
                  color: Colors.black38,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Top bar
                      SafeArea(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: Text(
                                _isVod ? 'VOD' : 'LIVE',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 12),
                              ),
                            ),
                            Row(
                              children: [
                                IconButton(
                                  tooltip: _fitCover ? 'Contain' : 'Cover',
                                  onPressed: () {
                                    setState(() => _fitCover = !_fitCover);
                                    _kickAutoHide();
                                  },
                                  icon: const Icon(Icons.fit_screen,
                                      color: Colors.white),
                                ),
                                const SizedBox(width: 8),
                              ],
                            ),
                          ],
                        ),
                      ),

                      // Center controls
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            iconSize: 64,
                            color: Colors.white,
                            onPressed: () async {
                              if (playing) {
                                await _ctrl!.pause();
                              } else {
                                await _ctrl!.play();
                              }
                              setState(() {});
                              _kickAutoHide();
                            },
                            icon: Icon(
                              playing ? Icons.pause_circle : Icons.play_circle,
                            ),
                          ),
                          const SizedBox(width: 16),
                          IconButton(
                            iconSize: 40,
                            color: Colors.white70,
                            tooltip: 'Reload',
                            onPressed: _currentUrl == null
                                ? null
                                : () => _openResolved(
                                      _currentUrl!,
                                      _currentHeaders,
                                    ),
                            icon: const Icon(Icons.refresh),
                          ),
                        ],
                      ),

                      // Bottom bar
                      SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_isVod)
                                _BufferedBar(
                                  duration: duration,
                                  position: position,
                                  ranges: buffered,
                                  onSeek: (to) => _ctrl?.seekTo(to),
                                )
                              else
                                const LinearProgressIndicator(
                                  value: null,
                                  backgroundColor: Colors.white24,
                                  minHeight: 3,
                                ),
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Text(
                                    _isVod ? _fmt(position) : 'LIVE',
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 12),
                                  ),
                                  const Spacer(),
                                  if (_isVod)
                                    Text(
                                      _fmt(duration),
                                      style: const TextStyle(
                                          color: Colors.white70, fontSize: 12),
                                    ),
                                  const SizedBox(width: 12),
                                  const Icon(Icons.volume_up,
                                      size: 18, color: Colors.white70),
                                  SizedBox(
                                    width: 140,
                                    child: Slider(
                                      min: 0,
                                      max: 1,
                                      value: _volume,
                                      onChanged: (v) async {
                                        setState(() => _volume = v);
                                        await _ctrl?.setVolume(_volume);
                                        _kickAutoHide();
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Resolved {
  final String url;
  final Map<String, String> headers;
  _Resolved(this.url, this.headers);
}

/// Progress + buffered (VOD)
class _BufferedBar extends StatelessWidget {
  final Duration duration;
  final Duration position;
  final List<DurationRange> ranges;
  final ValueChanged<Duration> onSeek;

  const _BufferedBar({
    required this.duration,
    required this.position,
    required this.ranges,
    required this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    final totalMs = duration.inMilliseconds.clamp(1, 1 << 31);
    final playedMs = position.inMilliseconds.clamp(0, totalMs);

    return LayoutBuilder(
      builder: (ctx, cons) {
        final w = cons.maxWidth;
        double msToPx(int ms) => (ms / totalMs) * w;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            final ratio = (d.localPosition.dx / w).clamp(0.0, 1.0);
            onSeek(Duration(milliseconds: (totalMs * ratio).round()));
          },
          onHorizontalDragUpdate: (d) {
            final ratio = (d.localPosition.dx / w).clamp(0.0, 1.0);
            onSeek(Duration(milliseconds: (totalMs * ratio).round()));
          },
          child: SizedBox(
            height: 24,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(height: 3, color: Colors.white24),
                // buffered ranges
                ...ranges.map((r) {
                  final left = msToPx(r.start.inMilliseconds);
                  final right = msToPx(r.end.inMilliseconds);
                  final width = (right - left).clamp(0.0, w);
                  return Positioned(
                    left: left.clamp(0.0, w),
                    width: width,
                    top: 0,
                    bottom: 0,
                    child: Container(height: 3, color: Colors.white54),
                  );
                }),
                // played
                Positioned(
                  left: 0,
                  width: msToPx(playedMs),
                  top: 0,
                  bottom: 0,
                  child: Container(height: 3, color: Colors.white),
                ),
                // handle
                Positioned(
                  left: (msToPx(playedMs) - 6).clamp(0.0, w - 12),
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
