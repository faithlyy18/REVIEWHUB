import 'package:cloud_firestore/cloud_firestore.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Subject model
// ─────────────────────────────────────────────────────────────────────────────
//
// Firestore collection: 'subjects'
// Each document = one subject, with fields:
//   code        (e.g. 'CRIM 1')
//   description (e.g. 'Introduction to Criminology')
//   yearLevel   (e.g. '1st Year')
//   semester    ('1st Semester' | '2nd Semester')
//   order       (int, used to keep subjects in a stable, predictable order
//                within their year/semester — same order as your old
//                hardcoded list)
// ─────────────────────────────────────────────────────────────────────────────

class Subject {
  final String id; // Firestore document id
  final String code;
  final String description;
  final String yearLevel;
  final String semester;
  final int order;

  const Subject({
    required this.id,
    required this.code,
    required this.description,
    required this.yearLevel,
    required this.semester,
    this.order = 0,
  });

  factory Subject.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    return Subject(
      id: doc.id,
      code: (data['code'] as String?) ?? '',
      description: (data['description'] as String?) ?? '',
      yearLevel: (data['yearLevel'] as String?) ?? '',
      semester: (data['semester'] as String?) ?? '',
      order: (data['order'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'code': code,
        'description': description,
        'yearLevel': yearLevel,
        'semester': semester,
        'order': order,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// CurriculumRepo
// ─────────────────────────────────────────────────────────────────────────────
//
// Single shared access point for reading/writing subjects. Both the admin's
// Manage Subjects screen and every subject picker/viewer in the app should
// go through this class, so everyone always sees the same live data.
// ─────────────────────────────────────────────────────────────────────────────

class CurriculumRepo {
  static final CollectionReference<Map<String, dynamic>> _col =
      FirebaseFirestore.instance.collection('subjects');

  static const List<String> yearLevels = [
    '1st Year',
    '2nd Year',
    '3rd Year',
    '4th Year',
  ];

  static const List<String> semesters = [
    '1st Semester',
    '2nd Semester',
  ];

  // ── Live streams ─────────────────────────────────────────────────────────

  /// All subjects, ordered by year, semester, then their manual order.
  static Stream<List<Subject>> streamAll() {
    return _col
        .orderBy('yearLevel')
        .orderBy('semester')
        .orderBy('order')
        .snapshots()
        .map((snap) => snap.docs.map(Subject.fromDoc).toList());
  }

  /// Subjects for one year level only (both semesters), still live.
  static Stream<List<Subject>> streamForYear(String yearLevel) {
    return _col
        .where('yearLevel', isEqualTo: yearLevel)
        .orderBy('semester')
        .orderBy('order')
        .snapshots()
        .map((snap) => snap.docs.map(Subject.fromDoc).toList());
  }

  // ── Writes (admin only — enforce in the UI layer / Firestore rules) ───────

  static Future<void> addSubject({
    required String code,
    required String description,
    required String yearLevel,
    required String semester,
  }) async {
    // Put new subjects at the end of their year/semester group.
    final existing = await _col
        .where('yearLevel', isEqualTo: yearLevel)
        .where('semester', isEqualTo: semester)
        .get();
    final nextOrder = existing.docs.length;

    await _col.add({
      'code': code.trim(),
      'description': description.trim(),
      'yearLevel': yearLevel,
      'semester': semester,
      'order': nextOrder,
    });
  }

  static Future<void> deleteSubject(String id) async {
    await _col.doc(id).delete();
  }

  static Future<void> updateSubject(Subject subject) async {
    await _col.doc(subject.id).update(subject.toMap());
  }

  // ── One-time migration ─────────────────────────────────────────────────────
  //
  // Copies the original hardcoded curriculum into Firestore, but ONLY if the
  // 'subjects' collection is still empty. Safe to call every time the admin
  // opens the Manage Subjects screen — after the first successful run it
  // becomes a no-op forever, so nothing already added/deleted by the admin
  // is ever touched or duplicated.
  // ─────────────────────────────────────────────────────────────────────────

  static Future<void> migrateIfEmpty() async {
    final snap = await _col.limit(1).get();
    if (snap.docs.isNotEmpty) return; // already migrated (or admin has data)

    final batch = FirebaseFirestore.instance.batch();
    for (final year in _seedCurriculum) {
      int order = 0;
      for (final s in year.sem1) {
        final doc = _col.doc();
        batch.set(doc, {
          'code': s.code,
          'description': s.description,
          'yearLevel': year.yearLabel,
          'semester': '1st Semester',
          'order': order++,
        });
      }
      order = 0;
      for (final s in year.sem2) {
        final doc = _col.doc();
        batch.set(doc, {
          'code': s.code,
          'description': s.description,
          'yearLevel': year.yearLabel,
          'semester': '2nd Semester',
          'order': order++,
        });
      }
    }
    await batch.commit();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Seed data — the ORIGINAL hardcoded curriculum, used once by
// migrateIfEmpty() to populate Firestore the first time. This is not used
// anywhere else in the app after migration.
// ─────────────────────────────────────────────────────────────────────────────

class _SeedSubject {
  final String code;
  final String description;
  const _SeedSubject(this.code, this.description);
}

class _SeedYear {
  final String yearLabel;
  final List<_SeedSubject> sem1;
  final List<_SeedSubject> sem2;
  const _SeedYear({
    required this.yearLabel,
    required this.sem1,
    required this.sem2,
  });
}

const List<_SeedYear> _seedCurriculum = [
  _SeedYear(
    yearLabel: '1st Year',
    sem1: [
      _SeedSubject('CRIM 1', 'Introduction to Criminology'),
    ],
    sem2: [
      _SeedSubject('CLJ 1', 'Introduction to Phil. Criminal Justice System'),
      _SeedSubject('LEA 1', 'Law Enforcement Organization and Administration'),
    ],
  ),
  _SeedYear(
    yearLabel: '2nd Year',
    sem1: [
      _SeedSubject('CA 1', 'Institutional Corrections'),
      _SeedSubject('CDI 1', 'Fundamentals of Investigation and Intelligence'),
      _SeedSubject('CLJ 2', 'Human Rights Education'),
      _SeedSubject('CRIM 2', 'Theories of Crime Causation'),
      _SeedSubject('LEA 2', 'Comparative Models in Policing'),
    ],
    sem2: [
      _SeedSubject('CDI 2', 'Specialized Crime Investigation 1 with Legal Medicine'),
      _SeedSubject('CFLM 1', 'Character Formation, Nationalism and Patriotism'),
      _SeedSubject('CLJ 3', 'Criminal Law (Book 1)'),
      _SeedSubject('CRIM 3', 'Human Behavior and Victimology'),
      _SeedSubject('FORENSIC 1', 'Forensic Photography'),
      _SeedSubject('FORENSIC 2', 'Personal Identification Techniques'),
      _SeedSubject('LEA 3', 'Introduction to Industrial Security Concepts'),
    ],
  ),
  _SeedYear(
    yearLabel: '3rd Year',
    sem1: [
      _SeedSubject('CA 2', 'Non-Institutional Corrections'),
      _SeedSubject('CDI 3',
          'Specialized Crime Investigation 2 with Simulation on Interrogation and Interview'),
      _SeedSubject('CDI 4',
          'Traffic Management and Accident Investigation with Driving'),
      _SeedSubject(
          'CDI 5', 'Technical English 1 (Technical Report Writing and Presentation)'),
      _SeedSubject('CFLM 2',
          'Character Formation with Leadership, Decision Making, Management and Administration'),
      _SeedSubject('CLJ 4', 'Criminal Law (Book 2)'),
      _SeedSubject('FORENSIC 3', 'Forensic Chemistry and Toxicology'),
      _SeedSubject('FORENSIC 4', 'Questioned Documents Examination'),
      _SeedSubject(
          'LEA 4', 'Law Enforcement Operations and Planning with Crime Mapping'),
    ],
    sem2: [
      _SeedSubject('CA 3', 'Therapeutic Modalities'),
      _SeedSubject('CDI 6', 'Fire Protection and Arson Investigation'),
      _SeedSubject('CDI 7', 'Vice and Drug Education and Control'),
      _SeedSubject('CLJ 5', 'Evidence'),
      _SeedSubject('CRIM 4', 'Professional Conduct and Ethical Standards'),
      _SeedSubject('CRIM 5', 'Juvenile Delinquency and Juvenile Justice System'),
      _SeedSubject('CRIM 6', 'Dispute Resolution and Crises/Incidents Management'),
      _SeedSubject('CRIM 7',
          'Criminological Research 1 (Research Methods with Applied Statistics)'),
      _SeedSubject('FORENSIC 5', 'Lie Detection Techniques'),
      _SeedSubject('FORENSIC 6', 'Forensic Ballistics'),
    ],
  ),
  _SeedYear(
    yearLabel: '4th Year',
    sem1: [
      _SeedSubject('CDI 8', 'Technical English 2 (Legal Forms)'),
      _SeedSubject(
          'CDI 9', 'Introduction to Cybercrime and Environmental Laws and Protection'),
      _SeedSubject('CLJ 6', 'Criminal Procedure and Court Testimony'),
      _SeedSubject('CP 1', 'Internship (On-the-Job Training 1)'),
      _SeedSubject(
          'CRIM 8', 'Criminological Research 2 (Thesis Writing and Presentation)'),
    ],
    sem2: [
      _SeedSubject('CP 2', 'Internship (On-the-Job Training 2)'),
      _SeedSubject('ICRIM RC', 'Criminology Refresher Course'),
    ],
  ),
];