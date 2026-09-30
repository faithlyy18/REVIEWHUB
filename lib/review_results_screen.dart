import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// ReviewResultsScreen — overall review / examination statistics, board-exam
/// style, across ALL quizzes.
///
/// LAYOUT
/// - Overall passing rate card (big %, progress bar, "X of N passed").
/// - Two group boxes: Passers and Non-passers, each with the head count and
///   the passing average / non-passing average (mean score %).
/// - Two small tiles: total examinees and overall average.
/// - "Results by quiz": one row per quiz with its submissions, passers,
///   non-passers and passing rate. Admins can tap the passing mark chip to
///   change the required passing rate of that quiz (saved on the quiz doc as
///   `passingPercent`, default 75).
///
/// Each submission counts as one examinee entry, and is judged against the
/// passing rate of its own quiz.
///
/// Per-quiz details (rankings, scores, dates) stay in QuizResultsScreen.
class ReviewResultsScreen extends StatelessWidget {
  /// Only admins can edit a quiz's required passing rate.
  final bool isAdmin;

  const ReviewResultsScreen({super.key, this.isAdmin = false});

  static const _brand = Color(0xFF1A237E);
  static const _green = Color(0xFF2E7D32);
  static const _red = Color(0xFFC62828);
  static const _greenBg = Color(0xFFE8F5E9);
  static const _redBg = Color(0xFFFFEBEE);
  static const _border = Color(0xFFE8EAF6);
  static const _muted = Color(0xFF9096B4);
  static const double _defaultPassing = 75;
  static const double _maxWidth = 1000;

