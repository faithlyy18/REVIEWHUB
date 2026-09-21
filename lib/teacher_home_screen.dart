import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../login_screen.dart';
import 'create_quiz_screen.dart';
import 'quiz_results_screen.dart';
import 'modules_screen.dart';
import 'retake_requests_tab.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Curriculum data
// ─────────────────────────────────────────────────────────────────────────────

class _Subject {
  final String code;
  final String description;
  const _Subject(this.code, this.description);
}

class _YearCurriculum {
  final String yearLabel;
  final List<_Subject> sem1;
  final List<_Subject> sem2;
  const _YearCurriculum(
      {required this.yearLabel, required this.sem1, required this.sem2});
}

const _curriculum = [
  _YearCurriculum(
    yearLabel: '1st Year',
    sem1: [
      _Subject('CRIM 1', 'Introduction to Criminology'),
    ],
    sem2: [
      _Subject('CLJ 1', 'Introduction to Phil. Criminal Justice System'),
      _Subject('LEA 1', 'Law Enforcement Organization and Administration'),
    ],
  ),
  _YearCurriculum(
    yearLabel: '2nd Year',
    sem1: [
      _Subject('CA 1', 'Institutional Corrections'),
      _Subject('CDI 1', 'Fundamentals of Investigation and Intelligence'),
      _Subject('CLJ 2', 'Human Rights Education'),
      _Subject('CRIM 2', 'Theories of Crime Causation'),
      _Subject('LEA 2', 'Comparative Models in Policing'),
    ],
    sem2: [
      _Subject('CDI 2', 'Specialized Crime Investigation 1 with Legal Medicine'),
      _Subject('CFLM 1', 'Character Formation, Nationalism and Patriotism'),
      _Subject('CLJ 3', 'Criminal Law (Book 1)'),
      _Subject('CRIM 3', 'Human Behavior and Victimology'),
      _Subject('FORENSIC 1', 'Forensic Photography'),
      _Subject('FORENSIC 2', 'Personal Identification Techniques'),
      _Subject('LEA 3', 'Introduction to Industrial Security Concepts'),
    ],
  ),
  _YearCurriculum(
    yearLabel: '3rd Year',
    sem1: [
      _Subject('CA 2', 'Non-Institutional Corrections'),
      _Subject('CDI 3', 'Specialized Crime Investigation 2 with Simulation on Interrogation and Interview'),
      _Subject('CDI 4', 'Traffic Management and Accident Investigation with Driving'),
      _Subject('CDI 5', 'Technical English 1 (Technical Report Writing and Presentation)'),
      _Subject('CFLM 2', 'Character Formation with Leadership, Decision Making, Management and Administration'),
      _Subject('CLJ 4', 'Criminal Law (Book 2)'),
      _Subject('FORENSIC 3', 'Forensic Chemistry and Toxicology'),
      _Subject('FORENSIC 4', 'Questioned Documents Examination'),
      _Subject('LEA 4', 'Law Enforcement Operations and Planning with Crime Mapping'),
    ],
    sem2: [
      _Subject('CA 3', 'Therapeutic Modalities'),
      _Subject('CDI 6', 'Fire Protection and Arson Investigation'),
      _Subject('CDI 7', 'Vice and Drug Education and Control'),
      _Subject('CLJ 5', 'Evidence'),
      _Subject('CRIM 4', 'Professional Conduct and Ethical Standards'),
      _Subject('CRIM 5', 'Juvenile Delinquency and Juvenile Justice System'),
      _Subject('CRIM 6', 'Dispute Resolution and Crises/Incidents Management'),
      _Subject('CRIM 7', 'Criminological Research 1 (Research Methods with Applied Statistics)'),
      _Subject('FORENSIC 5', 'Lie Detection Techniques'),
      _Subject('FORENSIC 6', 'Forensic Ballistics'),
    ],
  ),
  _YearCurriculum(
    yearLabel: '4th Year',
    sem1: [
      _Subject('CDI 8', 'Technical English 2 (Legal Forms)'),
      _Subject('CDI 9', 'Introduction to Cybercrime and Environmental Laws and Protection'),
      _Subject('CLJ 6', 'Criminal Procedure and Court Testimony'),
      _Subject('CP 1', 'Internship (On-the-Job Training 1)'),
      _Subject('CRIM 8', 'Criminological Research 2 (Thesis Writing and Presentation)'),
    ],
    sem2: [
      _Subject('CP 2', 'Internship (On-the-Job Training 2)'),
      _Subject('ICRIM RC', 'Criminology Refresher Course'),
    ],
  ),
];

List<_Subject> _getSubjects(String yearLabel, String semester) {
  try {
    final year = _curriculum.firstWhere((y) => y.yearLabel == yearLabel);
    return semester == '1st Semester' ? year.sem1 : year.sem2;
  } catch (_) {
    return [];
  }
}

// Formats a Firestore Timestamp (or DateTime) into e.g. "Aug 8, 2026".
// Returns null if the value is missing or of an unexpected type, so
// callers can simply omit the chip when there's nothing to show.
// NOTE: despite the name, this is used generically for any Firestore
// timestamp field (archivedAt, createdAt, uploadedAt, etc.) — see
// _InstructorReviewsList / _InstructorModulesList below.
const _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];

String? _formatArchivedDate(dynamic archivedAt) {
  DateTime? dt;
  if (archivedAt is Timestamp) {
    dt = archivedAt.toDate();
  } else if (archivedAt is DateTime) {
    dt = archivedAt;
  }
  if (dt == null) return null;
  return '${_monthNames[dt.month - 1]} ${dt.day}, ${dt.year}';
}

// ─────────────────────────────────────────────────────────────────────────────
// Background painter
// ─────────────────────────────────────────────────────────────────────────────

