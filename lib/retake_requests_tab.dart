import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Instructor-facing tab for approving/denying students' requests to retake
/// a review after they've used both free attempts.
///
/// WIRED UP in TeacherHomeScreen.dart as the 4th nav tab ("Requests"),
/// placed right after Archive.
///
/// DATA MODEL: reads/writes the `retake_requests` collection. One document
/// per `{quizId}_{studentUid}`, created from the student side (in
/// student_home_screen.dart) once a student has used kMaxFreeAttempts (2)
/// attempts on a review and taps "Request Permission to Retake". Fields:
///   quizId, quizTitle, subject, yearLevel,
///   studentUid, studentName, studentYearLevel,
///   attemptCount (int, attempts used at request time),
///   status ('pending' | 'approved' | 'denied' | 'used'),
///   requestedAt, respondedAt, usedAt (server timestamps)
///
/// Approving sets status to 'approved', which unlocks exactly one more
/// attempt in take_quiz_screen.dart; that screen flips status to 'used'
/// once the student actually submits it, so a further attempt requires a
/// brand-new request.
///
/// GROUPING: pending requests are grouped by their `subject` field. Each
/// subject section shows how many requests / students are waiting and has
/// its own "Approve All" / "Deny All" buttons, which update every pending
/// request in that subject with Firestore batched writes. Individual
/// Approve / Deny buttons on each request still work.
class RetakeRequestsTab extends StatelessWidget {
  const RetakeRequestsTab({super.key});

  // Firestore allows 500 writes per batch; stay comfortably below it.
  static const int _batchLimit = 400;

  // Label used for requests that have no `subject` value.
  static const String _noSubjectLabel = 'Other';

