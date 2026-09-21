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
class RetakeRequestsTab extends StatelessWidget {
  const RetakeRequestsTab({super.key});

  Future<void> _respond(
      BuildContext context, DocumentReference ref, String status) async {
    try {
      await ref.set({
        'status': status,
        'respondedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              status == 'approved' ? 'Retake approved.' : 'Request denied.'),
          backgroundColor:
              status == 'approved' ? Colors.green : Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Something went wrong. Please try again.'),
          backgroundColor: Colors.red.shade700,
        ));
      }
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

  @override
  Widget build(BuildContext context) {
    // Filtered by status only (no orderBy) so this doesn't require a
    // composite Firestore index — sorting happens client-side below.
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

        final docs = (snapshot.data?.docs ?? []).toList()
          ..sort((a, b) {
            final at = (a.data() as Map<String, dynamic>)['requestedAt']
                as Timestamp?;
            final bt = (b.data() as Map<String, dynamic>)['requestedAt']
                as Timestamp?;
            if (at == null || bt == null) return 0;
            return at.compareTo(bt); // oldest first
          });

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
                      itemCount: docs.length,
                      itemBuilder: (context, index) {
                        final doc = docs[index];
                        final data = doc.data() as Map<String, dynamic>;
                        final quizTitle =
                            data['quizTitle'] as String? ?? 'Review';
                        final studentName =
                            data['studentName'] as String? ?? 'Student';
                        final yearLevel =
                            data['studentYearLevel'] as String? ?? '';
                        final subject = data['subject'] as String? ?? '';
                        final attemptCount = data['attemptCount'] as int? ?? 0;
                        final requestedAt = data['requestedAt'] as Timestamp?;

                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14)),
                          elevation: 2,
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 40,
                                      height: 40,
                                      decoration: BoxDecoration(
                                        color: Colors.orange.shade50,
                                        borderRadius:
                                            BorderRadius.circular(10),
                                      ),
                                      child: Icon(Icons.person_rounded,
                                          color: Colors.orange.shade800,
                                          size: 20),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(studentName,
                                              style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 14,
                                                  color: Color(0xFF1A237E))),
                                          if (yearLevel.isNotEmpty)
                                            Text(yearLevel,
                                                style: const TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.black54)),
                                        ],
                                      ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: Colors.orange.shade50,
                                        borderRadius:
                                            BorderRadius.circular(20),
                                        border: Border.all(
                                            color: Colors.orange.shade200),
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
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600)),
                                if (subject.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(subject,
                                        style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.black54)),
                                  ),
                                if (requestedAt != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: Text(
                                      'Requested ${_formatDate(requestedAt.toDate())}',
                                      style: const TextStyle(
                                          fontSize: 11, color: Colors.grey),
                                    ),
                                  ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: () => _respond(
                                            context, doc.reference, 'denied'),
                                        icon: const Icon(Icons.close_rounded,
                                            size: 16),
                                        label: const Text('Deny'),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: Colors.red.shade700,
                                          side: BorderSide(
                                              color: Colors.red.shade200),
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 10),
                                          shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(10)),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: ElevatedButton.icon(
                                        onPressed: () => _respond(context,
                                            doc.reference, 'approved'),
                                        icon: const Icon(Icons.check_rounded,
                                            size: 16),
                                        label: const Text('Approve'),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor:
                                              Colors.green.shade700,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 10),
                                          shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(10)),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
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