class _BackgroundPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final textStyle = TextStyle(
      color: Colors.white.withOpacity(0.045),
      fontSize: 13,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.3,
    );

    final items = [
      'Criminal Law', 'Evidence', 'Criminalistics', 'Penology', 'Ethics',
      'R.A. 6975', 'R.A. 9708', 'P.D. 1606', 'B.P. 881', 'R.A. 10591',
      'Forensic Chemistry', 'Ballistics', 'Questioned Documents',
      'Police Organization', 'Law Enforcement Admin', 'Criminal Sociology',
      'Victimology', 'White-collar Crime', 'Organized Crime',
      'Art. 248 RPC — Murder', 'Art. 249 — Homicide', 'Art. 246 — Parricide',
      'Locard\'s Exchange Principle', 'Chain of Custody', 'Modus Operandi',
      'Institutional Corrections', 'Non-Institutional Corrections',
      'Human Rights Education', 'Crime Scene Investigation',
    ];

    double y = 20;
    int idx = 0;
    while (y < size.height + 30) {
      final text = items[idx % items.length];
      final span = TextSpan(text: text, style: textStyle);
      final painter = TextPainter(
        text: span,
        textDirection: TextDirection.ltr,
      )..layout();

      double x = (idx % 2 == 0) ? 20 : 60;
      while (x < size.width + 100) {
        painter.paint(canvas, Offset(x, y));
        x += painter.width + 40;
      }

      y += 28;
      idx++;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ─────────────────────────────────────────────────────────────────────────────
// TeacherHomeScreen
// ─────────────────────────────────────────────────────────────────────────────

class TeacherHomeScreen extends StatefulWidget {
  const TeacherHomeScreen({super.key});

  @override
  State<TeacherHomeScreen> createState() => _TeacherHomeScreenState();
}

class _TeacherHomeScreenState extends State<TeacherHomeScreen> {
  final _user = FirebaseAuth.instance.currentUser;
  late final Future<String> _teacherNameFuture;

  // Set to true when this account's Firestore doc has accountType == 'admin'.
  // Drives the extra "Overview" nav item and IndexedStack page — everyone
  // else keeps the exact same Reviews/Modules/Archive/Requests dashboard.
  bool _isAdmin = false;

  // 0 = Reviews, 1 = Modules, 2 = Archive, 3 = Requests, 4 = Overview (admin only)
  int _activeTab = 0;
  String _filterYear = 'All Years';
  late final Stream<QuerySnapshot> _quizStream;
  late final Stream<QuerySnapshot> _archiveStream;
  late final Stream<QuerySnapshot> _moduleArchiveStream;

  static const _yearOptions = [
    'All Years', '1st Year', '2nd Year', '3rd Year', '4th Year'
  ];

  @override
  void initState() {
    super.initState();
    _teacherNameFuture = _fetchTeacherName();

    _quizStream = FirebaseFirestore.instance
        .collection('quizzes')
        .where('createdBy', isEqualTo: _user?.uid)
        .snapshots();

    _archiveStream = FirebaseFirestore.instance
        .collection('quizzes')
        .where('createdBy', isEqualTo: _user?.uid)
        .where('archived', isEqualTo: true)
        .snapshots();

    _moduleArchiveStream = FirebaseFirestore.instance
        .collection('modules')
        .where('uploadedBy', isEqualTo: _user?.uid)
        .where('archived', isEqualTo: true)
        .snapshots();
  }

  Future<String> _fetchTeacherName() async {
    if (_user == null) return 'Teacher';
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_user.uid)
          .get();
      final data = doc.data();
      final accountType = data?['accountType'] as String?;
      if (accountType == 'admin' && mounted) {
        setState(() => _isAdmin = true);
      }
      return data?['firstName'] ?? 'Teacher';
    } catch (_) {
      return 'Teacher';
    }
  }

  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  List<QueryDocumentSnapshot> _applyFiltersAndSort(
      List<QueryDocumentSnapshot> docs) {
    final filtered = docs.where((doc) {
      final quiz = doc.data() as Map<String, dynamic>;
      final isArchived = quiz['archived'] as bool? ?? false;
      if (isArchived) return false;
      if (_filterYear != 'All Years') {
        final qYear = (quiz['yearLevel'] as String? ?? '').trim().toLowerCase();
        if (qYear != _filterYear.toLowerCase()) return false;
      }
      return true;
    }).toList();

    filtered.sort((a, b) {
      final aData = a.data() as Map<String, dynamic>;
      final bData = b.data() as Map<String, dynamic>;
      final aTime = aData['createdAt'];
      final bTime = bData['createdAt'];
      if (aTime == null && bTime == null) return 0;
      if (aTime == null) return 1;
      if (bTime == null) return -1;
      return (bTime as dynamic).compareTo(aTime as dynamic);
    });

    return filtered;
  }

  bool get _hasFilters => _filterYear != 'All Years';

  void _clearFilters() => setState(() {
        _filterYear = 'All Years';
      });

  Future<void> _archiveQuiz(String quizId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Archive Review',
            style: TextStyle(
                color: Color(0xFF1A237E), fontWeight: FontWeight.bold)),
        content: const Text(
            'This review will be moved to the Archive. You can restore it anytime.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child:
                  const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD84315),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8))),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await FirebaseFirestore.instance
          .collection('quizzes')
          .doc(quizId)
          .update({'archived': true, 'archivedAt': FieldValue.serverTimestamp()});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Review archived.')),
        );
      }
    }
  }

  Future<void> _restoreQuiz(String quizId) async {
    await FirebaseFirestore.instance
        .collection('quizzes')
        .doc(quizId)
        .update({'archived': false, 'archivedAt': FieldValue.delete()});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Review restored to active.'),
          action: SnackBarAction(
            label: 'View Reviews',
            onPressed: () => setState(() => _activeTab = 0),
          ),
        ),
      );
    }
  }

  Future<void> _deleteQuizPermanently(String quizId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Permanently',
            style: TextStyle(
                color: Colors.red, fontWeight: FontWeight.bold)),
        content: const Text(
            'This will permanently delete the review and cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child:
                  const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8))),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete Forever'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await FirebaseFirestore.instance
          .collection('quizzes')
          .doc(quizId)
          .delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Review permanently deleted.')));
      }
    }
  }

  Future<void> _restoreModule(String docId) async {
    await FirebaseFirestore.instance
        .collection('modules')
        .doc(docId)
        .update({'archived': false, 'archivedAt': FieldValue.delete()});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Module restored to active.'),
          action: SnackBarAction(
            label: 'View Modules',
            onPressed: () => setState(() => _activeTab = 1),
          ),
        ),
      );
    }
  }

  Future<void> _deleteModulePermanently(String docId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Permanently',
            style: TextStyle(
                color: Colors.red, fontWeight: FontWeight.bold)),
        content: const Text(
            'This will permanently delete the module and cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child:
                  const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8))),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete Forever'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await FirebaseFirestore.instance
          .collection('modules')
          .doc(docId)
          .delete();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Module permanently deleted.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF283593),
      drawer: _buildDrawer(),
      body: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(painter: _BackgroundPainter()),
          ),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  children: [
                    _buildTopBar(),
                    _buildWelcomeBanner(),
                    Expanded(
                      child: Container(
                        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.18),
                              blurRadius: 32,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: IndexedStack(
                          index: _activeTab,
                          children: [
                            _ReviewsTabBody(
                              quizStream: _quizStream,
                              filterYear: _filterYear,
                              hasFilters: _hasFilters,
                              yearOptions: _yearOptions,
                              applyFiltersAndSort: _applyFiltersAndSort,
                              onYearChanged: (v) => setState(() {
                                _filterYear = v;
                              }),
                              onSubjectViewTap: () =>
                                  _openSubjectViewer(context),
                              onClearFilters: _clearFilters,
                              onEdit: (quizId, quiz) => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => CreateQuizScreen(
                                      quizId: quizId, existingQuiz: quiz),
                                ),
                              ),
                              onArchive: _archiveQuiz,
                              onViewResults: (quizId, title) =>
                                  Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => QuizResultsScreen(
                                      quizId: quizId, quizTitle: title),
                                ),
                              ),
                            ),
                            const TeacherModulesScreen(),
                            _ArchiveTabBody(
                              isAdmin: _isAdmin,
                              archiveStream: _archiveStream,
                              moduleArchiveStream: _moduleArchiveStream,
                              onRestore: _restoreQuiz,
                              onDeletePermanently: _deleteQuizPermanently,
                              onViewResults: (quizId, title) =>
                                  Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => QuizResultsScreen(
                                      quizId: quizId, quizTitle: title),
                                ),
                              ),
                              onRestoreModule: _restoreModule,
                              onDeleteModulePermanently:
                                  _deleteModulePermanently,
                            ),
                            // New: instructor-facing retake-request inbox.
                            // Always index 3, right after Archive.
                            const RetakeRequestsTab(),
                            // Only ever reachable when _isAdmin is true,
                            // since the drawer item that sets _activeTab = 4
                            // only renders for admin accounts (see
                            // _buildDrawer). Including it conditionally
                            // here keeps the list length in sync with
                            // whatever _activeTab can actually be.
                            if (_isAdmin) const _AdminOverviewTabBody(),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_activeTab == 0)
            Positioned(
              bottom: 24,
              right: 24,
              child: FloatingActionButton.extended(
                heroTag: 'createReview',
                backgroundColor: const Color(0xFF1A237E),
                foregroundColor: Colors.white,
                elevation: 4,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Create Review',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CreateQuizScreen()),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Hamburger menu drawer: Reviews, Modules, Archive, Requests, (Overview) ──
  Widget _buildDrawer() {
    Widget navItem({
      required IconData icon,
      required String label,
      required int index,
    }) {
      final isActive = _activeTab == index;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: ListTile(
          leading: Icon(icon,
              color: isActive ? const Color(0xFF1A237E) : Colors.grey[600]),
          title: Text(
            label,
            style: TextStyle(
              color: isActive ? const Color(0xFF1A237E) : Colors.black87,
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              fontSize: 14,
            ),
          ),
          selected: isActive,
          selectedTileColor: const Color(0xFFE8EAF6),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          onTap: () {
            setState(() => _activeTab = index);
            Navigator.pop(context);
          },
        ),
      );
    }

    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              decoration: const BoxDecoration(color: Color(0xFF283593)),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.menu_book_rounded,
                        color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'ReviewHub',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            navItem(icon: Icons.quiz_rounded, label: 'Reviews', index: 0),
            navItem(icon: Icons.folder_rounded, label: 'Modules', index: 1),
            navItem(
                icon: Icons.inventory_2_rounded, label: 'Archive', index: 2),
            navItem(
                icon: Icons.mark_email_unread_rounded,
                label: 'Requests',
                index: 3),
            // Admin-only item. Nothing changes for instructor accounts —
            // this simply doesn't render for them.
            if (_isAdmin)
              navItem(
                  icon: Icons.dashboard_rounded,
                  label: 'Overview',
                  index: 4),
            if (_isAdmin) ...[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Divider(height: 1),
              ),
              // Opens the same Add Subject sheet that used to live as a FAB
              // on the Modules screen — now reachable from anywhere via the
              // drawer. Admin-only, matching the old FAB's visibility rule.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: ListTile(
                  leading: const Icon(Icons.bookmark_add_rounded,
                      color: Colors.grey),
                  title: const Text(
                    'Add Subject',
                    style: TextStyle(fontSize: 14, color: Colors.black87),
                  ),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  onTap: () {
                    Navigator.pop(context); // close the drawer first
                    showAddSubjectSheet(context);
                  },
                ),
              ),
            ],
            const Spacer(),
            const Divider(height: 1),
            ListTile(
              leading:
                  const Icon(Icons.logout_rounded, color: Colors.redAccent),
              title: const Text(
                'Logout',
                style: TextStyle(
                    color: Colors.redAccent, fontWeight: FontWeight.bold),
              ),
              onTap: () {
                Navigator.pop(context);
                _logout();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Top bar: hamburger icon (opens drawer) + logo ──────────────────────────
  // NOTE: the top-bar Logout button was removed (client request) since it
  // duplicated the Logout item already in the drawer/hamburger menu below.
  // The drawer's Logout (in _buildDrawer) is now the only way to log out.
  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
      child: Builder(
        builder: (context) {
          return Row(
            children: [
              IconButton(
                onPressed: () => Scaffold.of(context).openDrawer(),
                icon: const Icon(Icons.menu_rounded,
                    color: Colors.white, size: 24),
                tooltip: 'Menu',
              ),
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.menu_book_rounded,
                    color: Colors.white, size: 20),
              ),
              const SizedBox(width: 10),
              const Text(
                'ReviewHub',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const Spacer(),
            ],
          );
        },
      ),
    );
  }

  Widget _buildWelcomeBanner() {
    return FutureBuilder<String>(
      future: _teacherNameFuture,
      builder: (context, snap) {
        final name = snap.data ?? '';
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withOpacity(0.15)),
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                    _isAdmin
                        ? Icons.admin_panel_settings_rounded
                        : Icons.person_4_rounded,
                    color: Colors.white,
                    size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Column(
                    key: ValueKey(name),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? 'Welcome!' : 'Welcome, $name!',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        _isAdmin
                            ? 'Administrator — BS Criminology'
                            : 'Instructor — BS Criminology',
                        style:
                            const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                  border:
                      Border.all(color: Colors.white.withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.shield_rounded,
                        color: Colors.white70, size: 13),
                    const SizedBox(width: 5),
                    Text(_isAdmin ? 'Admin' : 'Instructor',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // Read-only viewer: tapping "All Subjects" shows every subject for the
  // currently selected year (or all 4 years if "All Years" is selected).
  // Rows here are for viewing only — there's no tap/select behavior on
  // them, since "All Subjects" isn't a filter.
  void _openSubjectViewer(BuildContext context) {
    final yearsToShow = _filterYear == 'All Years'
        ? _curriculum.map((y) => y.yearLabel).toList()
        : [_filterYear];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.93,
        minChildSize: 0.4,
        builder: (_, ctrl) => Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(children: [
                const Icon(Icons.menu_book_rounded,
                    color: Color(0xFF1A237E), size: 18),
                const SizedBox(width: 8),
                Text(
                  _filterYear == 'All Years'
                      ? 'All Subjects (1st – 4th Year)'
                      : 'Subjects — $_filterYear',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: Color(0xFF1A237E)),
                ),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: ctrl,
                children: [
                  for (final yearLabel in yearsToShow) ...[
                    Container(
                      color: const Color(0xFFE8EAF6),
                      padding:
                          const EdgeInsets.fromLTRB(16, 10, 16, 5),
                      child: Text(yearLabel,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1A237E),
                              letterSpacing: 0.3)),
                    ),
                    for (final sem in ['1st Semester', '2nd Semester']) ...[
                      if (_getSubjects(yearLabel, sem).isNotEmpty) ...[
                        Container(
                          color: const Color(0xFFF0F2F8),
                          padding:
                              const EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: Text(sem,
                              style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF3949AB),
                                  letterSpacing: 0.4)),
                        ),
                        for (final s in _getSubjects(yearLabel, sem))
                          _SubjectViewRow(label: s.description, code: s.code),
                      ],
                    ],
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reviews Tab Body
// ─────────────────────────────────────────────────────────────────────────────

class _ReviewsTabBody extends StatelessWidget {
  final Stream<QuerySnapshot> quizStream;
  final String filterYear;
  final bool hasFilters;
  final List<String> yearOptions;
  final List<QueryDocumentSnapshot> Function(List<QueryDocumentSnapshot>)
      applyFiltersAndSort;
  final ValueChanged<String> onYearChanged;
  final VoidCallback onSubjectViewTap;
  final VoidCallback onClearFilters;
  final void Function(String quizId, Map<String, dynamic> quiz) onEdit;
  final void Function(String quizId) onArchive;
  final void Function(String quizId, String title) onViewResults;

  const _ReviewsTabBody({
    required this.quizStream,
    required this.filterYear,
    required this.hasFilters,
    required this.yearOptions,
    required this.applyFiltersAndSort,
    required this.onYearChanged,
    required this.onSubjectViewTap,
    required this.onClearFilters,
    required this.onEdit,
    required this.onArchive,
    required this.onViewResults,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(
              bottom: BorderSide(color: Color(0xFFE8EAF6)),
            ),
          ),
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            Expanded(
              child: _FilterDropdown(
                icon: Icons.calendar_today_rounded,
                value: filterYear,
                items: yearOptions,
                onChanged: onYearChanged,
              ),
            ),
            const SizedBox(width: 10),
            // "All Subjects" is not a filter — tapping it just opens a
            // read-only list of the subjects for the selected year (or
            // all 4 years). The label itself never changes, and the
            // subjects inside the list aren't selectable/tappable.
            Expanded(
              child: _StaticFilterLabel(
                icon: Icons.menu_book_rounded,
                label: 'All Subjects',
                onTap: onSubjectViewTap,
              ),
            ),
            if (hasFilters) ...[
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onClearFilters,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8EAF6),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFC5CAE9)),
                  ),
                  child: const Icon(Icons.filter_alt_off_rounded,
                      size: 16, color: Color(0xFF1A237E)),
                ),
              ),
            ],
          ]),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: quizStream,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const Center(
                    child: CircularProgressIndicator(
                        color: Color(0xFF1A237E)));
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
                        const Text('Could not load reviews.',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15)),
                        const SizedBox(height: 6),
                        Text('${snapshot.error}',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey),
                            textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                );
              }

              final allDocs = snapshot.data?.docs ?? [];
              final quizzes = applyFiltersAndSort(allDocs);

              if (quizzes.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.quiz_outlined,
                          size: 64, color: Colors.grey[300]),
                      const SizedBox(height: 14),
                      Text(
                        allDocs.isEmpty
                            ? 'No reviews uploaded yet.'
                            : 'No reviews match the selected filter.',
                        style: TextStyle(
                            color: Colors.grey[500], fontSize: 15),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        allDocs.isEmpty
                            ? 'Tap "+ Create Review" to get started.'
                            : 'Try changing the year filter.',
                        style: TextStyle(
                            color: Colors.grey[400], fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                      if (hasFilters) ...[
                        const SizedBox(height: 14),
                        OutlinedButton.icon(
                          onPressed: onClearFilters,
                          icon: const Icon(
                              Icons.filter_alt_off_rounded,
                              size: 15),
                          label: const Text('Clear Filters'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor:
                                const Color(0xFF1A237E),
                            side: const BorderSide(
                                color: Color(0xFF1A237E)),
                            shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(8)),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }

              return ListView.separated(
                padding:
                    const EdgeInsets.fromLTRB(14, 12, 14, 100),
                itemCount: quizzes.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final doc = quizzes[index];
                  final quiz =
                      doc.data() as Map<String, dynamic>;
                  final quizId = doc.id;
                  return _QuizCard(
                    key: ValueKey(quizId),
                    quiz: quiz,
                    quizId: quizId,
                    onEdit: () => onEdit(quizId, quiz),
                    onArchive: () => onArchive(quizId),
                    onViewResults: () => onViewResults(
                        quizId, quiz['title'] ?? 'Untitled'),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Archive Tab Body  (Reviews + Modules sub-tabs for everyone; a third
// "Subjects" sub-tab is only added when isAdmin is true — archived
// subjects are an Admin-only concern and must never appear for
// instructor accounts. See ArchivedSubjectsList in modules_screen.dart,
// which owns its own Firestore stream — no extra plumbing needed here
// beyond conditionally dropping the widget in.)
// ─────────────────────────────────────────────────────────────────────────────

class _ArchiveTabBody extends StatelessWidget {
  final bool isAdmin;
  final Stream<QuerySnapshot> archiveStream;
  final Stream<QuerySnapshot> moduleArchiveStream;
  final void Function(String quizId) onRestore;
  final void Function(String quizId) onDeletePermanently;
  final void Function(String quizId, String title) onViewResults;
  final void Function(String docId) onRestoreModule;
  final void Function(String docId) onDeleteModulePermanently;

  const _ArchiveTabBody({
    required this.isAdmin,
    required this.archiveStream,
    required this.moduleArchiveStream,
    required this.onRestore,
    required this.onDeletePermanently,
    required this.onViewResults,
    required this.onRestoreModule,
    required this.onDeleteModulePermanently,
  });

  @override
  Widget build(BuildContext context) {
    // Instructors get 2 sub-tabs (Reviews, Modules). Admins get a 3rd
    // (Subjects) for managing archived subjects — that tab and its
    // content are never built at all for non-admin accounts.
    final tabCount = isAdmin ? 3 : 2;

    return DefaultTabController(
      length: tabCount,
      child: Column(
        children: [
          Container(
            decoration: const BoxDecoration(
              color: Color(0xFFFBE9E7),
              border: Border(bottom: BorderSide(color: Color(0xFFFFCCBC))),
            ),
            child: TabBar(
              labelColor: const Color(0xFFD84315),
              unselectedLabelColor: Color(0x80D84315),
              indicatorColor: const Color(0xFFD84315),
              indicatorWeight: 2.5,
              labelStyle: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 13),
              tabs: [
                const Tab(
                  icon: Icon(Icons.quiz_rounded, size: 16),
                  text: 'Reviews',
                  iconMargin: EdgeInsets.only(bottom: 2),
                ),
                const Tab(
                  icon: Icon(Icons.menu_book_rounded, size: 16),
                  text: 'Modules',
                  iconMargin: EdgeInsets.only(bottom: 2),
                ),
                // Admin-only tab.
                if (isAdmin)
                  const Tab(
                    icon: Icon(Icons.bookmark_remove_rounded, size: 16),
                    text: 'Subjects',
                    iconMargin: EdgeInsets.only(bottom: 2),
                  ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              children: [
                _ArchivedReviewsList(
                  archiveStream: archiveStream,
                  onRestore: onRestore,
                  onDeletePermanently: onDeletePermanently,
                  onViewResults: onViewResults,
                ),
                _ArchivedModulesList(
                  moduleArchiveStream: moduleArchiveStream,
                  onRestore: onRestoreModule,
                  onDeletePermanently: onDeleteModulePermanently,
                ),
                // Self-contained widget from modules_screen.dart — it owns
                // its own Firestore stream (archived subjects) and its own
                // Restore / Delete Permanently actions. Only ever built
                // when isAdmin is true, so instructor accounts never see
                // or load this tab.
                if (isAdmin) const ArchivedSubjectsList(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Archived Reviews List
// ─────────────────────────────────────────────────────────────────────────────

class _ArchivedReviewsList extends StatelessWidget {
  final Stream<QuerySnapshot> archiveStream;
  final void Function(String quizId) onRestore;
  final void Function(String quizId) onDeletePermanently;
  final void Function(String quizId, String title) onViewResults;

  const _ArchivedReviewsList({
    required this.archiveStream,
    required this.onRestore,
    required this.onDeletePermanently,
    required this.onViewResults,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: archiveStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(
              child: CircularProgressIndicator(color: Color(0xFFD84315)));
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('Error: ${snapshot.error}',
                style: const TextStyle(color: Colors.red)),
          );
        }

        final docs = snapshot.data?.docs ?? [];

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.inventory_2_outlined,
                    size: 64, color: Colors.grey[300]),
                const SizedBox(height: 14),
                Text('No archived reviews.',
                    style:
                        TextStyle(color: Colors.grey[500], fontSize: 15)),
                const SizedBox(height: 6),
                Text('Archived reviews will appear here.',
                    style:
                        TextStyle(color: Colors.grey[400], fontSize: 13)),
              ],
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final doc = docs[index];
            final quiz = doc.data() as Map<String, dynamic>;
            final quizId = doc.id;
            return _ArchivedQuizCard(
              key: ValueKey(quizId),
              quiz: quiz,
              quizId: quizId,
              onRestore: () => onRestore(quizId),
              onDelete: () => onDeletePermanently(quizId),
              onViewResults: () =>
                  onViewResults(quizId, quiz['title'] ?? 'Untitled'),
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Archived Modules List
// ─────────────────────────────────────────────────────────────────────────────

class _ArchivedModulesList extends StatelessWidget {
  final Stream<QuerySnapshot> moduleArchiveStream;
  final void Function(String docId) onRestore;
  final void Function(String docId) onDeletePermanently;

  const _ArchivedModulesList({
    required this.moduleArchiveStream,
    required this.onRestore,
    required this.onDeletePermanently,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: moduleArchiveStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(
              child: CircularProgressIndicator(color: Color(0xFFD84315)));
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('Error: ${snapshot.error}',
                style: const TextStyle(color: Colors.red)),
          );
        }

        final docs = snapshot.data?.docs ?? [];

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.folder_off_rounded,
                    size: 64, color: Colors.grey[300]),
                const SizedBox(height: 14),
                Text('No archived modules.',
                    style:
                        TextStyle(color: Colors.grey[500], fontSize: 15)),
                const SizedBox(height: 6),
                Text('Archived modules will appear here.',
                    style:
                        TextStyle(color: Colors.grey[400], fontSize: 13)),
              ],
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
          itemCount: docs.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final doc = docs[index];
            final data = doc.data() as Map<String, dynamic>;
            return _ArchivedModuleCard(
              key: ValueKey(doc.id),
              data: data,
              docId: doc.id,
              onRestore: () => onRestore(doc.id),
              onDelete: () => onDeletePermanently(doc.id),
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Archived Quiz Card
// ─────────────────────────────────────────────────────────────────────────────

class _ArchivedQuizCard extends StatelessWidget {
  final Map<String, dynamic> quiz;
  final String quizId;
  final VoidCallback onRestore;
  final VoidCallback onDelete;
  final VoidCallback onViewResults;

  const _ArchivedQuizCard({
    super.key,
    required this.quiz,
    required this.quizId,
    required this.onRestore,
    required this.onDelete,
    required this.onViewResults,
  });

  @override
  Widget build(BuildContext context) {
    final title = quiz['title'] as String? ?? 'Untitled Review';
    final questions = quiz['questions'] as List? ?? [];
    final yearLevel = quiz['yearLevel'] as String? ?? '';
    final subject = quiz['subject'] as String? ?? '';
    final archivedDate = _formatArchivedDate(quiz['archivedAt']);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFBE9E7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFCCBC), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFD84315).withOpacity(0.07),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 10, 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFCCBC),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Icon(
                    Icons.inventory_2_rounded,
                    color: Color(0xFFD84315),
                    size: 17,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            color: Color(0xFFBF360C),
                          )),
                      const SizedBox(height: 3),
                      Wrap(
                        spacing: 5,
                        runSpacing: 3,
                        children: [
                          _MetaChip(
                              icon: Icons.help_outline_rounded,
                              label:
                                  '${questions.length} question${questions.length != 1 ? 's' : ''}'),
                          if (yearLevel.isNotEmpty)
                            _MetaChip(
                                icon: Icons.school_rounded,
                                label: yearLevel),
                          if (subject.isNotEmpty)
                            _MetaChip(
                                icon: Icons.menu_book_rounded,
                                label: subject,
                                maxWidth: 150),
                          if (archivedDate != null)
                            _MetaChip(
                                icon: Icons.event_busy_rounded,
                                label: 'Archived $archivedDate'),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _ActionButton(
                      label: 'Restore',
                      icon: Icons.restore_rounded,
                      color: const Color(0xFF1A237E),
                      onTap: onRestore,
                    ),
                    const SizedBox(height: 4),
                    _ActionButton(
                      label: 'Delete',
                      icon: Icons.delete_forever_rounded,
                      color: Colors.red.shade600,
                      onTap: onDelete,
                    ),
                  ],
                ),
              ],
            ),
          ),
          InkWell(
            onTap: onViewResults,
            borderRadius:
                const BorderRadius.vertical(bottom: Radius.circular(14)),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 7),
              decoration: const BoxDecoration(
                color: Color(0xFFD84315),
                borderRadius:
                    BorderRadius.vertical(bottom: Radius.circular(14)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bar_chart_rounded,
                      color: Colors.white, size: 14),
                  SizedBox(width: 6),
                  Text(
                    'View Results',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12),
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

// ─────────────────────────────────────────────────────────────────────────────
// Archived Module Card
// ─────────────────────────────────────────────────────────────────────────────

class _ArchivedModuleCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final String docId;
  final VoidCallback onRestore;
  final VoidCallback onDelete;

  const _ArchivedModuleCard({
    super.key,
    required this.data,
    required this.docId,
    required this.onRestore,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final title = data['title'] as String? ?? 'Untitled Module';
    final clusterCode = data['cluster'] as String? ?? '';
    final clusterLabel = data['clusterLabel'] as String? ?? clusterCode;
    final archivedDate = _formatArchivedDate(data['archivedAt']);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFBE9E7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFCCBC), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFD84315).withOpacity(0.07),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: const Color(0xFFFFCCBC),
                borderRadius: BorderRadius.circular(9),
              ),
              child: const Icon(
                Icons.menu_book_rounded,
                color: Color(0xFFD84315),
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Color(0xFFBF360C),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: 5,
                    runSpacing: 3,
                    children: [
                      if (clusterCode.isNotEmpty)
                        _MetaChip(
                          icon: Icons.label_rounded,
                          label: clusterCode,
                        ),
                      if (clusterLabel.isNotEmpty)
                        _MetaChip(
                          icon: Icons.menu_book_rounded,
                          label: clusterLabel,
                          maxWidth: 150,
                        ),
                      if (archivedDate != null)
                        _MetaChip(
                          icon: Icons.event_busy_rounded,
                          label: 'Archived $archivedDate',
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _ActionButton(
                  label: 'Restore',
                  icon: Icons.restore_rounded,
                  color: const Color(0xFF1A237E),
                  onTap: onRestore,
                ),
                const SizedBox(height: 4),
                _ActionButton(
                  label: 'Delete',
                  icon: Icons.delete_forever_rounded,
                  color: Colors.red.shade600,
                  onTap: onDelete,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Quiz Card
// ─────────────────────────────────────────────────────────────────────────────
//
// COLOR NOTE: Reviews stays indigo-only, whether or not a review has
// takers — no separate accent color. Archive keeps its own orange/red
// palette, so the two tabs are still visually distinct from each other.
// ─────────────────────────────────────────────────────────────────────────────

class _QuizCard extends StatelessWidget {
  final Map<String, dynamic> quiz;
  final String quizId;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
  final VoidCallback onViewResults;

  const _QuizCard({
    super.key,
    required this.quiz,
    required this.quizId,
    required this.onEdit,
    required this.onArchive,
    required this.onViewResults,
  });

  @override
  Widget build(BuildContext context) {
    final title = quiz['title'] as String? ?? 'Untitled Review';
    final questions = quiz['questions'] as List? ?? [];
    final yearLevel = quiz['yearLevel'] as String? ?? '';
    final subject = quiz['subject'] as String? ?? '';

    return FutureBuilder<AggregateQuerySnapshot>(
      future: FirebaseFirestore.instance
          .collection('quiz_results')
          .where('quizId', isEqualTo: quizId)
          .count()
          .get(),
      builder: (context, snap) {
        final takenCount = snap.data?.count ?? 0;
        final hasTakers = takenCount > 0;

        // Reviews stays indigo regardless of takers — no accent swap.
        final cardBorderColor = const Color(0xFFE8EAF6);
        final cardBgColor = Colors.white;
        final iconBgColor = const Color(0xFFE8EAF6);
        final iconColor = const Color(0xFF1A237E);

        return Container(
          decoration: BoxDecoration(
            color: cardBgColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: cardBorderColor, width: 1),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF1A237E).withOpacity(0.05),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 10, 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: iconBgColor,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(
                        hasTakers
                            ? Icons.check_circle_rounded
                            : Icons.quiz_rounded,
                        color: iconColor,
                        size: 17,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                                color: Color(0xFF1A237E),
                              )),
                          const SizedBox(height: 3),
                          Wrap(
                            spacing: 5,
                            runSpacing: 3,
                            children: [
                              _MetaChip(
                                  icon: Icons.help_outline_rounded,
                                  label:
                                      '${questions.length} question${questions.length != 1 ? 's' : ''}'),
                              if (yearLevel.isNotEmpty)
                                _MetaChip(
                                    icon: Icons.school_rounded,
                                    label: yearLevel),
                              if (subject.isNotEmpty)
                                _MetaChip(
                                    icon: Icons.menu_book_rounded,
                                    label: subject,
                                    maxWidth: 170),
                              if (hasTakers)
                                _MetaChip(
                                  icon: Icons.people_rounded,
                                  label:
                                      '$takenCount student${takenCount != 1 ? 's' : ''} taken',
                                  isAccent: true,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _ActionButton(
                          label: 'Edit',
                          icon: Icons.edit_outlined,
                          color: const Color(0xFF1A237E),
                          onTap: onEdit,
                        ),
                        const SizedBox(height: 4),
                        _ActionButton(
                          label: 'Archive',
                          icon: Icons.inventory_2_rounded,
                          color: const Color(0xFF1A237E),
                          onTap: onArchive,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              InkWell(
                onTap: onViewResults,
                borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(14)),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: const BoxDecoration(
                    color: Color(0xFF1A237E),
                    borderRadius: BorderRadius.vertical(
                        bottom: Radius.circular(14)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.bar_chart_rounded,
                          color: Colors.white, size: 14),
                      const SizedBox(width: 6),
                      Text(
                        hasTakers
                            ? 'View Results ($takenCount)'
                            : 'View Results',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Admin Overview Tab Body (only mounted for accounts with accountType ==
// 'admin' — see TeacherHomeScreen._isAdmin). Shows platform-wide user
// counts and a filterable, deletable user list, while the admin keeps
// full access to the same Reviews/Modules/Archive/Requests tabs as an
// instructor.
//
// MONITORING: a Users / Reviews / Modules switcher sits below the stat
// cards.
//   - Users:   the original filterable/deletable account list. Tapping
//              an instructor or admin row still opens the read-only
//              _InstructorUploadsSheet for that one account.
//   - Reviews: every quiz on the platform (from every instructor), in
//              one read-only, uploader-labeled list.
//   - Modules: every module on the platform, same treatment.
// Reviews and Modules are 100% read-only — no edit/archive/delete is
// ever rendered here. Those actions only exist on each instructor's own
// Reviews/Archive tabs. This is a UI-layer restriction; make sure your
// Firestore security rules also only allow a document's own
// createdBy/uploadedBy uid (not "any teacher") to update or delete it,
// so the restriction holds even against direct API calls.
// ─────────────────────────────────────────────────────────────────────────────

enum _AdminUserFilter { all, students, instructors, admins }

enum _OverviewSection { users, reviews, modules }

class _AdminOverviewTabBody extends StatefulWidget {
  const _AdminOverviewTabBody();

  @override
  State<_AdminOverviewTabBody> createState() => _AdminOverviewTabBodyState();
}

class _AdminOverviewTabBodyState extends State<_AdminOverviewTabBody> {
  _AdminUserFilter _filter = _AdminUserFilter.all;
  _OverviewSection _section = _OverviewSection.users;
  final _currentUid = FirebaseAuth.instance.currentUser?.uid;

  String _displayName(Map<String, dynamic> data, String fallbackEmail) {
    final name = data['name'] as String?;
    if (name != null && name.trim().isNotEmpty) return name;
    final first = data['firstName'] as String? ?? '';
    final last = data['lastName'] as String? ?? '';
    final combined = '$first $last'.trim();
    if (combined.isNotEmpty) return combined;
    return fallbackEmail.isNotEmpty ? fallbackEmail.split('@').first : 'User';
  }

  // 'role' is either 'student' or 'teacher'. For 'teacher', 'accountType'
  // further distinguishes 'instructor' from 'admin' (matches the check
  // already used to route admins in home_screen.dart).
  String _accountTypeOf(Map<String, dynamic> data) {
    final role = data['role'] as String? ?? 'student';
    if (role != 'teacher') return 'student';
    final accountType = data['accountType'] as String?;
    return accountType == 'admin' ? 'admin' : 'instructor';
  }

  // Opens the read-only "what has this account uploaded" monitoring sheet.
  // Only ever called for instructor/admin rows — see _AdminUserTile's
  // onViewUploads wiring below.
  void _showInstructorUploads(String uid, String name) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _InstructorUploadsSheet(uid: uid, name: name),
    );
  }

  Future<void> _confirmAndDelete(String uid, String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove User',
            style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
        content: Text(
            "This will permanently delete $name's account data. This cannot be undone."),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    try {
      // 1. Remove the Firestore profile — this we can always do directly.
      await FirebaseFirestore.instance.collection('users').doc(uid).delete();

      // 2. Remove the Firebase Auth account. Client SDKs can only delete
      //    the *currently signed-in* user's own Auth account — deleting
      //    someone else's requires the Admin SDK, which only runs
      //    server-side. Deploy a callable Cloud Function named
      //    'deleteUserAccount' (accepting { uid }) that internally calls
      //    admin.auth().deleteUser(uid), and add the cloud_functions
      //    package to pubspec.yaml for this call to succeed.
      try {
        await FirebaseFunctions.instance
            .httpsCallable('deleteUserAccount')
            .call({'uid': uid});
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('User removed.')));
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'User data removed. Deploy the deleteUserAccount Cloud Function to also remove their login.'),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to delete user: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final usersStream =
        FirebaseFirestore.instance.collection('users').snapshots();

    return StreamBuilder<QuerySnapshot>(
      stream: usersStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(
              child: CircularProgressIndicator(color: Color(0xFF1A237E)));
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('Error: ${snapshot.error}',
                style: const TextStyle(color: Colors.red)),
          );
        }

        final docs = snapshot.data?.docs ?? [];

        // uid -> display name, built once here and handed down to the
        // Reviews/Modules sections below so they can label each card
        // with its uploader without a separate Firestore read per card.
        final namesByUid = <String, String>{
          for (final doc in docs)
            doc.id: _displayName(
              doc.data() as Map<String, dynamic>,
              (doc.data() as Map<String, dynamic>)['email'] as String? ?? '',
            ),
        };

        int studentCount = 0;
        int instructorCount = 0;
        int adminCount = 0;

        for (final doc in docs) {
          final data = doc.data() as Map<String, dynamic>;
          switch (_accountTypeOf(data)) {
            case 'student':
              studentCount++;
              break;
            case 'instructor':
              instructorCount++;
              break;
            case 'admin':
              adminCount++;
              break;
          }
        }

        final filteredDocs = docs.where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          final type = _accountTypeOf(data);
          switch (_filter) {
            case _AdminUserFilter.all:
              return true;
            case _AdminUserFilter.students:
              return type == 'student';
            case _AdminUserFilter.instructors:
              return type == 'instructor';
            case _AdminUserFilter.admins:
              return type == 'admin';
          }
        }).toList();

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
              child: Row(
                children: [
                  Expanded(
                    child: _AdminStatCard(
                      icon: Icons.school_rounded,
                      value: studentCount,
                      label: 'Students',
                      color: const Color(0xFF1A237E),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _AdminStatCard(
                      icon: Icons.person_rounded,
                      value: instructorCount,
                      label: 'Instructors',
                      color: const Color(0xFF00695C),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _AdminStatCard(
                      icon: Icons.shield_rounded,
                      value: adminCount,
                      label: 'Admins',
                      color: const Color(0xFFD84315),
                    ),
                  ),
                ],
              ),
            ),

            // ── Users / Reviews / Modules switcher ─────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
              child: Row(
                children: [
                  Expanded(
                    child: _SectionTabButton(
                      icon: Icons.people_alt_rounded,
                      label: 'Users',
                      isActive: _section == _OverviewSection.users,
                      onTap: () =>
                          setState(() => _section = _OverviewSection.users),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _SectionTabButton(
                      icon: Icons.quiz_rounded,
                      label: 'Reviews',
                      isActive: _section == _OverviewSection.reviews,
                      onTap: () =>
                          setState(() => _section = _OverviewSection.reviews),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _SectionTabButton(
                      icon: Icons.menu_book_rounded,
                      label: 'Modules',
                      isActive: _section == _OverviewSection.modules,
                      onTap: () =>
                          setState(() => _section = _OverviewSection.modules),
                    ),
                  ),
                ],
              ),
            ),

            // Role filter chips only make sense in the Users view.
            if (_section == _OverviewSection.users) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _FilterChip(
                        label: 'All',
                        isActive: _filter == _AdminUserFilter.all,
                        onTap: () =>
                            setState(() => _filter = _AdminUserFilter.all),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: 'Students',
                        isActive: _filter == _AdminUserFilter.students,
                        onTap: () => setState(
                            () => _filter = _AdminUserFilter.students),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: 'Instructors',
                        isActive: _filter == _AdminUserFilter.instructors,
                        onTap: () => setState(
                            () => _filter = _AdminUserFilter.instructors),
                      ),
                      const SizedBox(width: 8),
                      _FilterChip(
                        label: 'Admins',
                        isActive: _filter == _AdminUserFilter.admins,
                        onTap: () => setState(
                            () => _filter = _AdminUserFilter.admins),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],

            Expanded(
              child: Builder(builder: (context) {
                // An if/else chain (rather than a switch) so the function
                // always, unambiguously returns a Widget — a switch over
                // an enum inside a closure isn't always recognized by the
                // analyzer as exhaustive, and an unmatched switch with no
                // default silently falls through to an implicit `null`
                // return, which is what caused the "build function
                // returned null" crash.
                if (_section == _OverviewSection.reviews) {
                  return _AllReviewsMonitorList(namesByUid: namesByUid);
                }
                if (_section == _OverviewSection.modules) {
                  return _AllModulesMonitorList(namesByUid: namesByUid);
                }
                // _section == _OverviewSection.users
                return filteredDocs.isEmpty
                    ? Center(
                        child: Text('No users in this category.',
                            style: TextStyle(color: Colors.grey[500])),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
                        itemCount: filteredDocs.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final doc = filteredDocs[index];
                          final data = doc.data() as Map<String, dynamic>;
                          final uid = doc.id;
                          final email = data['email'] as String? ?? '';
                          final name = _displayName(data, email);
                          final type = _accountTypeOf(data);
                          final isSelf = uid == _currentUid;

                          return _AdminUserTile(
                            name: name,
                            email: email,
                            accountType: type,
                            canDelete: !isSelf,
                            onDelete: () => _confirmAndDelete(uid, name),
                            // Students don't upload reviews/modules, so
                            // there's nothing to monitor for them.
                            onViewUploads: type == 'student'
                                ? null
                                : () => _showInstructorUploads(uid, name),
                          );
                        },
                      );
              }),
            ),
          ],
        );
      },
    );
  }
}

class _AdminStatCard extends StatelessWidget {
  final IconData icon;
  final int value;
  final String label;
  final Color color;
  const _AdminStatCard({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE8EAF6)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 6),
            Text('$value',
                style: TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold, color: color)),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
      );
}

// Pill-style toggle used for the Users / Reviews / Modules switcher at
// the top of the Admin Overview tab. Visually distinct from _FilterChip
// (rounded rectangle, fills its Expanded width) so it doesn't get
// confused with the role filter chips shown only in the Users view.
class _SectionTabButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  const _SectionTabButton({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF1A237E) : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isActive
                  ? const Color(0xFF1A237E)
                  : const Color(0xFFD0D5E8),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 15,
                  color: isActive ? Colors.white : const Color(0xFF3949AB)),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isActive ? Colors.white : const Color(0xFF3949AB),
                ),
              ),
            ],
          ),
        ),
      );
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  const _FilterChip({
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: isActive ? const Color(0xFF1A237E) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: isActive
                    ? const Color(0xFF1A237E)
                    : const Color(0xFFD0D5E8)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isActive) ...[
                const Icon(Icons.check_rounded, size: 14, color: Colors.white),
                const SizedBox(width: 4),
              ],
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isActive ? Colors.white : const Color(0xFF3949AB))),
            ],
          ),
        ),
      );
}

// Now tappable for instructor/admin rows (onViewUploads != null) to open
// the read-only uploads monitoring sheet. The tap target wraps only the
// avatar/name/badge area, kept as a sibling of the delete IconButton
// rather than nesting them, so the delete tap isn't swallowed by the
// row's InkWell.
class _AdminUserTile extends StatelessWidget {
  final String name;
  final String email;
  final String accountType; // 'student' | 'instructor' | 'admin'
  final bool canDelete;
  final VoidCallback onDelete;
  final VoidCallback? onViewUploads;
  const _AdminUserTile({
    required this.name,
    required this.email,
    required this.accountType,
    required this.canDelete,
    required this.onDelete,
    this.onViewUploads,
  });

  Color get _badgeColor {
    switch (accountType) {
      case 'admin':
        return const Color(0xFFD84315);
      case 'instructor':
        return const Color(0xFF00695C);
      default:
        return const Color(0xFF1A237E);
    }
  }

  IconData get _avatarIcon {
    switch (accountType) {
      case 'admin':
        return Icons.shield_rounded;
      case 'instructor':
        return Icons.person_rounded;
      default:
        return Icons.school_rounded;
    }
  }

  String get _badgeLabel {
    switch (accountType) {
      case 'admin':
        return 'Admin';
      case 'instructor':
        return 'Instructor';
      default:
        return 'Student';
    }
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE8EAF6)),
        ),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: onViewUploads,
                borderRadius: BorderRadius.circular(10),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: _badgeColor.withOpacity(0.12),
                      child: Icon(_avatarIcon, color: _badgeColor, size: 18),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 14)),
                          if (email.isNotEmpty)
                            Text(email,
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey[600])),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: _badgeColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(_badgeLabel,
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: _badgeColor)),
                    ),
                    if (onViewUploads != null) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.chevron_right_rounded,
                          color: Colors.grey[400], size: 18),
                    ],
                  ],
                ),
              ),
            ),
            if (canDelete) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded,
                    color: Colors.red, size: 20),
                onPressed: onDelete,
                tooltip: 'Remove user',
              ),
            ],
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Instructor/Admin Uploads Monitoring Sheet
// ─────────────────────────────────────────────────────────────────────────────
//
// Read-only. Opened from _AdminUserTile when the admin taps an
// instructor or admin row in the Overview list. Shows two tabs —
// Reviews (from 'quizzes' where createdBy == uid) and Modules (from
// 'modules' where uploadedBy == uid) — including archived items, so the
// admin has full visibility into what that account has published.
// There is deliberately no edit/archive/delete action here: monitoring
// only. Those actions still live on the account's own Reviews/Archive
// tabs.
// ─────────────────────────────────────────────────────────────────────────────

