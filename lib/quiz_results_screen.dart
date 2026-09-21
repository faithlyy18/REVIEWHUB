import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// QuizResultsScreen — Teacher views all student submissions for a quiz.
///
/// REDESIGN NOTES (mobile-friendly pass):
/// - The old layout wrapped everything (summary bar + list) in a single
///   Center > SingleChildScrollView > Column, which visually centered the
///   whole block vertically on screen — producing a large empty gap above
///   the summary bar whenever there were few submissions. Layout is now a
///   fixed-height summary card up top + Expanded ListView below, so the
///   summary always sits directly under the AppBar and the list scrolls
///   independently.
/// - The heavy full-bleed dark-blue summary band is now a compact, rounded
///   "dashboard card" with a 2x2 icon grid and hairline dividers between
///   cells, instead of two loosely-spaced Rows.
/// - Tapping Highest/Lowest still reveals which student(s) hold that score
///   (same feature as before), but now opens a small bottom sheet instead
///   of expanding the stat cell inline — this keeps all four grid cells a
///   uniform height instead of shifting the grid around on tap.
/// - Result cards use tighter padding and a flat border instead of heavy
///   elevation, and the top/bottom-scorer badge only shows once its stat
///   has been revealed (same behavior as before).
class QuizResultsScreen extends StatefulWidget {
  final String quizId;
  final String quizTitle;

  const QuizResultsScreen({
    super.key,
    required this.quizId,
    required this.quizTitle,
  });

  @override
  State<QuizResultsScreen> createState() => _QuizResultsScreenState();
}

class _QuizResultsScreenState extends State<QuizResultsScreen> {
  static const _brand = Color(0xFF1A237E);

  // Tracks whether the Highest/Lowest scorer name(s) have been revealed
  // (via the bottom sheet triggered by tapping that stat tile). Kept in
  // State so the highlight badges on the result cards persist across
  // Firestore stream rebuilds.
  bool _showHighestName = false;
  bool _showLowestName = false;

