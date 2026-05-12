import 'package:flutter/material.dart';

class DispatchColors {
  static const Color ink = Color(0xff16181d);
  static const Color muted = Color(0xff626977);
  static const Color border = Color(0xffd9dde6);
  static const Color surface = Color(0xfffbfbfd);
  static const Color panel = Color(0xffffffff);
  static const Color accent = Color(0xff1f6feb);
  static const Color danger = Color(0xffc7362f);
  static const Color ok = Color(0xff238636);
}

ThemeData buildDispatchTheme() {
  ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: DispatchColors.accent,
    brightness: Brightness.light,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme.copyWith(
      surface: DispatchColors.surface,
      primary: DispatchColors.accent,
      error: DispatchColors.danger,
    ),
    scaffoldBackgroundColor: DispatchColors.surface,
    fontFamily: 'SF Pro Display',
    textTheme: const TextTheme(
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: DispatchColors.ink,
      ),
      titleMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: DispatchColors.ink,
      ),
      bodyMedium: TextStyle(fontSize: 13, color: DispatchColors.ink),
      bodySmall: TextStyle(fontSize: 12, color: DispatchColors.muted),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: DispatchColors.panel,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: DispatchColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: DispatchColors.border),
      ),
    ),
  );
}

class DispatchSection extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;

  const DispatchSection({
    required this.title,
    required this.child,
    this.trailing,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: DispatchColors.panel,
        border: Border.all(color: DispatchColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          const Divider(height: 1, color: DispatchColors.border),
          child,
        ],
      ),
    );
  }
}

class DispatchBadge extends StatelessWidget {
  final String label;
  final Color color;

  const DispatchBadge({required this.label, required this.color, super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 11,
        ),
      ),
    );
  }
}

class DenseIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const DenseIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 18),
        onPressed: onPressed,
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
