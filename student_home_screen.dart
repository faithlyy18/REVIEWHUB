import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../login_screen.dart';
import 'take_quiz_screen.dart';
import 'modules_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
// BS Criminology Curriculum Data
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
// ─────────────────────────────────────────────────────────────────────────────
// Background painter — same floating text as login & teacher screens
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
// NOTE: the old "already taken" purple palette (_purpleDark / _purpleMid /
// _purpleLight / _purpleBorder) has been removed. Completed-review cards
// now reuse the same neutral/white styling as not-yet-taken cards — only
// the status bar at the bottom of the card still carries color (orange for
// pending approval, green for an approved retake, deep-orange for
// "request permission", navy for take/retake).
// ─────────────────────────────────────────────────────────────────────────────

// A soft neutral tint used for the "already taken" icon badge and chips so
// completed reviews are still visually distinguishable from fresh ones,
// without reintroducing a colored card background/border.
const _neutralIconBg   = Color(0xFFE8EAF6);
const _neutralIconFg   = Color(0xFF1A237E);
const _neutralChipBg   = Color(0xFFEEF0FA);
const _neutralChipFg   = Color(0xFF3949AB);

// ─────────────────────────────────────────────────────────────────────────────
// Retake policy: students get this many free attempts (1 take + 1 retake)
// before they need instructor approval (via `retake_requests`) to try again.
// ─────────────────────────────────────────────────────────────────────────────

const int kMaxFreeAttempts = 2;

// ─────────────────────────────────────────────────────────────────────────────
// StudentHomeScreen
// ─────────────────────────────────────────────────────────────────────────────

class StudentHomeScreen extends StatefulWidget {
  const StudentHomeScreen({super.key});