class _InstructorUploadsSheet extends StatelessWidget {
  final String uid;
  final String name;

  const _InstructorUploadsSheet({required this.uid, required this.name});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.93,
        minChildSize: 0.4,
        builder: (_, ctrl) => Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Row(
                children: [
                  const Icon(Icons.visibility_rounded,
                      color: Color(0xFF1A237E), size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "$name's Uploads",
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: Color(0xFF1A237E)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(bottom: BorderSide(color: Color(0xFFE8EAF6))),
              ),
              child: const TabBar(
                labelColor: Color(0xFF1A237E),
                unselectedLabelColor: Color(0x801A237E),
                indicatorColor: Color(0xFF1A237E),
                indicatorWeight: 2.5,
                labelStyle:
                    TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                tabs: [
                  Tab(
                    icon: Icon(Icons.quiz_rounded, size: 16),
                    text: 'Reviews',
                    iconMargin: EdgeInsets.only(bottom: 2),
                  ),
                  Tab(
                    icon: Icon(Icons.menu_book_rounded, size: 16),
                    text: 'Modules',
                    iconMargin: EdgeInsets.only(bottom: 2),
                  ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _InstructorReviewsList(uid: uid, scrollController: ctrl),
                  _InstructorModulesList(uid: uid, scrollController: ctrl),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InstructorReviewsList extends StatelessWidget {
  final String uid;
  final ScrollController scrollController;
  const _InstructorReviewsList(
      {required this.uid, required this.scrollController});

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection('quizzes')
        .where('createdBy', isEqualTo: uid)
        .snapshots();

    return StreamBuilder<QuerySnapshot>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(
              child: CircularProgressIndicator(color: Color(0xFF1A237E)));
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('Error: ${snapshot.error}',
                style: const TextStyle(color: Colors.red)),
          );
        }

        final docs = snapshot.data?.docs ?? [];

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.quiz_outlined, size: 56, color: Colors.grey[300]),
                const SizedBox(height: 12),
                Text('No reviews uploaded yet.',
                    style: TextStyle(color: Colors.grey[500], fontSize: 14)),
              ],
            ),
          );
        }

        final sorted = [...docs];
        sorted.sort((a, b) {
          final aData = a.data() as Map<String, dynamic>;
          final bData = b.data() as Map<String, dynamic>;
          final aTime = aData['createdAt'];
          final bTime = bData['createdAt'];
          if (aTime == null && bTime == null) return 0;
          if (aTime == null) return 1;
          if (bTime == null) return -1;
          return (bTime as dynamic).compareTo(aTime as dynamic);
        });

        return ListView.separated(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          itemCount: sorted.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final data = sorted[index].data() as Map<String, dynamic>;
            final questions = data['questions'] as List? ?? [];
            final yearLevel = data['yearLevel'] as String? ?? '';
            final subject = data['subject'] as String? ?? '';
            final isArchived = data['archived'] as bool? ?? false;

            return _MonitorCard(
              icon: Icons.quiz_rounded,
              title: data['title'] as String? ?? 'Untitled Review',
              chips: [
                '${questions.length} question${questions.length != 1 ? 's' : ''}',
                if (yearLevel.isNotEmpty) yearLevel,
                if (subject.isNotEmpty) subject,
              ],
              isArchived: isArchived,
              dateLabel: _formatArchivedDate(data['createdAt']),
            );
          },
        );
      },
    );
  }
}

