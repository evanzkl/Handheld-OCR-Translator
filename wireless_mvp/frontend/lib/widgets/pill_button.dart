import 'package:flutter/material.dart';

/// Colors/shapes mirror the Tkinter "Pill.TButton" / "HUD.TCombobox" styles
/// used throughout laptop_mvp/gui (see widgets.py, camera_view.py, result_view.py).
const pillBackground = Color(0xFFF9F9F9);
const pillForeground = Color(0xFF1F2937);
const pillBorderColor = Color(0xFFD6DCE3);
const pillDisabledBg = Color(0xFFF1F1F1);
const pillDisabledFg = Color(0xFF8A8A8A);
const accuracyForeground = Color(0xFF1C7D45);

class PillButton extends StatelessWidget {
  const PillButton({super.key, required this.label, this.icon, this.onPressed, this.busy = false});

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !busy;
    return SizedBox(
      height: 40,
      child: OutlinedButton.icon(
        onPressed: enabled ? onPressed : null,
        style: OutlinedButton.styleFrom(
          backgroundColor: enabled ? pillBackground : pillDisabledBg,
          foregroundColor: enabled ? pillForeground : pillDisabledFg,
          side: BorderSide(color: enabled ? pillBorderColor : const Color(0xFFE5E7EB)),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          textStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
        ),
        icon: busy
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : (icon != null ? Icon(icon, size: 18) : const SizedBox.shrink()),
        label: Text(label),
      ),
    );
  }
}

/// Rounded HUD-style dropdown matching the Tkinter "HUD.TCombobox" style.
class HudDropdown<T> extends StatelessWidget {
  const HudDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.itemLabel,
    required this.onChanged,
  });

  final T? value;
  final List<T> items;
  final String Function(T) itemLabel;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: pillBackground,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: pillBorderColor),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          icon: const Icon(Icons.keyboard_arrow_down, size: 18, color: pillForeground),
          style: const TextStyle(color: pillForeground, fontWeight: FontWeight.w600, fontSize: 13),
          dropdownColor: pillBackground,
          items: items
              .map((item) => DropdownMenuItem(value: item, child: Text(itemLabel(item), overflow: TextOverflow.ellipsis)))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// Circular icon button matching the eye-toggle / settings corner buttons.
class CircleIconButton extends StatelessWidget {
  const CircleIconButton({super.key, required this.icon, this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: pillBackground,
      shape: const CircleBorder(side: BorderSide(color: pillBorderColor)),
      child: IconButton(
        icon: Icon(icon, color: pillForeground, size: 20),
        onPressed: onPressed,
      ),
    );
  }
}