  @override
  State<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends State<StudentHomeScreen>
    with SingleTickerProviderStateMixin {
  final _user = FirebaseAuth.instance.currentUser;
  String _studentName = '';
  String _studentYearLevel = '';
  bool _profileLoaded = false;

  String _selectedYearLevel = 'All Years';
  String _selectedSubject = 'All Subjects';

  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadProfile();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    if (_user == null) return;
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(_user.uid)
        .get();
    if (mounted) {
      setState(() {
        _studentName = doc.data()?['firstName'] ?? 'Student';
        _studentYearLevel = doc.data()?['yearLevel'] ?? '';
        _profileLoaded = true;
      });
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF283593),
      body: Stack(
        children: [
          // ── Background text pattern ────────────────────────────
          Positioned.fill(
            child: CustomPaint(painter: _BackgroundPainter()),
          ),

          // ── Main content ───────────────────────────────────────
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  children: [
                    // ── Top bar ──────────────────────────────────
                    _buildTopBar(),

                    // ── Welcome banner ───────────────────────────
                    _buildWelcomeBanner(),

                    // ── Tab bar ──────────────────────────────────
                    _buildTabBar(),

                    // ── White card content ───────────────────────
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
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            _QuizzesTab(
                              profileLoaded: _profileLoaded,
                              selectedYearLevel: _selectedYearLevel,
                              selectedSubject: _selectedSubject,
                              studentUid: _user?.uid ?? '',
                              studentName: _studentName,
                              studentYearLevel: _studentYearLevel,
                              onYearLevelChanged: (v) =>
                                  setState(() => _selectedYearLevel = v),
                              onSubjectChanged: (v) =>
                                  setState(() => _selectedSubject = v),
                            ),
                            const _SubjectsTab(),
                            const StudentModulesScreen(),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
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
            'BISU Exam Reviewer',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.4,
            ),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: _logout,
            icon: const Icon(Icons.logout_rounded,
                color: Colors.white70, size: 16),
            label: const Text('Logout',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
            style: TextButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: Colors.white.withOpacity(0.25)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWelcomeBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
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
            child: const Icon(Icons.school_rounded,
                color: Colors.white, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _studentName.isEmpty
                      ? 'Welcome!'
                      : 'Welcome, $_studentName!',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  _studentYearLevel.isNotEmpty
                      ? '$_studentYearLevel — BS Criminology'
                      : 'BS Criminology — BISU Balilihan',
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withOpacity(0.3)),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.school_rounded, color: Colors.white70, size: 13),
                SizedBox(width: 5),
                Text('Student',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      height: 48,
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.15)),
      ),
      child: TabBar(
        controller: _tabController,
        indicator: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        indicatorPadding: EdgeInsets.zero,
        labelColor: const Color(0xFF1A237E),
        unselectedLabelColor: Colors.white70,
        labelStyle:
            const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
        unselectedLabelStyle: const TextStyle(fontSize: 12),
        dividerColor: Colors.transparent,
        padding: EdgeInsets.zero,
        labelPadding: EdgeInsets.zero,
        tabs: const [
          Tab(
            height: 40,
            icon: Icon(Icons.quiz_rounded, size: 16),
            text: 'Reviews',
          ),
          Tab(
            height: 40,
            icon: Icon(Icons.menu_book_rounded, size: 16),
            text: 'Subjects',
          ),
          Tab(
            height: 40,
            icon: Icon(Icons.folder_rounded, size: 16),
            text: 'Modules',
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Quizzes Tab
// ─────────────────────────────────────────────────────────────────────────────

class _QuizzesTab extends StatelessWidget {
  final bool profileLoaded;
  final String selectedYearLevel;
  final String selectedSubject;
  final String studentUid;
  final String studentName;
  final String studentYearLevel;
  final ValueChanged<String> onYearLevelChanged;
  final ValueChanged<String> onSubjectChanged;

  const _QuizzesTab({
    required this.profileLoaded,
    required this.selectedYearLevel,
    required this.selectedSubject,
    required this.studentUid,
    required this.studentName,
    required this.studentYearLevel,
    required this.onYearLevelChanged,
    required this.onSubjectChanged,
  });

  static const _yearLevels = [
    'All Years', '1st Year', '2nd Year', '3rd Year', '4th Year',
  ];

  Map<String, List<_Subject>> _groupedSubjectsForYear() {
    final sem1 = <_Subject>[];
    final sem2 = <_Subject>[];
    final seen = <String>{};

    void addUnique(List<_Subject> target, List<_Subject> source) {
      for (final s in source) {
        if (!seen.contains(s.description)) {
          seen.add(s.description);
          target.add(s);
        }
      }
    }

    if (selectedYearLevel == 'All Years') {
      for (final y in _curriculum) {
        addUnique(sem1, y.sem1);
        addUnique(sem2, y.sem2);
      }
    } else {
      final match = _curriculum.firstWhere(
        (y) => y.yearLabel == selectedYearLevel,
        orElse: () =>
            const _YearCurriculum(yearLabel: '', sem1: [], sem2: []),
      );
      addUnique(sem1, match.sem1);
      addUnique(sem2, match.sem2);
    }
    return {'sem1': sem1, 'sem2': sem2};
  }

  List<String> _allSubjectDescriptions() {
    final g = _groupedSubjectsForYear();
    return [
      'All Subjects',
      ...g['sem1']!.map((s) => s.description),
      ...g['sem2']!.map((s) => s.description),
    ];
  }

  Stream<QuerySnapshot> _buildQuizStream() {
    Query query = FirebaseFirestore.instance
        .collection('quizzes')
        .orderBy('createdAt', descending: true);
    if (selectedSubject != 'All Subjects') {
      query = query.where('subject', isEqualTo: selectedSubject);
    }
    return query.snapshots();
  }

  bool _matchesYearFilter(String quizYearLevel) {
    if (selectedYearLevel == 'All Years') return true;
    return quizYearLevel == selectedYearLevel ||
        quizYearLevel == 'All Years' ||
        quizYearLevel.isEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final allDescs = _allSubjectDescriptions();
    final effectiveSubject =
        allDescs.contains(selectedSubject) ? selectedSubject : 'All Subjects';

    return Column(
      children: [
        // Filter bar
        Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xFFE8EAF6))),
          ),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: _FilterDropdown<String>(
            icon: Icons.calendar_today_rounded,
            value: selectedYearLevel,
            items: _yearLevels,
            labelBuilder: (v) => v,
            onChanged: (v) {
              onYearLevelChanged(v);
              onSubjectChanged('All Subjects');
            },
          ),
        ),

        // Active filter chips
        if (selectedYearLevel != 'All Years' ||
            effectiveSubject != 'All Subjects')
          Container(
            color: const Color(0xFFF0F2F8),
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
            child: Row(
              children: [
                const Text('Filtering: ',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
                if (selectedYearLevel != 'All Years')
                  _ActiveChip(
                    label: selectedYearLevel,
                    onRemove: () {
                      onYearLevelChanged('All Years');
                      onSubjectChanged('All Subjects');
                    },
                  ),
                if (effectiveSubject != 'All Subjects')
                  Flexible(
                    child: _ActiveChip(
                      label: effectiveSubject,
                      onRemove: () => onSubjectChanged('All Subjects'),
                    ),
                  ),
              ],
            ),
          ),

        // Quiz list
        Expanded(
          child: !profileLoaded
              ? const Center(
                  child: CircularProgressIndicator(color: Color(0xFF1A237E)))
              : StreamBuilder<QuerySnapshot>(
                  stream: _buildQuizStream(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(
                          child: CircularProgressIndicator(
                              color: Color(0xFF1A237E)));
                    }

                    final allDocs = snapshot.data?.docs ?? [];
                    final quizzes = allDocs.where((doc) {
                      final quiz = doc.data() as Map<String, dynamic>;
                      final isArchived = quiz['archived'] as bool? ?? false;
                       if (isArchived) return false;  
                      final quizYear = quiz['yearLevel'] as String? ?? '';
                      return _matchesYearFilter(quizYear);
                    }).toList();

                    if (quizzes.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.inbox_outlined,
                                size: 64, color: Colors.grey[300]),
                            const SizedBox(height: 12),
                            Text('No reviews found.',
                                style: TextStyle(
                                    color: Colors.grey[500], fontSize: 16)),
                            const SizedBox(height: 4),
                            Text('Try changing your filters.',
                                style: TextStyle(
                                    color: Colors.grey[400], fontSize: 13)),
                          ],
                        ),
                      );
                    }

                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
                      itemCount: quizzes.length,
                      itemBuilder: (context, index) {
                        final quiz =
                            quizzes[index].data() as Map<String, dynamic>;
                        final quizId = quizzes[index].id;
                        final questionCount =
                            (quiz['questions'] as List?)?.length ?? 0;
                        final yearLevel = quiz['yearLevel'] ?? 'All Years';
                        final subject = quiz['subject'] as String? ?? '';

                        return _QuizCard(
                          quizId: quizId,
                          title: quiz['title'] ?? 'Untitled Review',
                          questionCount: questionCount,
                          yearLevel: yearLevel,
                          subject: subject,
                          timeLimitMinutes: (quiz['timeLimitMinutes'] as num?)?.toInt(),
                          teacherUid: quiz['createdBy'] as String? ?? '',
                          studentUid: studentUid,
                          studentName: studentName,
                          studentYearLevel: studentYearLevel,
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
// Subjects Tab
// ─────────────────────────────────────────────────────────────────────────────

class _SubjectsTab extends StatefulWidget {
  const _SubjectsTab();

  @override
  State<_SubjectsTab> createState() => _SubjectsTabState();
}

class _SubjectsTabState extends State<_SubjectsTab> {
  int? _expandedYear;

  static const _yearColors = [
    Color(0xFF1A237E),
    Color(0xFF00695C),
    Color(0xFF4A148C),
    Color(0xFFBF360C),
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'BS Criminology Curriculum',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15,
              color: Color(0xFF1A237E),
            ),
          ),
        ),
        for (int i = 0; i < _curriculum.length; i++)
          _YearCard(
            yearCurriculum: _curriculum[i],
            color: _yearColors[i],
            isExpanded: _expandedYear == i,
            onToggle: () => setState(
                () => _expandedYear = _expandedYear == i ? null : i),
          ),
      ],
    );
  }
}