  static String _pct(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  // ── Edit a quiz's required passing rate (admin) ──────────────────────────
  Future<void> _editPassingPercent(
      BuildContext context, String quizId, double current) async {
    final controller = TextEditingController(text: _pct(current));
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Required passing rate',
            style: TextStyle(color: _brand, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          decoration: const InputDecoration(
            suffixText: '%',
            hintText: 'e.g. 75',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () {
              final v = double.tryParse(controller.text.trim());
              if (v == null || v <= 0 || v > 100) return;
              Navigator.pop(ctx, v);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: _brand, foregroundColor: Colors.white),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('quizzes')
          .doc(quizId)
          .set({'passingPercent': result}, SetOptions(merge: true));
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not save passing rate: $e'),
        backgroundColor: Colors.red.shade700,
      ));
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────
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
          final quizMeta = <String, _QuizMeta>{};
          for (final d in quizSnap.data?.docs ?? const []) {
            final m = d.data() as Map<String, dynamic>;
            quizMeta[d.id] = _QuizMeta(
              title: (m['title'] as String?)?.trim() ?? '',
              subject: (m['subject'] as String?)?.trim() ?? '',
              passing:
                  (m['passingPercent'] as num?)?.toDouble() ?? _defaultPassing,
            );
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

              // ── Normalise ───────────────────────────────────────────────
              final entries = <_Entry>[];
              final byQuiz = <String, _QuizAgg>{};

              for (final d in docs) {
                final m = d.data() as Map<String, dynamic>;
                final quizId = (m['quizId'] as String?) ?? '';
                final meta = quizMeta[quizId];
                final passing = meta?.passing ?? _defaultPassing;
                final score = (m['score'] as num?)?.toInt() ?? 0;
                final total = (m['totalQuestions'] as num?)?.toInt() ?? 1;
                final percent = total == 0 ? 0.0 : score / total * 100;
                final passed = percent >= passing;
                entries.add(_Entry(percent: percent, passed: passed));

                final resultTitle = (m['quizTitle'] as String?)?.trim() ?? '';
                final resultSubject = (m['subject'] as String?)?.trim() ?? '';
                final agg = byQuiz.putIfAbsent(
                  quizId,
                  () => _QuizAgg(
                    quizId: quizId,
                    title: resultTitle.isNotEmpty
                        ? resultTitle
                        : ((meta?.title.isNotEmpty ?? false)
                            ? meta!.title
                            : 'Untitled quiz'),
                    subject: resultSubject.isNotEmpty
                        ? resultSubject
                        : (meta?.subject ?? ''),
                    passing: passing,
                    editable: meta != null,
                  ),
                );
                agg.count++;
                if (passed) agg.passers++;
              }

              // ── Overall statistics ──────────────────────────────────────
              final passers = entries.where((e) => e.passed).toList();
              final nonPassers = entries.where((e) => !e.passed).toList();
              final n = entries.length;
              final passRate = passers.length / n * 100;
              final failRate = nonPassers.length / n * 100;
              final overallAvg =
                  entries.fold<double>(0, (a, e) => a + e.percent) / n;
              final passingAvg = passers.isEmpty
                  ? 0.0
                  : passers.fold<double>(0, (a, e) => a + e.percent) /
                      passers.length;
              final nonPassingAvg = nonPassers.isEmpty
                  ? 0.0
                  : nonPassers.fold<double>(0, (a, e) => a + e.percent) /
                      nonPassers.length;

              final quizzes = byQuiz.values.toList()
                ..sort((a, b) => b.count.compareTo(a.count));

              return LayoutBuilder(builder: (context, constraints) {
                final contentWidth = constraints.maxWidth > _maxWidth
                    ? _maxWidth
                    : constraints.maxWidth;
                final wide = contentWidth - 28 >= 560;

                return SingleChildScrollView(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: _maxWidth),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildOverviewCard(
                              wide: wide,
                              total: n,
                              passRate: passRate,
                              failRate: failRate,
                              passers: passers.length,
                              nonPassers: nonPassers.length,
                              passingAvg: passingAvg,
                              nonPassingAvg: nonPassingAvg,
                            ),
                            const SizedBox(height: 12),
                            Row(children: [
                              Expanded(
                                child: _StatTile(
                                    icon: Icons.people_alt_outlined,
                                    label: 'Total examinees',
                                    value: '$n'),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _StatTile(
                                    icon: Icons.bar_chart_rounded,
                                    label: 'Overall average',
                                    value: '${overallAvg.toStringAsFixed(1)}%'),
                              ),
                            ]),
                            const SizedBox(height: 12),
                            _buildByQuizCard(context, quizzes),
                          ],
                        ),
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

  // ── 1. Overall passing rate + passers / non-passers ──────────────────────
  Widget _buildOverviewCard({
    required bool wide,
    required int total,
    required double passRate,
    required double failRate,
    required int passers,
    required int nonPassers,
    required double passingAvg,
    required double nonPassingAvg,
  }) {
    String rate(double v) => _pct(double.parse(v.toStringAsFixed(1)));

    final overall = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Overall passing rate',
            style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        const SizedBox(height: 2),
        Text('${rate(passRate)}%',
            style: const TextStyle(
                fontSize: 32,
                height: 1.2,
                fontWeight: FontWeight.bold,
                color: _green)),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Container(
            height: 8,
            color: _redBg,
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: (passRate / 100).clamp(0.0, 1.0),
              child: Container(color: _green),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text('$passers of $total examinees passed',
            style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        Text('Failing rate: ${rate(failRate)}%',
            style: TextStyle(fontSize: 12, color: Colors.grey[600])),
      ],
    );

    final groups = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _GroupBox(
            color: _green,
            bg: _greenBg,
            icon: Icons.check_circle_outline_rounded,
            label: 'Passers',
            count: passers,
            avgLabel: 'Passing average',
            avg: passers == 0 ? null : passingAvg,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _GroupBox(
            color: _red,
            bg: _redBg,
            icon: Icons.cancel_outlined,
            label: 'Non-passers',
            count: nonPassers,
            avgLabel: 'Non-passing average',
            avg: nonPassers == 0 ? null : nonPassingAvg,
          ),
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.analytics_outlined, size: 18, color: _brand),
            SizedBox(width: 8),
            Text('Examination statistics',
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14, color: _brand)),
          ]),
          const SizedBox(height: 14),
          if (wide)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 10, child: overall),
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    color: _border,
                  ),
                  Expanded(flex: 17, child: groups),
                ],
              ),
            )
          else ...[
            overall,
            const SizedBox(height: 14),
            groups,
          ],
        ],
      ),
    );
  }

  // ── 2. Results by quiz ───────────────────────────────────────────────────
  Widget _buildByQuizCard(BuildContext context, List<_QuizAgg> quizzes) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(children: [
              Icon(Icons.list_alt_rounded, size: 18, color: _brand),
              SizedBox(width: 8),
              Text('Results by quiz',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: _brand)),
            ]),
          ),
          const Divider(height: 1, color: _border),
          for (int i = 0; i < quizzes.length; i++) ...[
            _buildQuizRow(context, quizzes[i]),
            if (i != quizzes.length - 1)
              const Divider(height: 1, color: _border),
          ],
        ],
      ),
    );
  }

  Widget _buildQuizRow(BuildContext context, _QuizAgg q) {
    final failed = q.count - q.passers;
    final rate = q.count == 0 ? 0.0 : q.passers / q.count * 100;
    final canEdit = isAdmin && q.editable;

    final passingChip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFC5CAE9)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (canEdit) ...[
          const Icon(Icons.edit_outlined, size: 12, color: _brand),
          const SizedBox(width: 4),
        ],
        Text('Passing: ${_pct(q.passing)}%',
            style: const TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.w600, color: _brand)),
      ]),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(q.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13.5)),
              if (q.subject.isNotEmpty)
                Text(q.subject,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: _muted)),
              const SizedBox(height: 4),
              Text(
                  '${q.count} submission${q.count == 1 ? '' : 's'} · '
                  '${q.passers} passed · $failed failed',
                  style: const TextStyle(fontSize: 11.5, color: _muted)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text('${_pct(double.parse(rate.toStringAsFixed(1)))}%',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: rate >= 50 ? _green : _red)),
            const SizedBox(height: 4),
            canEdit
                ? InkWell(
                    onTap: () =>
                        _editPassingPercent(context, q.quizId, q.passing),
                    borderRadius: BorderRadius.circular(8),
                    child: passingChip,
                  )
                : passingChip,
          ],
        ),
      ]),
    );
  }
}