  void _revealAndShowSheet({
    required String title,
    required String names,
    required String scoreLabel,
    required Color accent,
    required IconData icon,
    required VoidCallback markRevealed,
  }) {
    markRevealed();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: accent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: accent, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: _brand)),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                names.isEmpty ? 'No submissions yet.' : names,
                style: const TextStyle(fontSize: 14, color: Colors.black87),
              ),
              const SizedBox(height: 4),
              Text(scoreLabel,
                  style: TextStyle(fontSize: 12, color: Colors.grey[500])),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F8),
      appBar: AppBar(
        backgroundColor: _brand,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Quiz Results',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            Text(widget.quizTitle,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        // Removed .orderBy('submittedAt') — combining where() + orderBy()
        // on different fields requires a Firestore composite index. Without
        // that index the stream silently returns empty. Sorted client-side
        // instead (see below).
        stream: FirebaseFirestore.instance
            .collection('quiz_results')
            .where('quizId', isEqualTo: widget.quizId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: _brand),
            );
          }

          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.error_outline_rounded,
                        size: 48, color: Colors.red[300]),
                    const SizedBox(height: 10),
                    const Text('Could not load results.',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                    const SizedBox(height: 6),
                    Text('${snapshot.error}',
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey),
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            );
          }

          // Sort client-side — newest first, no composite index needed.
          final results =
              List<QueryDocumentSnapshot>.from(snapshot.data?.docs ?? []);
          results.sort((a, b) {
            final aT = (a.data() as Map)['submittedAt'];
            final bT = (b.data() as Map)['submittedAt'];
            if (aT == null && bT == null) return 0;
            if (aT == null) return 1;
            if (bT == null) return -1;
            return (bT as dynamic).compareTo(aT as dynamic);
          });

          if (results.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.assignment_outlined,
                      size: 64, color: Colors.grey[400]),
                  const SizedBox(height: 12),
                  Text('No submissions yet.',
                      style: TextStyle(color: Colors.grey[600], fontSize: 16)),
                  const SizedBox(height: 4),
                  Text("Students haven't taken this quiz yet.",
                      style:
                          TextStyle(color: Colors.grey[400], fontSize: 13)),
                ],
              ),
            );
          }

          // ── Summary stats ──────────────────────────────────────────────
          final scores = results
              .map((r) =>
                  (r.data() as Map<String, dynamic>)['score'] as int? ?? 0)
              .toList();
          final total = ((results.first.data()
                  as Map<String, dynamic>)['totalQuestions'] as int?) ??
              1;
          final avg = scores.isEmpty
              ? 0.0
              : scores.reduce((a, b) => a + b) / scores.length;
          final highest =
              scores.isEmpty ? 0 : scores.reduce((a, b) => a > b ? a : b);
          final lowest =
              scores.isEmpty ? 0 : scores.reduce((a, b) => a < b ? a : b);

          // Identify which student(s) hold the highest/lowest score. If
          // several students tie, list all of their names.
          final highestDocs = results
              .where((r) => (r.data() as Map)['score'] == highest)
              .toList();
          final lowestDocs = results
              .where((r) => (r.data() as Map)['score'] == lowest)
              .toList();
          final highestNames = highestDocs
              .map((d) => (d.data() as Map)['studentName'] ?? 'Unknown Student')
              .toSet()
              .join(', ');
          final lowestNames = lowestDocs
              .map((d) => (d.data() as Map)['studentName'] ?? 'Unknown Student')
              .toSet()
              .join(', ');

          const maxContentWidth = 600.0;

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: maxContentWidth),
              child: Column(
                children: [
                  // ── Compact summary card ─────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                    child: Container(
                      decoration: BoxDecoration(
                        color: _brand,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: _brand.withOpacity(0.25),
                            blurRadius: 14,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          IntrinsicHeight(
                            child: Row(
                              children: [
                                Expanded(
                                  child: _StatTile(
                                    icon: Icons.people_alt_rounded,
                                    value: '${results.length}',
                                    label: 'Submissions',
                                  ),
                                ),
                                const VerticalDivider(
                                    color: Colors.white24,
                                    width: 1,
                                    thickness: 1,
                                    indent: 14,
                                    endIndent: 14),
                                Expanded(
                                  child: _StatTile(
                                    icon: Icons.bar_chart_rounded,
                                    value: '${avg.toStringAsFixed(1)}/$total',
                                    label: 'Average',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Divider(
                              color: Colors.white24, height: 1, thickness: 1),
                          IntrinsicHeight(
                            child: Row(
                              children: [
                                Expanded(
                                  child: _StatTile(
                                    icon: Icons.emoji_events_rounded,
                                    value: '$highest/$total',
                                    label: 'Highest',
                                    tappable: true,
                                    onTap: () => _revealAndShowSheet(
                                      title: 'Highest Score',
                                      names: highestNames,
                                      scoreLabel: '$highest out of $total',
                                      accent: const Color(0xFF2E7D32),
                                      icon: Icons.emoji_events_rounded,
                                      markRevealed: () => setState(
                                          () => _showHighestName = true),
                                    ),
                                  ),
                                ),
                                const VerticalDivider(
                                    color: Colors.white24,
                                    width: 1,
                                    thickness: 1,
                                    indent: 14,
                                    endIndent: 14),
                                Expanded(
                                  child: _StatTile(
                                    icon: Icons.trending_down_rounded,
                                    value: '$lowest/$total',
                                    label: 'Lowest',
                                    tappable: true,
                                    onTap: () => _revealAndShowSheet(
                                      title: 'Lowest Score',
                                      names: lowestNames,
                                      scoreLabel: '$lowest out of $total',
                                      accent: const Color(0xFFC62828),
                                      icon: Icons.trending_down_rounded,
                                      markRevealed: () => setState(
                                          () => _showLowestName = true),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // ── Results list ──────────────────────────────────────
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(14, 6, 14, 20),
                      itemCount: results.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final doc = results[index];
                        final result = doc.data() as Map<String, dynamic>;
                        final score = result['score'] as int? ?? 0;
                        final totalQ = result['totalQuestions'] as int? ?? 1;
                        final percent = (score / totalQ * 100).round();
                        final studentName =
                            result['studentName'] ?? 'Unknown Student';
                        final yearLevel = result['yearLevel'] ?? '';

                        // Only badge the card once the instructor has
                        // tapped the corresponding Highest/Lowest tile.
                        final isHighest =
                            score == highest && _showHighestName;
                        final isLowest = score == lowest &&
                            lowest != highest &&
                            _showLowestName;

                        Color scoreColor;
                        if (percent >= 75) {
                          scoreColor = Colors.green;
                        } else if (percent >= 50) {
                          scoreColor = Colors.orange;
                        } else {
                          scoreColor = Colors.red;
                        }

                        final borderColor = isHighest
                            ? const Color(0xFF2E7D32)
                            : isLowest
                                ? const Color(0xFFC62828)
                                : const Color(0xFFE8EAF6);

                        return Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: borderColor,
                              width: (isHighest || isLowest) ? 1.4 : 1,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.04),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          padding: const EdgeInsets.all(11),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              CircleAvatar(
                                radius: 20,
                                backgroundColor: scoreColor.withOpacity(0.15),
                                child: Text(
                                  '$percent%',
                                  style: TextStyle(
                                    color: scoreColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            studentName,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13.5),
                                          ),
                                        ),
                                        if (isHighest) ...[
                                          const SizedBox(width: 5),
                                          const Text('🏆',
                                              style: TextStyle(fontSize: 12)),
                                        ],
                                        if (isLowest) ...[
                                          const SizedBox(width: 5),
                                          Icon(Icons.trending_down_rounded,
                                              size: 14,
                                              color: Colors.red[400]),
                                        ],
                                      ],
                                    ),
                                    if (yearLevel.toString().isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        yearLevel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 11.5,
                                            color: Color(0xFF9096B4)),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 9, vertical: 5),
                                decoration: BoxDecoration(
                                  color: scoreColor.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                      color: scoreColor.withOpacity(0.35)),
                                ),
                                child: Text(
                                  '$score/$totalQ',
                                  style: TextStyle(
                                    color: scoreColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One cell in the 2x2 summary grid. Every tile — tappable or not — keeps
/// the same icon/value/label structure and height, so the grid never
/// shifts around (unlike the old inline-reveal version).
class _StatTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final bool tappable;
  final VoidCallback? onTap;

  const _StatTile({
    required this.icon,
    required this.value,
    required this.label,
    this.tappable = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: const TextStyle(color: Colors.white70, fontSize: 11)),
              if (tappable) ...[
                const SizedBox(width: 2),
                const Icon(Icons.info_outline_rounded,
                    size: 11, color: Colors.white70),
              ],
            ],
          ),
        ],
      ),
    );

    if (!tappable) return content;

    return InkWell(onTap: onTap, child: content);
  }
}