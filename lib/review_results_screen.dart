import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// ReviewResultsScreen — overall examination statistics across ALL quizzes.
///
/// Shows exactly four summary tiles, matching the Quiz Results page:
///   Total Examinees · Overall Average · Passing Average · Non-Passing Average
///
/// Each submission counts as one examinee entry and is judged against the
/// required passing rate of its own quiz (`passingPercent` on the quiz doc,
/// default 75). Averages are mean score percentages.
///
/// Per-quiz details (rankings, scores, dates) stay in QuizResultsScreen.
class ReviewResultsScreen extends StatelessWidget {
  /// Kept only so existing callers that pass `isAdmin:` still compile.
  final bool isAdmin;

  const ReviewResultsScreen({super.key, this.isAdmin = false});

  static const _brand = Color(0xFF1A237E);
  static const _green = Color(0xFF2E7D32);
  static const _red = Color(0xFFC62828);
  static const double _defaultPassing = 75;
  static const double _maxWidth = 1000;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F8),
      appBar: AppBar(
        backgroundColor: _brand,
        foregroundColor: Colors.white,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Review Results',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            Text('Overall examination statistics',
                style: TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
      ),
      // Outer stream: quiz docs (required passing % per quiz).
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('quizzes').snapshots(),
        builder: (context, quizSnap) {
          final passingByQuiz = <String, double>{};
          for (final d in quizSnap.data?.docs ?? const []) {
            final m = d.data() as Map<String, dynamic>;
            passingByQuiz[d.id] =
                (m['passingPercent'] as num?)?.toDouble() ?? _defaultPassing;
          }

          // Inner stream: every submission of every quiz.
          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('quiz_results')
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                    child: CircularProgressIndicator(color: _brand));
              }
              if (snapshot.hasError) return _buildError(snapshot.error);

              final docs = snapshot.data?.docs ?? [];
              if (docs.isEmpty) return _buildEmpty();

              // ── Compute the four statistics ─────────────────────────────
              double sumAll = 0, sumPass = 0, sumFail = 0;
              int nPass = 0, nFail = 0;

              for (final d in docs) {
                final m = d.data() as Map<String, dynamic>;
                final passing =
                    passingByQuiz[(m['quizId'] as String?) ?? ''] ??
                        _defaultPassing;
                final score = (m['score'] as num?)?.toInt() ?? 0;
                final total = (m['totalQuestions'] as num?)?.toInt() ?? 1;
                final percent = total == 0 ? 0.0 : score / total * 100;
                sumAll += percent;
                if (percent >= passing) {
                  sumPass += percent;
                  nPass++;
                } else {
                  sumFail += percent;
                  nFail++;
                }
              }

              final totalExaminees = docs.length;
              final overallAvg = sumAll / totalExaminees;
              final passingAvg = nPass == 0 ? null : sumPass / nPass;
              final nonPassingAvg = nFail == 0 ? null : sumFail / nFail;

              String fmt(double? v) =>
                  v == null ? '—' : '${v.toStringAsFixed(1)}%';

              final tiles = <Widget>[
                _StatTile(
                    icon: Icons.people_alt_outlined,
                    label: 'Total Examinees',
                    value: '$totalExaminees'),
                _StatTile(
                    icon: Icons.bar_chart_rounded,
                    label: 'Overall Average',
                    value: fmt(overallAvg)),
                _StatTile(
                    icon: Icons.emoji_events_outlined,
                    label: 'Passing Average',
                    value: fmt(passingAvg),
                    valueColor: _green),
                _StatTile(
                    icon: Icons.trending_down_rounded,
                    label: 'Non-Passing Average',
                    value: fmt(nonPassingAvg),
                    valueColor: _red),
              ];

              return LayoutBuilder(builder: (context, constraints) {
                final contentWidth = constraints.maxWidth > _maxWidth
                    ? _maxWidth
                    : constraints.maxWidth;
                final narrow = contentWidth < 480;

                return SingleChildScrollView(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: _maxWidth),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                        child: narrow
                            // Phones: 2 x 2 grid.
                            ? Column(children: [
                                Row(children: [
                                  Expanded(child: tiles[0]),
                                  const SizedBox(width: 8),
                                  Expanded(child: tiles[1]),
                                ]),
                                const SizedBox(height: 8),
                                Row(children: [
                                  Expanded(child: tiles[2]),
                                  const SizedBox(width: 8),
                                  Expanded(child: tiles[3]),
                                ]),
                              ])
                            : Row(children: [
                                for (int i = 0; i < tiles.length; i++) ...[
                                  if (i > 0) const SizedBox(width: 8),
                                  Expanded(child: tiles[i]),
                                ],
                              ]),
                      ),
                    ),
                  ),
                );
              });
            },
          );
        },
      ),
    );
  }

  // ── States ───────────────────────────────────────────────────────────────
  Widget _buildError(Object? error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline_rounded,
                  size: 48, color: Colors.red[300]),
              const SizedBox(height: 10),
              const Text('Could not load review results.',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 6),
              Text('$error',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );

  Widget _buildEmpty() => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.assignment_outlined, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 12),
            Text('No results yet.',
                style: TextStyle(color: Colors.grey[600], fontSize: 16)),
            const SizedBox(height: 4),
            Text('Statistics appear once students submit quizzes.',
                style: TextStyle(color: Colors.grey[400], fontSize: 13)),
          ],
        ),
      );
}

// ── Stat tile (same look as the Quiz Results tiles) ──────────────────────────
class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color valueColor;

  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor = const Color(0xFF1A237E),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE8EAF6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Icon(icon, size: 14, color: Colors.grey[600]),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ),
          ]),
          const SizedBox(height: 3),
          Text(value,
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold, color: valueColor)),
        ],
      ),
    );
  }
}