class _InstructorModulesList extends StatelessWidget {
  final String uid;
  final ScrollController scrollController;
  const _InstructorModulesList(
      {required this.uid, required this.scrollController});

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection('modules')
        .where('uploadedBy', isEqualTo: uid)
        .snapshots();

    return StreamBuilder<QuerySnapshot>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(
              child: CircularProgressIndicator(color: Color(0xFF1A237E)));
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('Error: ${snapshot.error}',
                style: const TextStyle(color: Colors.red)),
          );
        }

        final docs = snapshot.data?.docs ?? [];

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.folder_off_rounded,
                    size: 56, color: Colors.grey[300]),
                const SizedBox(height: 12),
                Text('No modules uploaded yet.',
                    style: TextStyle(color: Colors.grey[500], fontSize: 14)),
              ],
            ),
          );
        }

        final sorted = [...docs];
        sorted.sort((a, b) {
          final aData = a.data() as Map<String, dynamic>;
          final bData = b.data() as Map<String, dynamic>;
          // Field name for module creation time isn't confirmed in the
          // original schema (only 'archivedAt' is used elsewhere), so
          // this checks the common alternatives and falls back to no
          // sort key if none are present.
          final aTime = aData['uploadedAt'] ?? aData['createdAt'];
          final bTime = bData['uploadedAt'] ?? bData['createdAt'];
          if (aTime == null && bTime == null) return 0;
          if (aTime == null) return 1;
          if (bTime == null) return -1;
          return (bTime as dynamic).compareTo(aTime as dynamic);
        });

        return ListView.separated(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          itemCount: sorted.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final data = sorted[index].data() as Map<String, dynamic>;
            final clusterCode = data['cluster'] as String? ?? '';
            final clusterLabel = data['clusterLabel'] as String? ?? clusterCode;
            final isArchived = data['archived'] as bool? ?? false;
            final dateLabel =
                _formatArchivedDate(data['uploadedAt'] ?? data['createdAt']);

            return _MonitorCard(
              icon: Icons.menu_book_rounded,
              title: data['title'] as String? ?? 'Untitled Module',
              chips: [
                if (clusterCode.isNotEmpty) clusterCode,
                if (clusterLabel.isNotEmpty && clusterLabel != clusterCode)
                  clusterLabel,
              ],
              isArchived: isArchived,
              dateLabel: dateLabel,
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Platform-wide Reviews / Modules monitoring lists — the "Reviews" and
// "Modules" sections of the Admin Overview tab. Unlike
// _InstructorReviewsList / _InstructorModulesList above (scoped to one
// uid, shown inside a sheet), these stream every document in the
// collection, across every instructor, and GROUP them by uploader —
// one collapsible card per instructor/admin, named after them, that
// expands to show everything that account has uploaded. This is the
// "organizer" the client asked for: content is filed under the
// person who posted it instead of appearing as one long flat list.
//
// Grouping uses the namesByUid map built once in
// _AdminOverviewTabBodyState.build() from the users stream that's
// already being fetched for the stat counts, so no extra reads are
// needed per card. Read-only throughout — no edit/archive/delete.
// ─────────────────────────────────────────────────────────────────────────────

class _AllReviewsMonitorList extends StatelessWidget {
  final Map<String, String> namesByUid;
  const _AllReviewsMonitorList({required this.namesByUid});

  @override
  Widget build(BuildContext context) {
    final stream =
        FirebaseFirestore.instance.collection('quizzes').snapshots();

    return StreamBuilder<QuerySnapshot>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(
              child: CircularProgressIndicator(color: Color(0xFF1A237E)));
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('Error: ${snapshot.error}',
                style: const TextStyle(color: Colors.red)),
          );
        }

        final docs = snapshot.data?.docs ?? [];

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.quiz_outlined, size: 64, color: Colors.grey[300]),
                const SizedBox(height: 14),
                Text('No reviews uploaded on the platform yet.',
                    style: TextStyle(color: Colors.grey[500], fontSize: 15),
                    textAlign: TextAlign.center),
              ],
            ),
          );
        }

        // ── Group by uploader (createdBy) ──────────────────────────────
        final grouped = <String, List<QueryDocumentSnapshot>>{};
        for (final doc in docs) {
          final data = doc.data() as Map<String, dynamic>;
          final uid = data['createdBy'] as String? ?? '';
          grouped.putIfAbsent(uid, () => []).add(doc);
        }

        final groupUids = grouped.keys.toList()
          ..sort((a, b) => (namesByUid[a] ?? 'Unknown Instructor')
              .toLowerCase()
              .compareTo(
                  (namesByUid[b] ?? 'Unknown Instructor').toLowerCase()));

        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
          itemCount: groupUids.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final uid = groupUids[index];
            final items = [...grouped[uid]!];
            items.sort((a, b) {
              final aData = a.data() as Map<String, dynamic>;
              final bData = b.data() as Map<String, dynamic>;
              final aTime = aData['createdAt'];
              final bTime = bData['createdAt'];
              if (aTime == null && bTime == null) return 0;
              if (aTime == null) return 1;
              if (bTime == null) return -1;
              return (bTime as dynamic).compareTo(aTime as dynamic);
            });

            return _InstructorGroupCard(
              name: namesByUid[uid] ?? 'Unknown Instructor',
              count: items.length,
              children: [
                for (final doc in items)
                  Builder(builder: (context) {
                    final data = doc.data() as Map<String, dynamic>;
                    final questions = data['questions'] as List? ?? [];
                    final yearLevel = data['yearLevel'] as String? ?? '';
                    final subject = data['subject'] as String? ?? '';
                    final isArchived = data['archived'] as bool? ?? false;

                    return _MonitorCard(
                      icon: Icons.quiz_rounded,
                      title: data['title'] as String? ?? 'Untitled Review',
                      chips: [
                        '${questions.length} question${questions.length != 1 ? 's' : ''}',
                        if (yearLevel.isNotEmpty) yearLevel,
                        if (subject.isNotEmpty) subject,
                      ],
                      isArchived: isArchived,
                      dateLabel: _formatArchivedDate(data['createdAt']),
                    );
                  }),
              ],
            );
          },
        );
      },
    );
  }
}