class _YearCard extends StatelessWidget {
  final _YearCurriculum yearCurriculum;
  final Color color;
  final bool isExpanded;
  final VoidCallback onToggle;

  const _YearCard({
    required this.yearCurriculum,
    required this.color,
    required this.isExpanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final totalSubjects =
        yearCurriculum.sem1.length + yearCurriculum.sem2.length;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: color),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.school_rounded,
                        color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(yearCurriculum.yearLabel,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 15)),
                        Text('$totalSubjects subjects across 2 semesters',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
                  Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: Colors.white,
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded) ...[
            _SemesterSection(
              label: '1st Semester',
              subjects: yearCurriculum.sem1,
              color: color,
            ),
            Divider(height: 1, color: Colors.grey.shade200),
            _SemesterSection(
              label: '2nd Semester',
              subjects: yearCurriculum.sem2,
              color: color,
            ),
          ],
        ],
      ),
    );
  }
}

class _SemesterSection extends StatelessWidget {
  final String label;
  final List<_Subject> subjects;
  final Color color;

  const _SemesterSection({
    required this.label,
    required this.subjects,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Row(
            children: [
              Icon(Icons.calendar_view_month_rounded, size: 14, color: color),
              const SizedBox(width: 6),
              Text(label,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: color)),
            ],
          ),
        ),
        for (final subject in subjects)
          _SubjectTile(
            subject: subject,
            color: color,
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}

// Plain, non-interactive display row — the curriculum tab is view-only, so
// this deliberately has no InkWell/onTap and no trailing chevron (a chevron
// would visually imply the row is tappable).
class _SubjectTile extends StatelessWidget {
  final _Subject subject;
  final Color color;

