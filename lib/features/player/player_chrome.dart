import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One selectable track, whichever engine reports it.
///
/// [id] is engine-dependent (`vlc:<nativeId>`, `file:<url>`) and only ever
/// passed back to the surface that produced the list.
final class PlayerTrack {
  const PlayerTrack({required this.id, required this.label, this.language});

  final String id;
  final String label;
  final String? language;

  @override
  bool operator ==(Object other) =>
      other is PlayerTrack &&
      other.id == id &&
      other.label == label &&
      other.language == language;

  @override
  int get hashCode => Object.hash(id, label, language);
}

/// The player UI both engines draw over their video surface.
///
/// Deliberately engine-agnostic: every input arrives as plain values and every
/// command as a callback, so libVLC and mpv render the same chrome and the
/// user learns one set of controls. Auto-hides while playing, stays up while
/// paused, tap toggles.
class PlayerChrome extends StatefulWidget {
  const PlayerChrome({
    required this.child,
    required this.engineLabel,
    required this.playing,
    required this.buffering,
    required this.position,
    required this.duration,
    required this.bufferedFraction,
    required this.volume,
    required this.speed,
    required this.subtitleTracks,
    required this.currentSubtitleId,
    required this.audioTracks,
    required this.currentAudioId,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onVolumeChanged,
    required this.onSpeedChanged,
    required this.onSubtitleChanged,
    required this.onAudioChanged,
    required this.onFitChanged,
    this.onFullscreenChanged,
    this.fitLabel = 'Fit',
    this.isLive = false,
    this.fullscreen = false,
    super.key,
  });

  /// The video surface underneath.
  final Widget child;

  /// Shown in the corner: `libVLC` or `mpv`.
  final String engineLabel;

  final bool playing;

  /// True while the engine is buffering or stalled mid-play.
  final bool buffering;

  final Duration position;
  final Duration duration;

  /// 0..1 while the engine knows it, null otherwise (nothing is drawn).
  final double? bufferedFraction;

  /// 0..100.
  final double volume;

  final double speed;

  final List<PlayerTrack> subtitleTracks;

  /// Null means subtitles are off.
  final String? currentSubtitleId;

  final List<PlayerTrack> audioTracks;
  final String? currentAudioId;

  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeek;

  /// 0..100, already committed (called when the drag ends).
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<double> onSpeedChanged;

  /// Null disables subtitles.
  final ValueChanged<String?> onSubtitleChanged;
  final ValueChanged<String> onAudioChanged;

  /// Cycles contain → cover → fill.
  final VoidCallback onFitChanged;
  final String fitLabel;

  /// Asks the containing watch screen to remove or restore its surrounding UI.
  final ValueChanged<bool>? onFullscreenChanged;
  final bool fullscreen;

  /// Live streams cannot seek; the chrome swaps the slider for a LIVE badge.
  final bool isLive;

  @override
  State<PlayerChrome> createState() => _PlayerChromeState();
}

class _PlayerChromeState extends State<PlayerChrome> {
  static const Duration _hideAfter = Duration(seconds: 4);
  static const List<double> _speeds = <double>[0.5, 0.75, 1, 1.25, 1.5, 2];

  bool _visible = true;
  bool _dragging = false;
  double _scrub = 0;
  double _volumeDrag = 0;
  bool _volumeDragging = false;
  Offset? _doubleTapAt;
  int? _skipFeedback;
  Timer? _hideTimer;
  Timer? _feedbackTimer;

  @override
  void initState() {
    super.initState();
    _scheduleHide();
  }