class _AllModulesMonitorList extends StatelessWidget {
  final Map<String, String> namesByUid;
  const _AllModulesMonitorList({required this.namesByUid});

  @override
  Widget build(BuildContext context) {
    final stream =
        FirebaseFirestore.instance.collection('modules').snapshots();

    return StreamBuilder<QuerySnapshot>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(
              child: CircularProgressIndicator(color: Color(0xFF1A237E)));
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('Error: ${snapshot.error}',
                style: const TextStyle(color: Colors.red)),
          );
        }

        final docs = snapshot.data?.docs ?? [];

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.folder_off_rounded,
                    size: 64, color: Colors.grey[300]),
                const SizedBox(height: 14),
                Text('No modules uploaded on the platform yet.',
                    style: TextStyle(color: Colors.grey[500], fontSize: 15),
                    textAlign: TextAlign.center),
              ],
            ),
          );
        }

        // ── Group by uploader (uploadedBy) ─────────────────────────────
        final grouped = <String, List<QueryDocumentSnapshot>>{};
        for (final doc in docs) {
          final data = doc.data() as Map<String, dynamic>;
          final uid = data['uploadedBy'] as String? ?? '';
          grouped.putIfAbsent(uid, () => []).add(doc);
        }

        final groupUids = grouped.keys.toList()
          ..sort((a, b) => (namesByUid[a] ?? 'Unknown Instructor')
              .toLowerCase()
              .compareTo(
                  (namesByUid[b] ?? 'Unknown Instructor').toLowerCase()));

        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
          itemCount: groupUids.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final uid = groupUids[index];
            final items = [...grouped[uid]!];
            items.sort((a, b) {
              final aData = a.data() as Map<String, dynamic>;
              final bData = b.data() as Map<String, dynamic>;
              final aTime = aData['uploadedAt'] ?? aData['createdAt'];
              final bTime = bData['uploadedAt'] ?? bData['createdAt'];
              if (aTime == null && bTime == null) return 0;
              if (aTime == null) return 1;
              if (bTime == null) return -1;
              return (bTime as dynamic).compareTo(aTime as dynamic);
            });

            return _InstructorGroupCard(
              name: namesByUid[uid] ?? 'Unknown Instructor',
              count: items.length,
              children: [
                for (final doc in items)
                  Builder(builder: (context) {
                    final data = doc.data() as Map<String, dynamic>;
                    final clusterCode = data['cluster'] as String? ?? '';
                    final clusterLabel =
                        data['clusterLabel'] as String? ?? clusterCode;
                    final isArchived = data['archived'] as bool? ?? false;
                    final dateLabel = _formatArchivedDate(
                        data['uploadedAt'] ?? data['createdAt']);

                    return _MonitorCard(
                      icon: Icons.menu_book_rounded,
                      title: data['title'] as String? ?? 'Untitled Module',
                      chips: [
                        if (clusterCode.isNotEmpty) clusterCode,
                        if (clusterLabel.isNotEmpty &&
                            clusterLabel != clusterCode)
                          clusterLabel,
                      ],
                      isArchived: isArchived,
                      dateLabel: dateLabel,
                    );
                  }),
              ],
            );
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Instructor Group Card — the collapsible "organizer" header. Tapping the
// row expands/collapses the list of that instructor's uploads (passed in
// as `children`, already-built _MonitorCard widgets). Used by both
// _AllReviewsMonitorList and _AllModulesMonitorList above so Reviews and
// Modules share the exact same grouping presentation, as requested.
// Collapsed by default so the Reviews/Modules tab opens as a clean list
// of instructor names rather than a wall of cards.
//
// FIX: the avatar/count accent previously reused the general navy brand
// color (0xFF1A237E). Changed to the same teal (0xFF00695C) already used
// elsewhere in this file for "instructor" — e.g. _AdminUserTile's
// instructor badge and the "Instructors" stat card — so the person icon
// here is visually consistent with the rest of the admin UI instead of
// clashing with it.
// ─────────────────────────────────────────────────────────────────────────────