// ── Data holders ─────────────────────────────────────────────────────────────
class _QuizMeta {
  final String title;
  final String subject;
  final double passing;
  const _QuizMeta(
      {required this.title, required this.subject, required this.passing});
}

class _Entry {
  final double percent;
  final bool passed;
  const _Entry({required this.percent, required this.passed});
}

class _QuizAgg {
  final String quizId;
  final String title;
  final String subject;
  final double passing;

  /// False when the quiz doc no longer exists, so its rate can't be edited.
  final bool editable;
  int count = 0;
  int passers = 0;

  _QuizAgg({
    required this.quizId,
    required this.title,
    required this.subject,
    required this.passing,
    required this.editable,
  });
}

// ── Small widgets ────────────────────────────────────────────────────────────
class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatTile(
      {required this.icon, required this.label, required this.value});

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
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A237E))),
        ],
      ),
    );
  }
}

class _GroupBox extends StatelessWidget {
  final Color color;
  final Color bg;
  final IconData icon;
  final String label;
  final int count;
  final String avgLabel;

  /// Mean score % of the group, or null when the group is empty.
  final double? avg;

  const _GroupBox({
    required this.color,
    required this.bg,
    required this.icon,
    required this.label,
    required this.count,
    required this.avgLabel,
    required this.avg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, color: color)),
          ]),
          const SizedBox(height: 2),
          Text('$count',
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 2),
          Text(
              avg == null
                  ? '$avgLabel: No data'
                  : '$avgLabel: ${avg!.toStringAsFixed(1)}%',
              style: TextStyle(fontSize: 12, color: color)),
        ],
      ),
    );
  }
}