  void _showSnack(BuildContext context, String message, Color color) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ── Single request ──────────────────────────────────────────────────────
  Future<void> _respond(
      BuildContext context, DocumentReference ref, String status) async {
    try {
      await ref.set({
        'status': status,
        'respondedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      _showSnack(
        context,
        status == 'approved' ? 'Retake approved.' : 'Request denied.',
        status == 'approved' ? Colors.green : Colors.red.shade700,
      );
    } catch (e) {
      _showSnack(context, 'Something went wrong. Please try again.',
          Colors.red.shade700);
    }
  }

  // ── Bulk: every pending request of one subject ──────────────────────────
  Future<void> _respondAll(
    BuildContext context,
    String subject,
    List<QueryDocumentSnapshot> docs,
    String status,
  ) async {
    if (docs.isEmpty) return;
    final approve = status == 'approved';
    final count = docs.length;
    final noun = count == 1 ? 'request' : 'requests';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(approve ? 'Approve all requests?' : 'Deny all requests?'),
        content: Text(
          approve
              ? 'Approve $count retake $noun for "$subject"? '
                  'Each student will get one more attempt.'
              : 'Deny $count retake $noun for "$subject"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  approve ? Colors.green.shade700 : Colors.red.shade700,
              foregroundColor: Colors.white,
            ),
            child: Text(approve ? 'Approve All' : 'Deny All'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final db = FirebaseFirestore.instance;
      for (var i = 0; i < docs.length; i += _batchLimit) {
        final batch = db.batch();
        for (final d in docs.skip(i).take(_batchLimit)) {
          batch.set(
            d.reference,
            {
              'status': status,
              'respondedAt': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true),
          );
        }
        await batch.commit();
      }
      _showSnack(
        context,
        approve
            ? 'Approved $count $noun for $subject.'
            : 'Denied $count $noun for $subject.',
        approve ? Colors.green : Colors.red.shade700,
      );
    } catch (e) {
      _showSnack(context, 'Something went wrong. Please try again.',
          Colors.red.shade700);
    }
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  // ── Header banner + live pending-count badge ────────────────────────────
  // `count` is null while the stream hasn't emitted yet (or errored), in
  // which case the badge is simply omitted rather than showing a wrong or
  // flickering "0".
  Widget _buildHeader(int? count) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFF0F2F8),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Expanded(
            child: Text(
              'Students appear here after using both free attempts on a '
              'review and asking for permission to try again.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
          if (count != null && count > 0) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF1A237E),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                count == 1 ? '1 pending' : '$count pending',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Groups pending requests by subject. Requests inside each group are
  /// sorted oldest first; groups are sorted alphabetically with the
  /// "Other" (no subject) group last.
  Map<String, List<QueryDocumentSnapshot>> _groupBySubject(
      List<QueryDocumentSnapshot> docs) {
    final grouped = <String, List<QueryDocumentSnapshot>>{};
    for (final d in docs) {
      final data = d.data() as Map<String, dynamic>;
      final raw = (data['subject'] as String?)?.trim() ?? '';
      final key = raw.isEmpty ? _noSubjectLabel : raw;
      grouped.putIfAbsent(key, () => []).add(d);
    }

    for (final list in grouped.values) {
      list.sort((a, b) {
        final at =
            (a.data() as Map<String, dynamic>)['requestedAt'] as Timestamp?;
        final bt =
            (b.data() as Map<String, dynamic>)['requestedAt'] as Timestamp?;
        if (at == null || bt == null) return 0;
        return at.compareTo(bt); // oldest first
      });
    }

    final keys = grouped.keys.toList()
      ..sort((a, b) {
        if (a == _noSubjectLabel) return 1;
        if (b == _noSubjectLabel) return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    return {for (final k in keys) k: grouped[k]!};
  }

  @override
  Widget build(BuildContext context) {
    // Filtered by status only (no orderBy) so this doesn't require a
    // composite Firestore index — sorting happens client-side.
    final pendingStream = FirebaseFirestore.instance
        .collection('retake_requests')
        .where('status', isEqualTo: 'pending')
        .snapshots();

    return StreamBuilder<QuerySnapshot>(
      stream: pendingStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return Column(
            children: [
              _buildHeader(null),
              const Expanded(
                child: Center(
                    child: CircularProgressIndicator(
                        color: Color(0xFF1A237E))),
              ),
            ],
          );
        }

        // IMPORTANT: without this check, a permission-denied error
        // (e.g. missing/incorrect Firestore security rules on the
        // retake_requests collection) silently falls through to the
        // "No pending requests." empty state below, making a rules
        // problem look identical to "everything is fine, there's
        // just nothing to show." Surface it explicitly instead.
        if (snapshot.hasError) {
          return Column(
            children: [
              _buildHeader(null),
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline_rounded,
                            size: 48, color: Colors.red[300]),
                        const SizedBox(height: 10),
                        const Text('Could not load requests.',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15)),
                        const SizedBox(height: 6),
                        Text('${snapshot.error}',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey),
                            textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        final docs = (snapshot.data?.docs ?? []).toList();
        final grouped = _groupBySubject(docs);
        final subjects = grouped.keys.toList();

        return Column(
          children: [
            _buildHeader(docs.length),
            Expanded(
              child: docs.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.mark_email_read_rounded,
                              size: 56, color: Colors.grey[300]),
                          const SizedBox(height: 12),
                          Text('No pending requests.',
                              style: TextStyle(
                                  color: Colors.grey[500], fontSize: 15)),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(14),
                      itemCount: subjects.length,
                      itemBuilder: (context, index) {
                        final subject = subjects[index];
                        final groupDocs = grouped[subject]!;
                        return _SubjectGroup(
                          // Keeps expanded/collapsed state when the
                          // Firestore stream emits new data.
                          key: ValueKey(subject),
                          subject: subject,
                          docs: groupDocs,
                          formatDate: _formatDate,
                          onRespondOne: (doc, status) =>
                              _respond(context, doc.reference, status),
                          onRespondAll: (status) =>
                              _respondAll(context, subject, groupDocs, status),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// One collapsible section per subject, with bulk Approve All / Deny All.
// ─────────────────────────────────────────────────────────────────────────
class _SubjectGroup extends StatefulWidget {
  final String subject;
  final List<QueryDocumentSnapshot> docs;
  final String Function(DateTime) formatDate;
  final Future<void> Function(QueryDocumentSnapshot doc, String status)
      onRespondOne;
  final Future<void> Function(String status) onRespondAll;

  const _SubjectGroup({
    super.key,
    required this.subject,
    required this.docs,
    required this.formatDate,
    required this.onRespondOne,
    required this.onRespondAll,
  });

  @override
  State<_SubjectGroup> createState() => _SubjectGroupState();
}

class _SubjectGroupState extends State<_SubjectGroup> {
  bool _expanded = true;
  bool _busy = false;

  Future<void> _bulk(String status) async {
    setState(() => _busy = true);
    try {
      await widget.onRespondAll(status);
    } finally {
      // The group usually disappears once its requests are approved, so
      // only touch state if we're still on screen.
      if (mounted) setState(() => _busy = false);
    }
  }

  int get _studentCount {
    final ids = <String>{};
    for (final d in widget.docs) {
      final data = d.data() as Map<String, dynamic>;
      final id = (data['studentUid'] as String?) ??
          (data['studentName'] as String?) ??
          d.id;
      ids.add(id);
    }
    return ids.length;
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.docs.length;
    final students = _studentCount;
    final summary = '$count ${count == 1 ? 'request' : 'requests'}'
        ' · $students ${students == 1 ? 'student' : 'students'}';

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Subject header (tap to collapse/expand) ───────────────────
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 10, 10),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8EAF6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.menu_book_rounded,
                        color: Color(0xFF1A237E), size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.subject,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                                color: Color(0xFF1A237E))),
                        const SizedBox(height: 2),
                        Text(summary,
                            style: const TextStyle(
                                fontSize: 11, color: Colors.black54)),
                      ],
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A237E),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: Colors.black45,
                  ),
                ],
              ),
            ),
          ),

          // ── Bulk actions (shown when there is more than one request) ──
          if (count > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _bulk('denied'),
                      icon: const Icon(Icons.close_rounded, size: 16),
                      label: const Text('Deny All'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade700,
                        side: BorderSide(color: Colors.red.shade200),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _busy ? null : () => _bulk('approved'),
                      icon: _busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.done_all_rounded, size: 16),
                      label: Text('Approve All ($count)'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // ── Individual requests ───────────────────────────────────────
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  for (final doc in widget.docs) _buildRequestTile(doc),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRequestTile(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final quizTitle = data['quizTitle'] as String? ?? 'Review';
    final studentName = data['studentName'] as String? ?? 'Student';
    final yearLevel = data['studentYearLevel'] as String? ?? '';
    final attemptCount = data['attemptCount'] as int? ?? 0;
    final requestedAt = data['requestedAt'] as Timestamp?;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE6E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.person_rounded,
                    color: Colors.orange.shade800, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(studentName,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Color(0xFF1A237E))),
                    if (yearLevel.isNotEmpty)
                      Text(yearLevel,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.black54)),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Text('$attemptCount attempts used',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.orange.shade800,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text('Review: $quizTitle',
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          if (requestedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Requested ${widget.formatDate(requestedAt.toDate())}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed:
                      _busy ? null : () => widget.onRespondOne(doc, 'denied'),
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: const Text('Deny'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red.shade700,
                    side: BorderSide(color: Colors.red.shade200),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => widget.onRespondOne(doc, 'approved'),
                  icon: const Icon(Icons.check_rounded, size: 16),
                  label: const Text('Approve'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}