class _InstructorGroupCard extends StatefulWidget {
  final String name;
  final int count;
  final List<Widget> children;

  const _InstructorGroupCard({
    required this.name,
    required this.count,
    required this.children,
  });

  @override
  State<_InstructorGroupCard> createState() => _InstructorGroupCardState();
}

class _InstructorGroupCardState extends State<_InstructorGroupCard> {
  bool _expanded = false;

  static const _accentColor = Color(0xFF00695C);

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE8EAF6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: _accentColor.withOpacity(0.12),
                    child: const Icon(Icons.person_rounded,
                        color: _accentColor, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 14),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _accentColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${widget.count}',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: _accentColor),
                    ),
                  ),
                  const SizedBox(width: 6),
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(Icons.chevron_right_rounded,
                        color: Colors.grey[400], size: 20),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 200),
            sizeCurve: Curves.easeInOut,
            crossFadeState:
                _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity, height: 0),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                children: [
                  for (final child in widget.children) ...[
                    child,
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Read-only card used both by the per-instructor uploads sheet and,
// nested inside _InstructorGroupCard, by the platform-wide Reviews/
// Modules sections. No actions — this is purely for the admin to see
// what exists, not to manage it.
class _MonitorCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<String> chips;
  final bool isArchived;
  final String? dateLabel;

  const _MonitorCard({
    required this.icon,
    required this.title,
    required this.chips,
    this.isArchived = false,
    this.dateLabel,
  });

  @override
  Widget build(BuildContext context) {
    final baseColor =
        isArchived ? const Color(0xFFD84315) : const Color(0xFF1A237E);
    final bgColor = isArchived ? const Color(0xFFFBE9E7) : Colors.white;
    final borderColor =
        isArchived ? const Color(0xFFFFCCBC) : const Color(0xFFE8EAF6);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: 1.2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: baseColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(icon, color: baseColor, size: 17),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: baseColor)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 5,
                  runSpacing: 3,
                  children: [
                    for (final c in chips)
                      _MetaChip(
                          icon: Icons.label_rounded, label: c, maxWidth: 170),
                    if (isArchived)
                      _MetaChip(
                          icon: Icons.inventory_2_rounded, label: 'Archived'),
                    if (dateLabel != null)
                      _MetaChip(icon: Icons.event_rounded, label: dateLabel!),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small reusable widgets
// ─────────────────────────────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: color.withOpacity(0.25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 11, color: color),
              const SizedBox(width: 3),
              Text(label,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: color)),
            ],
          ),
        ),
      );
}

