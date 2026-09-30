import 'package:flutter/material.dart';

/// Small info box telling users which account/email to use.
/// Shared by the login and register screens.
class GoogleAccountNotice extends StatelessWidget {
  final String message;
  const GoogleAccountNotice({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFE8EAF6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFC5CAE9)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline_rounded,
              size: 16, color: Color(0xFF1A237E)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 12,
                height: 1.35,
                color: Color(0xFF1A237E),
              ),
            ),
          ),
        ],
      ),
    );
  }
}