  @override
  void didUpdateWidget(PlayerChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) {
      // Paused: the controls stay. Playing again: start the hide clock.
      _scheduleHide();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _feedbackTimer?.cancel();
    if (widget.fullscreen) {
      // Leave the player the way it was found.
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!widget.playing) {
      if (mounted) setState(() => _visible = true);
      return;
    }
    _hideTimer = Timer(_hideAfter, () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _poke() {
    if (!_visible) setState(() => _visible = true);
    _scheduleHide();
  }

  void _toggleVisibility() {
    if (!widget.playing) {
      _poke();
      return;
    }
    setState(() => _visible = !_visible);
    if (_visible) _scheduleHide();
  }

  Future<void> _toggleFullscreen() async {
    final next = !widget.fullscreen;
    widget.onFullscreenChanged?.call(next);
    await SystemChrome.setEnabledSystemUIMode(
      next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  void _onDoubleTapDown(TapDownDetails details) {
    _doubleTapAt = details.localPosition;
  }

  void _onDoubleTap() {
    final width = context.size?.width;
    final x = _doubleTapAt?.dx;
    if (widget.isLive || widget.duration <= Duration.zero) {
      _poke();
      return;
    }
    if (width == null || x == null) return;
    final seconds = x < width / 2 ? -10 : 10;
    final targetMs = (widget.position.inMilliseconds + seconds * 1000)
        .clamp(0, widget.duration.inMilliseconds)
        .toInt();
    widget.onSeek(Duration(milliseconds: targetMs));
    _feedbackTimer?.cancel();
    setState(() => _skipFeedback = seconds);
    _feedbackTimer = Timer(const Duration(milliseconds: 750), () {
      if (mounted) setState(() => _skipFeedback = null);
    });
    _poke();
  }

  static String _fmt(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final duration = widget.duration;
    final seekable = !widget.isLive && duration > Duration.zero;
    final position = _dragging
        ? Duration(milliseconds: (_scrub * 1000).round())
        : widget.position;
    final maxMs =
        duration.inMilliseconds <= 0 ? 1.0 : duration.inMilliseconds.toDouble();
    final value = position.inMilliseconds
        .clamp(0, duration.inMilliseconds.clamp(0, 1 << 31))
        .toDouble();

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        // Tap anywhere toggles the chrome; the gradient swallows nothing.
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _toggleVisibility,
          onDoubleTapDown: _onDoubleTapDown,
          onDoubleTap: _onDoubleTap,
        ),
        if (_skipFeedback != null)
          Positioned(
            top: 0,
            bottom: 0,
            left: _skipFeedback! < 0 ? 28 : null,
            right: _skipFeedback! > 0 ? 28 : null,
            child: IgnorePointer(
              child: Center(
                child: _SkipFeedback(seconds: _skipFeedback!),
              ),
            ),
          ),
        if (widget.buffering)
          const Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Colors.white70,
                  ),
                ),
              ),
            ),
          ),
        AnimatedOpacity(
          opacity: _visible ? 1 : 0,
          duration: const Duration(milliseconds: 250),
          child: IgnorePointer(
            ignoring: !_visible,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(
                  engineLabel: widget.engineLabel,
                  fitLabel: widget.fitLabel,
                  fullscreen: widget.fullscreen,
                  onFitChanged: () {
                    widget.onFitChanged();
                    _poke();
                  },
                  onToggleFullscreen: () {
                    unawaited(_toggleFullscreen());
                    _poke();
                  },
                ),
                Expanded(
                  child: Center(
                    child: _CenterButton(
                      playing: widget.playing,
                      onPressed: () {
                        widget.onTogglePlay();
                        _poke();
                      },
                    ),
                  ),
                ),
                _BottomBar(
                  seekable: seekable,
                  isLive: widget.isLive,
                  positionText: _fmt(position),
                  durationText: _fmt(duration),
                  sliderMax: maxMs / 1000,
                  sliderValue: _dragging ? _scrub : value / 1000,
                  bufferedFraction: widget.bufferedFraction,
                  volume: _volumeDragging ? _volumeDrag : widget.volume,
                  speed: widget.speed,
                  speeds: _speeds,
                  subtitleTracks: widget.subtitleTracks,
                  currentSubtitleId: widget.currentSubtitleId,
                  audioTracks: widget.audioTracks,
                  currentAudioId: widget.currentAudioId,
                  onSeekStart: () {
                    _dragging = true;
                    _scrub = value / 1000;
                  },
                  onSeekChanged: (seconds) {
                    setState(() => _scrub = seconds);
                    _hideTimer?.cancel();
                  },
                  onSeekEnd: (seconds) {
                    widget.onSeek(
                        Duration(milliseconds: (seconds * 1000).round()));
                    setState(() => _dragging = false);
                    _scheduleHide();
                  },
                  onVolumeChanged: (volume) {
                    setState(() {
                      _volumeDragging = true;
                      _volumeDrag = volume;
                    });
                    _hideTimer?.cancel();
                  },
                  onVolumeEnd: (volume) {
                    widget.onVolumeChanged(volume);
                    setState(() => _volumeDragging = false);
                    _poke();
                  },
                  onSpeedChanged: (speed) => widget.onSpeedChanged(speed),
                  onSubtitleChanged: widget.onSubtitleChanged,
                  onAudioChanged: widget.onAudioChanged,
                  onInteract: _poke,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.engineLabel,
    required this.fitLabel,
    required this.fullscreen,
    required this.onFitChanged,
    required this.onToggleFullscreen,
  });

  final String engineLabel;
  final String fitLabel;
  final bool fullscreen;
  final VoidCallback onFitChanged;
  final VoidCallback onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Colors.black54, Colors.transparent],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 24),
        child: Row(
          children: [
            // Which engine is rendering — the whole point of having two.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white24),
              ),
              child: Text(
                engineLabel,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Change fit ($fitLabel)',
              color: Colors.white,
              onPressed: onFitChanged,
              icon: const Icon(Icons.aspect_ratio_outlined),
            ),
            IconButton(
              tooltip: fullscreen ? 'Exit full screen' : 'Full screen',
              color: Colors.white,
              onPressed: onToggleFullscreen,
              icon: Icon(
                fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CenterButton extends StatelessWidget {
  const _CenterButton({required this.playing, required this.onPressed});

  final bool playing;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: playing ? 'Pause' : 'Play',
      child: Material(
        color: Colors.black45,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Icon(
              playing ? Icons.pause : Icons.play_arrow,
              color: Colors.white,
              size: 44,
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.seekable,
    required this.isLive,
    required this.positionText,
    required this.durationText,
    required this.sliderMax,
    required this.sliderValue,
    required this.bufferedFraction,
    required this.volume,
    required this.speed,
    required this.speeds,
    required this.subtitleTracks,
    required this.currentSubtitleId,
    required this.audioTracks,
    required this.currentAudioId,
    required this.onSeekStart,
    required this.onSeekChanged,
    required this.onSeekEnd,
    required this.onVolumeChanged,
    required this.onVolumeEnd,
    required this.onSpeedChanged,
    required this.onSubtitleChanged,
    required this.onAudioChanged,
    required this.onInteract,
  });

  final bool seekable;
  final bool isLive;
  final String positionText;
  final String durationText;
  final double sliderMax;
  final double sliderValue;
  final double? bufferedFraction;
  final double volume;
  final double speed;
  final List<double> speeds;
  final List<PlayerTrack> subtitleTracks;
  final String? currentSubtitleId;
  final List<PlayerTrack> audioTracks;
  final String? currentAudioId;
  final VoidCallback onSeekStart;
  final ValueChanged<double> onSeekChanged;
  final ValueChanged<double> onSeekEnd;
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<double> onVolumeEnd;
  final ValueChanged<double> onSpeedChanged;
  final ValueChanged<String?> onSubtitleChanged;
  final ValueChanged<String> onAudioChanged;
  final VoidCallback onInteract;

  @override
  Widget build(BuildContext context) {
    final clampedValue = sliderValue.clamp(0.0, sliderMax);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: <Color>[Colors.black87, Colors.transparent],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 24, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (bufferedFraction != null)
              SizedBox(
                height: 2,
                child: LinearProgressIndicator(
                  value: bufferedFraction!.clamp(0.0, 1.0),
                  backgroundColor: Colors.white12,
                  color: Colors.white38,
                ),
              ),
            if (isLive)
              const Row(
                children: [
                  _LiveBadge(),
                  Spacer(),
                ],
              )
            else
              Row(
                children: [
                  SizedBox(
                    width: 46,
                    child: Text(
                      positionText,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontFeatures: <FontFeature>[
                          FontFeature.tabularFigures()
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: clampedValue,
                      max: sliderMax,
                      activeColor: Colors.white,
                      inactiveColor: Colors.white24,
                      onChangeStart: (_) => onSeekStart(),
                      onChanged: seekable ? onSeekChanged : null,
                      onChangeEnd: seekable ? onSeekEnd : null,
                    ),
                  ),
                  SizedBox(
                    width: 46,
                    child: Text(
                      durationText,
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontFeatures: <FontFeature>[
                          FontFeature.tabularFigures()
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            Row(
              children: [
                IconButton(
                  tooltip: volume == 0 ? 'Unmute' : 'Mute',
                  color: Colors.white,
                  onPressed: () => onVolumeEnd(volume == 0 ? 100 : 0),
                  icon: Icon(
                    volume == 0
                        ? Icons.volume_off
                        : volume < 50
                            ? Icons.volume_down
                            : Icons.volume_up,
                  ),
                ),
                SizedBox(
                  width: 120,
                  child: Slider(
                    value: volume.clamp(0.0, 100.0),
                    max: 100,
                    activeColor: Colors.white,
                    inactiveColor: Colors.white24,
                    onChanged: onVolumeChanged,
                    onChangeEnd: onVolumeEnd,
                  ),
                ),
                PopupMenuButton<double>(
                  tooltip: 'Playback speed',
                  color: const Color(0xFF1F1F1F),
                  onSelected: (value) {
                    onSpeedChanged(value);
                    onInteract();
                  },
                  itemBuilder: (context) => [
                    for (final option in speeds)
                      PopupMenuItem<double>(
                        value: option,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 24,
                              child: option == speed
                                  ? const Icon(Icons.check,
                                      size: 18, color: Colors.white)
                                  : null,
                            ),
                            Text(
                              '${option}x',
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '${speed}x',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                if (subtitleTracks.isNotEmpty)
                  PopupMenuButton<String>(
                    tooltip: 'Subtitles',
                    color: const Color(0xFF1F1F1F),
                    onSelected: (value) {
                      onSubtitleChanged(value.isEmpty ? null : value);
                      onInteract();
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem<String>(
                        value: '',
                        child: _MenuRow(
                          label: 'Off',
                          checked: currentSubtitleId == null,
                        ),
                      ),
                      for (final track in subtitleTracks)
                        PopupMenuItem<String>(
                          value: track.id,
                          child: _MenuRow(
                            label: track.label,
                            checked: track.id == currentSubtitleId,
                          ),
                        ),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.subtitles, color: Colors.white),
                    ),
                  ),
                if (audioTracks.length > 1)
                  PopupMenuButton<String>(
                    tooltip: 'Audio track',
                    color: const Color(0xFF1F1F1F),
                    onSelected: (value) {
                      onAudioChanged(value);
                      onInteract();
                    },
                    itemBuilder: (context) => [
                      for (final track in audioTracks)
                        PopupMenuItem<String>(
                          value: track.id,
                          child: _MenuRow(
                            label: track.label,
                            checked: track.id == currentAudioId,
                          ),
                        ),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Icon(Icons.audiotrack, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SkipFeedback extends StatelessWidget {
  const _SkipFeedback({required this.seconds});

  final int seconds;

  @override
  Widget build(BuildContext context) {
    final backwards = seconds < 0;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.black54,
        shape: BoxShape.circle,
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              backwards ? Icons.replay_10 : Icons.forward_10,
              color: Colors.white,
              size: 34,
            ),
            Text(
              backwards ? '-10s' : '+10s',
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.label, required this.checked});

  final String label;
  final bool checked;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 24,
          child: checked
              ? const Icon(Icons.check, size: 18, color: Colors.white)
              : null,
        ),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ],
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.redAccent.shade700,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'LIVE',
        style: TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 1,
        ),
      ),
    );
  }
}