  const _SubjectTile({
    required this.subject,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Row(
        children: [
          Container(
            width: 76,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color.withOpacity(0.3)),
            ),
            child: Text(subject.code,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: color)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(subject.description,
                style: const TextStyle(fontSize: 13, color: Colors.black87)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Filter Dropdown
// ─────────────────────────────────────────────────────────────────────────────

class _FilterDropdown<T> extends StatelessWidget {
  final IconData icon;
  final T value;
  final List<T> items;
  final String Function(T) labelBuilder;
  final ValueChanged<T> onChanged;

  const _FilterDropdown({
    required this.icon,
    required this.value,
    required this.items,
    required this.labelBuilder,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFD0D5E8)),
        borderRadius: BorderRadius.circular(8),
        color: Colors.white,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
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
          items: items.map((item) {
            return DropdownMenuItem<T>(
              value: item,
              child: Row(
                children: [
                  Icon(icon, size: 13, color: const Color(0xFF3949AB)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(labelBuilder(item),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Active Filter Chip
// ─────────────────────────────────────────────────────────────────────────────

class _ActiveChip extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;
  const _ActiveChip({required this.label, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFF1A237E),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              label.length > 20 ? '${label.substring(0, 19)}…' : label,
              style: const TextStyle(
                  fontSize: 11,
                  color: Colors.white,
                  fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onRemove,
            child: const Icon(Icons.close_rounded,
                size: 12, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Quiz Card
// ─────────────────────────────────────────────────────────────────────────────

// The four button states a card can be in, derived from _attemptCount and
// the status of any retake_requests doc for this quiz+student.
enum _RetakeAction { take, retake, retakeApproved, requestPermission, pending }

class _QuizCard extends StatefulWidget {
  final String quizId;
  final String title;
  final int questionCount;
  final String yearLevel;
  final String subject;
  final int? timeLimitMinutes; 
  final String teacherUid;
  final String studentUid;
  final String studentName;
  final String studentYearLevel;

  const _QuizCard({
    required this.quizId,
    required this.title,
    required this.questionCount,
    required this.yearLevel,
    required this.subject,
     this.timeLimitMinutes, 
    required this.teacherUid,
    required this.studentUid,
    required this.studentName,
    required this.studentYearLevel,
  });

  @override
  State<_QuizCard> createState() => _QuizCardState();
}

class _QuizCardState extends State<_QuizCard> {
  bool _alreadyTaken = false;
  int? _prevScore;
  int? _prevTotal;
  int _attemptCount = 0;
  // null / 'pending' / 'approved' / 'denied' / 'used'
  String? _requestStatus;
  bool _statusLoading = true;

  // Instructor who created this review — looked up once from `users` via
  // the quiz's `createdBy` uid. Null while loading or if it's unavailable
  // (e.g. an older quiz saved before `createdBy` existed), in which case
  // the chip is simply omitted rather than showing a wrong/blank name.
  String? _teacherName;

  @override
  void initState() {
    super.initState();
    _checkIfTaken();
    _loadTeacherName();
  }

  Future<void> _loadTeacherName() async {
    if (widget.teacherUid.isEmpty) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.teacherUid)
          .get();
      final data = doc.data();
      if (data == null) return;
      final first = (data['firstName'] as String? ?? '').trim();
      final last = (data['lastName'] as String? ?? '').trim();
      final fullName = [first, last].where((s) => s.isNotEmpty).join(' ');
      if (mounted && fullName.isNotEmpty) {
        setState(() => _teacherName = fullName);
      }
    } catch (_) {
      // Silently skip — a missing/unreadable instructor name shouldn't
      // block the rest of the card from displaying.
    }
  }

  // Looks at every past submission for this quiz+student (not just one) so
  // we know the real attempt count, and — once the free-attempt limit is
  // hit — checks whether the instructor has approved (or is reviewing) a
  // retake request.
  Future<void> _checkIfTaken() async {
    final result = await FirebaseFirestore.instance
        .collection('quiz_results')
        .where('quizId', isEqualTo: widget.quizId)
        .where('studentUid', isEqualTo: widget.studentUid)
        .get();

    int? latestScore;
    int? latestTotal;
    if (result.docs.isNotEmpty) {
      final sorted = result.docs.toList()
        ..sort((a, b) {
          final at = a.data()['submittedAt'] as Timestamp?;
          final bt = b.data()['submittedAt'] as Timestamp?;
          if (at == null || bt == null) return 0;
          return bt.compareTo(at); // most recent first
        });
      final latest = sorted.first.data();
      latestScore = latest['score'] as int?;
      latestTotal = latest['totalQuestions'] as int?;
    }

    String? status;
    if (result.docs.length >= kMaxFreeAttempts) {
      final reqDoc = await FirebaseFirestore.instance
          .collection('retake_requests')
          .doc('${widget.quizId}_${widget.studentUid}')
          .get();
      status = reqDoc.data()?['status'] as String?;
    }

    if (mounted) {
      setState(() {
        _attemptCount = result.docs.length;
        _alreadyTaken = result.docs.isNotEmpty;
        _prevScore = latestScore;
        _prevTotal = latestTotal;
        _requestStatus = status;
        _statusLoading = false;
      });
    }
  }

  _RetakeAction get _action {
    if (_attemptCount < kMaxFreeAttempts) {
      return _attemptCount == 0 ? _RetakeAction.take : _RetakeAction.retake;
    }
    if (_requestStatus == 'approved') return _RetakeAction.retakeApproved;
    if (_requestStatus == 'pending') return _RetakeAction.pending;
    // covers null, 'denied', and 'used' (a previously-approved retake that
    // has already been consumed)
    return _RetakeAction.requestPermission;
  }

  Future<void> _openQuiz(BuildContext context) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TakeQuizScreen(
          quizId: widget.quizId,
          studentUid: widget.studentUid,
          studentName: widget.studentName,
          studentYearLevel: widget.studentYearLevel,
          timeLimitMinutes: widget.timeLimitMinutes, 
        ),
      ),
    );
    _checkIfTaken();
  }

  void _handleButtonTap(BuildContext context) {
    switch (_action) {
      case _RetakeAction.take:
      case _RetakeAction.retake:
      case _RetakeAction.retakeApproved:
        _openQuiz(context);
        break;
      case _RetakeAction.pending:
        _showPendingInfo(context);
        break;
      case _RetakeAction.requestPermission:
        _confirmSendRequest(context);
        break;
    }
  }

  Future<void> _confirmSendRequest(BuildContext context) async {
    final wasDenied = _requestStatus == 'denied';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Request Permission to Retake',
            style: TextStyle(
                color: Color(0xFF1A237E), fontWeight: FontWeight.bold)),
        content: Text(
          wasDenied
              ? 'Your previous request for "${widget.title}" was declined. '
                  'Send a new request to your instructor?'
              : 'You\'ve used both attempts for "${widget.title}". Send a '
                  'request to your instructor for permission to take it again?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child:
                  const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A237E),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8))),
            child: const Text('Send Request'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      // One request doc per quiz+student — a new request simply overwrites
      // the previous (denied/used) one and resets it to 'pending'.
      await FirebaseFirestore.instance
          .collection('retake_requests')
          .doc('${widget.quizId}_${widget.studentUid}')
          .set({
        'quizId': widget.quizId,
        'quizTitle': widget.title,
        'subject': widget.subject,
        'yearLevel': widget.yearLevel,
        'studentUid': widget.studentUid,
        'studentName': widget.studentName,
        'studentYearLevel': widget.studentYearLevel,
        'attemptCount': _attemptCount,
        'status': 'pending',
        'requestedAt': FieldValue.serverTimestamp(),
        'respondedAt': null,
      });
      if (mounted) {
        setState(() => _requestStatus = 'pending');
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Request sent! Your instructor will review it.'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      // IMPORTANT: this used to show only a generic "Please try again"
      // message, which hides the real cause (most commonly a Firestore
      // security-rules permission-denied error on the retake_requests
      // collection). Surfacing `e` here — and printing it to the debug
      // console — makes that failure mode visible instead of silent.
      debugPrint('retake_requests write failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not send request: $e'),
          backgroundColor: Colors.red.shade700,
        ));
      }
    }
  }

  void _showPendingInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Request Pending',
            style: TextStyle(
                color: Color(0xFF1A237E), fontWeight: FontWeight.bold)),
        content: Text(
          'Your request to retake "${widget.title}" is waiting for your '
          'instructor\'s approval. You\'ll be able to retake it as soon as '
          'they approve.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ── Card body: always white/neutral now, regardless of _alreadyTaken.
    // Completion state is still conveyed (icon swaps to a checkmark, and an
    // attempt/score chip appears), but no colored background or border —
    // only the status bar at the bottom of the card (built below, driven by
    // `_action`) carries color, per the requested design.
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE8EAF6)),
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
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: _neutralIconBg,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    _alreadyTaken
                        ? Icons.done_all_rounded
                        : Icons.quiz_rounded,
                    color: _neutralIconFg,
                    size: 21,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                          color: Color(0xFF1A237E),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 6,
                        runSpacing: 3,
                        children: [
                          _chip(Icons.help_outline_rounded,
                              '${widget.questionCount} questions'),
                          _chip(Icons.school_rounded, widget.yearLevel),
                          if (widget.subject.isNotEmpty)
                            _chip(Icons.menu_book_rounded, widget.subject),
                          if (_attemptCount > 0)
                            _chip(Icons.repeat_rounded,
                                'Attempt $_attemptCount/$kMaxFreeAttempts'),
                          if (_alreadyTaken && _prevScore != null)
                            _scoreChip(),
                          if (_teacherName != null)
                            _chip(Icons.person_rounded, _teacherName!),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Take / Retake / Request-permission status bar — driven by
          // _action, which folds in the 2-attempt limit and any
          // retake_requests status for this quiz+student. This is the only
          // part of the card that carries color.
          Builder(builder: (context) {
            late final Color bg;
            late final IconData icon;
            late final String label;

            switch (_action) {
              case _RetakeAction.take:
                bg = const Color(0xFF1A237E);
                icon = Icons.play_arrow_rounded;
                label = 'Take Review';
                break;
              case _RetakeAction.retake:
                bg = const Color(0xFF1A237E);
                icon = Icons.refresh_rounded;
                label = 'Retake Review';
                break;
              case _RetakeAction.retakeApproved:
                bg = Colors.green.shade700;
                icon = Icons.verified_rounded;
                label = 'Retake Review (Approved)';
                break;
              case _RetakeAction.pending:
                bg = Colors.orange.shade800;
                icon = Icons.hourglass_top_rounded;
                label = 'Pending Instructor Approval';
                break;
              case _RetakeAction.requestPermission:
                bg = Colors.deepOrange.shade600;
                icon = _requestStatus == 'denied'
                    ? Icons.mark_email_unread_rounded
                    : Icons.lock_clock_rounded;
                // FIX: previously read 'Request Denied — Try Again'.
                // Now just shows 'Request Denied' when the request was
                // declined by the instructor.
                label = _requestStatus == 'denied'
                    ? 'Request Denied'
                    : 'Request Permission to Retake';
                break;
            }

            return InkWell(
              onTap: _statusLoading ? null : () => _handleButtonTap(context),
              borderRadius:
                  const BorderRadius.vertical(bottom: Radius.circular(14)),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(14)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, color: Colors.white, size: 16),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: _neutralChipBg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: _neutralChipFg),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  fontSize: 11,
                  color: _neutralChipFg,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _scoreChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: _neutralChipBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFD0D5E8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.emoji_events_rounded,
              size: 11, color: _neutralChipFg),
          const SizedBox(width: 4),
          Text('Score: $_prevScore/$_prevTotal',
              style: const TextStyle(
                  fontSize: 11,
                  color: _neutralChipFg,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}