// All chips in Reviews — including the "students taken" one — share the
// same indigo styling. No accent color swap.
class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final double? maxWidth;
  final bool isAccent;
  const _MetaChip({
    required this.icon,
    required this.label,
    this.maxWidth,
    this.isAccent = false,
  });

  @override
  Widget build(BuildContext context) => Container(
        constraints: maxWidth != null
            ? BoxConstraints(maxWidth: maxWidth!)
            : null,
        padding:
            const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        decoration: BoxDecoration(
          color: const Color(0xFFEEF0FA),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 10, color: const Color(0xFF3949AB)),
            const SizedBox(width: 3),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFF3949AB),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      );
}

// Fixed height used by both the Year dropdown and the static "All Subjects"
// label in the Reviews filter row, so the two boxes always match in size.
const double _kFilterBoxHeight = 42;

class _FilterDropdown extends StatelessWidget {
  final IconData icon;
  final String value;
  final List<String> items;
  final ValueChanged<String> onChanged;
  const _FilterDropdown({
    required this.icon,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Container(
        height: _kFilterBoxHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFD0D5E8)),
          borderRadius: BorderRadius.circular(8),
          color: Colors.white,
        ),
        alignment: Alignment.centerLeft,
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            isExpanded: true,
            isDense: true,
            value: value,
            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                size: 16, color: Color(0xFF3949AB)),
            style: const TextStyle(
                fontSize: 12,
                color: Color(0xFF1A237E),
                fontWeight: FontWeight.w600),
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
            items: items
                .map((item) => DropdownMenuItem(
                      value: item,
                      child: Row(children: [
                        Icon(icon,
                            size: 13,
                            color: const Color(0xFF3949AB)),
                        const SizedBox(width: 6),
                        Flexible(
                            child: Text(item,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    const TextStyle(fontSize: 12))),
                      ]),
                    ))
                .toList(),
          ),
        ),
      );
}

