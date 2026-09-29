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
//   order       (int, keeps subjects in a stable order within their
//                year/semester)
//   archived    (bool, default false — archived subjects are hidden from
//                every picker/viewer but can be restored by an admin)
//   archivedAt  (server timestamp, only present while archived)
//
// Documents created before archiving existed have no `archived` field;
// they are treated as active.
// ─────────────────────────────────────────────────────────────────────────────

class Subject {
  final String id; // Firestore document id
  final String code;
  final String description;
  final String yearLevel;
  final String semester;
  final int order;
  final bool archived;

  const Subject({
    required this.id,
    required this.code,
    required this.description,
    required this.yearLevel,
    required this.semester,
    this.order = 0,
    this.archived = false,
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
      archived: (data['archived'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
        'code': code,
        'description': description,
        'yearLevel': yearLevel,
        'semester': semester,
        'order': order,
        'archived': archived,
      };

  /// e.g. "CRIM 1 — Introduction to Criminology"
  String get label => '$code — $description';
}

/// Thrown by [CurriculumRepo] write methods for problems the admin can fix
/// (empty fields, duplicate code). The message is safe to show in the UI.
class CurriculumException implements Exception {
  final String message;
  const CurriculumException(this.message);

  @override
  String toString() => message;
}

// ─────────────────────────────────────────────────────────────────────────────
// CurriculumRepo
// ─────────────────────────────────────────────────────────────────────────────
//
// Single shared access point for reading/writing subjects. The admin's
// Manage Curriculum screen and every subject picker/viewer in the app go
// through this class, so everyone always sees the same live data.
//
// Streams:
//   streamAll()        active subjects only (what pickers/viewers use)
//   streamForYear(y)   active subjects for one year level
//   streamArchived()   archived subjects only
//   streamEverything() active + archived (Manage Curriculum screen)
//
// Sorting is done on the device (year → semester → order → code) instead of
// with Firestore orderBy, so NO composite index is needed and older
// documents without an `archived` field still show up.
//
// Writes are admin-only. The UI hides them from instructors, and you must
// also enforce it in Firestore security rules (see the integration notes).
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

  // ── Sorting / parsing helpers ─────────────────────────────────────────────

  static int _compare(Subject a, Subject b) {
    final y = yearLevels
        .indexOf(a.yearLevel)
        .compareTo(yearLevels.indexOf(b.yearLevel));
    if (y != 0) return y;
    final s = semesters
        .indexOf(a.semester)
        .compareTo(semesters.indexOf(b.semester));
    if (s != 0) return s;
    final o = a.order.compareTo(b.order);
    if (o != 0) return o;
    return a.code.toLowerCase().compareTo(b.code.toLowerCase());
  }

  static List<Subject> _parse(QuerySnapshot<Map<String, dynamic>> snap) {
    final list = snap.docs.map(Subject.fromDoc).toList();
    list.sort(_compare);
    return list;
  }

  // ── Live streams ─────────────────────────────────────────────────────────

  /// Every ACTIVE (non-archived) subject, in curriculum order.
  static Stream<List<Subject>> streamAll() {
    return _col.snapshots().map(
        (snap) => _parse(snap).where((s) => !s.archived).toList());
  }

  /// ACTIVE subjects for one year level (both semesters), still live.
  static Stream<List<Subject>> streamForYear(String yearLevel) {
    return _col.snapshots().map((snap) => _parse(snap)
        .where((s) => !s.archived && s.yearLevel == yearLevel)
        .toList());
  }

  /// ARCHIVED subjects only.
  static Stream<List<Subject>> streamArchived() {
    return _col
        .snapshots()
        .map((snap) => _parse(snap).where((s) => s.archived).toList());
  }

  /// Active AND archived subjects (for the admin's Manage Curriculum screen).
  static Stream<List<Subject>> streamEverything() {
    return _col.snapshots().map(_parse);
  }

  // ── Writes (admin only — enforce in the UI layer AND Firestore rules) ─────

  static void _assertCodeFree(List<Subject> all, String code,
      {String? exceptId}) {
    final clash = all.where((s) =>
        s.id != exceptId && s.code.trim().toLowerCase() == code.toLowerCase());
    if (clash.isNotEmpty) {
      final inArchive = clash.first.archived;
      throw CurriculumException(
        'A subject with the code "$code" already exists'
        '${inArchive ? ' (it is in the Archived list — restore it instead)' : ''}.',
      );
    }
  }

  static int _nextOrder(
      List<Subject> all, String yearLevel, String semester) {
    var highest = -1;
    for (final s in all) {
      if (s.yearLevel == yearLevel &&
          s.semester == semester &&
          s.order > highest) {
        highest = s.order;
      }
    }
    return highest + 1;
  }

  static Future<void> addSubject({
    required String code,
    required String description,
    required String yearLevel,
    required String semester,
  }) async {
    final c = code.trim();
    final d = description.trim();
    if (c.isEmpty || d.isEmpty) {
      throw const CurriculumException(
          'Subject code and description are required.');
    }

    final all = (await _col.get()).docs.map(Subject.fromDoc).toList();
    _assertCodeFree(all, c);

    await _col.add({
      'code': c,
      'description': d,
      'yearLevel': yearLevel,
      'semester': semester,
      // New subjects go to the end of their year/semester group.
      'order': _nextOrder(all, yearLevel, semester),
      'archived': false,
    });
  }

  /// Edits a subject's details. If it moves to another year/semester it is
  /// placed at the end of that group.
  static Future<void> editSubject({
    required String id,
    required String code,
    required String description,
    required String yearLevel,
    required String semester,
  }) async {
    final c = code.trim();
    final d = description.trim();
    if (c.isEmpty || d.isEmpty) {
      throw const CurriculumException(
          'Subject code and description are required.');
    }

    final all = (await _col.get()).docs.map(Subject.fromDoc).toList();
    _assertCodeFree(all, c, exceptId: id);

    final current = all.where((s) => s.id == id);
    final moved = current.isEmpty ||
        current.first.yearLevel != yearLevel ||
        current.first.semester != semester;

    final update = <String, dynamic>{
      'code': c,
      'description': d,
      'yearLevel': yearLevel,
      'semester': semester,
    };
    if (moved) update['order'] = _nextOrder(all, yearLevel, semester);

    await _col.doc(id).update(update);
  }

  /// Hides a subject from every picker/viewer without deleting anything.
  static Future<void> archiveSubject(String id) async {
    await _col.doc(id).update({
      'archived': true,
      'archivedAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> restoreSubject(String id) async {
    await _col.doc(id).update({
      'archived': false,
      'archivedAt': FieldValue.delete(),
    });
  }

  /// Permanently removes a subject. The admin UI only offers this from the
  /// Archived list, behind a confirmation.
  static Future<void> deleteSubject(String id) async {
    await _col.doc(id).delete();
  }

  /// Kept for older callers. Overwrites every field from [subject].
  static Future<void> updateSubject(Subject subject) async {
    await _col.doc(subject.id).update(subject.toMap());
  }

  // ── One-time migration ─────────────────────────────────────────────────────
  //
  // Copies the original hardcoded curriculum into Firestore, but ONLY if the
  // 'subjects' collection is still empty. Safe to call every time the admin
  // opens Manage Curriculum — after the first successful run it becomes a
  // no-op forever, so nothing already added/archived/deleted by the admin is
  // ever touched or duplicated.
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
          'archived': false,
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
          'archived': false,
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