import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:crm_whatsapp/core.dart';

/// Reproductor a pantalla completa para un video ya subido a Storage.
///
/// Es público porque lo reusa el editor de respuestas rápidas para que el
/// operador confirme que la plantilla guardada es el video que cree: sin esto
/// sólo vería el nombre del archivo.
class FullscreenVideo extends StatefulWidget {
  final String url;
  final bool loop;
  final List<Widget> actions;
  const FullscreenVideo({
    super.key,
    required this.url,
    required this.loop,
    this.actions = const [],
  });

  @override
  State<FullscreenVideo> createState() => _FullscreenVideoState();
}

class _FullscreenVideoState extends State<FullscreenVideo> {
  late final VideoPlayerController _controller;
  bool _initialized = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _controller.setLooping(widget.loop);
    _controller.initialize().then((_) {
      if (!mounted) return;
      setState(() => _initialized = true);
      _controller.play();
    }).catchError((e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    });
    _controller.addListener(_onPlayerUpdate);
  }

  void _onPlayerUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onPlayerUpdate);
    _controller.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: widget.actions,
      ),
      body: _error != null
          ? Center(
              child: Text('No se pudo cargar el video',
                  style: const TextStyle(color: Colors.white70)),
            )
          : !_initialized
              ? const Center(
                  child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation<Color>(primaryAqua)),
                )
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      child: AspectRatio(
                        aspectRatio: _controller.value.aspectRatio,
                        child: VideoPlayer(_controller),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.7),
                              Colors.transparent,
                            ],
                          ),
                        ),
                        padding: EdgeInsets.fromLTRB(
                            12, 24, 12, 16 + MediaQuery.of(context).padding.bottom),
                        child: Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                _controller.value.isPlaying
                                    ? Icons.pause
                                    : Icons.play_arrow,
                                color: Colors.white,
                                size: 32,
                              ),
                              onPressed: () {
                                if (_controller.value.isPlaying) {
                                  _controller.pause();
                                } else {
                                  _controller.play();
                                }
                              },
                            ),
                            Expanded(
                              child: SliderTheme(
                                data: const SliderThemeData(
                                  trackHeight: 2.5,
                                  thumbShape: RoundSliderThumbShape(
                                      enabledThumbRadius: 6),
                                  activeTrackColor: primaryAqua,
                                  inactiveTrackColor: Colors.white24,
                                  thumbColor: primaryAqua,
                                ),
                                child: Slider(
                                  min: 0,
                                  max: _controller.value.duration.inMilliseconds
                                      .toDouble()
                                      .clamp(1, double.infinity),
                                  value: _controller.value.position.inMilliseconds
                                      .clamp(
                                          0,
                                          _controller.value.duration.inMilliseconds)
                                      .toDouble(),
                                  onChanged: (v) {
                                    _controller
                                        .seekTo(Duration(milliseconds: v.toInt()));
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${_fmt(_controller.value.position)} / ${_fmt(_controller.value.duration)}',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