// A box that mirrors _FilterDropdown's exact size and styling but isn't
// a real filter — tapping it opens a read-only list (see onTap), and the
// label itself never changes since there's nothing to "select" here.
class _StaticFilterLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _StaticFilterLabel({
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final box = Container(
      height: _kFilterBoxHeight,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFD0D5E8)),
        borderRadius: BorderRadius.circular(8),
        color: const Color(0xFFF5F6FA),
      ),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Icon(icon, size: 13, color: const Color(0xFF3949AB)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF3949AB),
              ),
            ),
          ),
          if (onTap != null)
            const Icon(Icons.visibility_outlined,
                size: 14, color: Color(0xFF3949AB)),
        ],
      ),
    );

    if (onTap == null) return box;
    return GestureDetector(onTap: onTap, child: box);
  }
}

// A plain, non-interactive row used inside the read-only subject viewer.
// No onTap, no selection state, no check icon — it's for viewing only.
class _SubjectViewRow extends StatelessWidget {
  final String label;
  final String code;
  const _SubjectViewRow({required this.label, required this.code});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(children: [
          Container(
            width: 72,
            padding:
                const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFFE8EAF6),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(code,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF3949AB))),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: const TextStyle(fontSize: 13, color: Colors.black87)),
          ),
        ]),
      );
}