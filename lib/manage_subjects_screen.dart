import 'package:flutter/material.dart';
import 'curriculum_repo.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ManageSubjectsScreen  (ADMIN — the ONLY place to add/remove subjects)
// ─────────────────────────────────────────────────────────────────────────────
//
// • The official BS Criminology subjects are pre-loaded, shown with a lock,
//   and can NOT be deleted.
// • The admin can add extra subjects for any year level / semester. They
//   appear live in the Create Review subject picker for that year level.
// • Admin-added subjects can be deleted (with confirmation).
//
// This screen does NOT check accountType — the caller (teacher_home_screen)
// only shows the entry point to admins. Also protect the `subjects`
// collection with Firestore rules.
// ─────────────────────────────────────────────────────────────────────────────

class ManageSubjectsScreen extends StatefulWidget {
  const ManageSubjectsScreen({super.key});

  @override
  State<ManageSubjectsScreen> createState() => _ManageSubjectsScreenState();
}

class _ManageSubjectsScreenState extends State<ManageSubjectsScreen> {
  static const Color _brand = Color(0xFF1A237E);

  bool _loading = true;
  String _filterYear = CurriculumRepo.yearLevels.first;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  // Makes sure every official BS Criminology subject exists in Firestore,
  // locked and not archived. Safe to run every time.
  Future<void> _prepare() async {
    try {
      await CurriculumRepo.ensureCoreSubjects();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not sync the curriculum: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : null,
    ));
  }

  // ── Add subject dialog ────────────────────────────────────────────────────

  Future<void> _openAddDialog() async {
    final codeController = TextEditingController();
    final descController = TextEditingController();
    String year = _filterYear;
    String semester = CurriculumRepo.semesters.first;
    final formKey = GlobalKey<FormState>();
    bool saving = false;
    String? error;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(children: [
                    Icon(Icons.add_circle_rounded, color: _brand, size: 20),
                    SizedBox(width: 8),
                    Text('Add Subject',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: _brand)),
                  ]),
                  const SizedBox(height: 6),
                  Text(
                    'It will appear in Create Review under the year level you choose.',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: year,
                    decoration: const InputDecoration(labelText: 'Year Level'),
                    items: CurriculumRepo.yearLevels
                        .map((y) => DropdownMenuItem(value: y, child: Text(y)))
                        .toList(),
                    onChanged: (v) => setDialogState(() => year = v ?? year),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: semester,
                    decoration: const InputDecoration(labelText: 'Semester'),
                    items: CurriculumRepo.semesters
                        .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (v) =>
                        setDialogState(() => semester = v ?? semester),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: codeController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: 'Subject Code',
                      hintText: 'e.g. CRIM 9',
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: descController,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Subject Title',
                      hintText: 'e.g. Introduction to Forensic Science',
                    ),
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Text(error!,
                          style: TextStyle(
                              color: Colors.red.shade700, fontSize: 12)),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(children: [
                    Expanded(
                      child: TextButton(
                        onPressed:
                            saving ? null : () => Navigator.pop(dialogContext),
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: saving
                            ? null
                            : () async {
                                if (!formKey.currentState!.validate()) return;
                                setDialogState(() {
                                  saving = true;
                                  error = null;
                                });
                                try {
                                  await CurriculumRepo.addSubject(
                                    code: codeController.text,
                                    description: descController.text,
                                    yearLevel: year,
                                    semester: semester,
                                  );
                                  if (dialogContext.mounted) {
                                    Navigator.pop(dialogContext);
                                  }
                                  // Jump to the year the subject was added to.
                                  if (mounted) {
                                    setState(() => _filterYear = year);
                                  }
                                  _snack('Subject added to $year.');
                                } on CurriculumException catch (e) {
                                  setDialogState(() {
                                    saving = false;
                                    error = e.message;
                                  });
                                } catch (e) {
                                  setDialogState(() {
                                    saving = false;
                                    error = 'Could not add subject: $e';
                                  });
                                }
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _brand,
                          foregroundColor: Colors.white,
                        ),
                        child: saving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2),
                              )
                            : const Text('Add'),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    codeController.dispose();
    descController.dispose();
  }

  // ── Delete confirmation (admin-added subjects only) ───────────────────────

  Future<void> _confirmDelete(Subject subject) async {
    if (subject.isCore) {
      _snack('Official curriculum subjects cannot be deleted.', error: true);
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Subject',
            style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
        content: Text(
          'Delete "${subject.code} — ${subject.description}"?\n\n'
          'It will disappear from the Create Review subject list right away. '
          'Existing reviews that already used this subject keep their saved '
          'subject name.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await CurriculumRepo.deleteSubject(subject.id);
        _snack('Subject deleted.');
      } on CurriculumException catch (e) {
        _snack(e.message, error: true);
      } catch (e) {
        _snack('Could not delete subject: $e', error: true);
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F8),
      appBar: AppBar(
        backgroundColor: _brand,
        foregroundColor: Colors.white,
        title: const Text('Manage Subjects',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _brand))
          : Column(
              children: [
                // Year filter tabs
                Container(
                  color: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      for (final y in CurriculumRepo.yearLevels)
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _filterYear = y),
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              padding: const EdgeInsets.symmetric(vertical: 9),
                              decoration: BoxDecoration(
                                color: _filterYear == y
                                    ? _brand
                                    : const Color(0xFFE8EAF6),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                y.replaceAll(' Year', ''),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: _filterYear == y
                                      ? Colors.white
                                      : const Color(0xFF3949AB),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1),

                // Explains the lock icon
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8EAF6),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(children: [
                    const Icon(Icons.lock_outline_rounded,
                        size: 15, color: _brand),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Locked subjects are the official BS Criminology '
                        'curriculum and cannot be removed. Tap "Add Subject" '
                        'to add more for a year level.',
                        style: TextStyle(fontSize: 11, color: Colors.grey[800]),
                      ),
                    ),
                  ]),
                ),

                // Live subject list for the selected year
                Expanded(
                  child: StreamBuilder<List<Subject>>(
                    stream: CurriculumRepo.streamForYear(_filterYear),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting &&
                          !snapshot.hasData) {
                        return const Center(
                            child: CircularProgressIndicator(color: _brand));
                      }
                      if (snapshot.hasError) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                                'Error loading subjects: ${snapshot.error}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.red)),
                          ),
                        );
                      }

                      final subjects = snapshot.data ?? [];
                      if (subjects.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.menu_book_outlined,
                                  size: 56, color: Colors.grey[300]),
                              const SizedBox(height: 12),
                              Text('No subjects for $_filterYear yet.',
                                  style: TextStyle(color: Colors.grey[500])),
                              const SizedBox(height: 4),
                              Text('Tap "Add Subject" to create one.',
                                  style: TextStyle(
                                      color: Colors.grey[400], fontSize: 12)),
                            ],
                          ),
                        );
                      }

                      final sem1 = subjects
                          .where((s) => s.semester == '1st Semester')
                          .toList();
                      final sem2 = subjects
                          .where((s) => s.semester == '2nd Semester')
                          .toList();

                      return ListView(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                        children: [
                          if (sem1.isNotEmpty) ...[
                            _semLabel('1st Semester'),
                            for (final s in sem1) _subjectTile(s),
                          ],
                          if (sem2.isNotEmpty) ...[
                            _semLabel('2nd Semester'),
                            for (final s in sem2) _subjectTile(s),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: _brand,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Subject',
            style: TextStyle(fontWeight: FontWeight.bold)),
        onPressed: _openAddDialog,
      ),
    );
  }

  Widget _semLabel(String label) => Padding(
        padding: const EdgeInsets.fromLTRB(6, 10, 6, 6),
        child: Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Color(0xFF3949AB),
                letterSpacing: 0.4)),
      );

  Widget _subjectTile(Subject s) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE8EAF6)),
        ),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          leading: Container(
            width: 60,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFE8EAF6),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              s.code,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF3949AB)),
            ),
          ),
          title: Text(s.description,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1A237E))),
          // Official subjects: lock, no delete. Admin-added: delete button.
          trailing: s.isCore
              ? const Tooltip(
                  message: 'Official BS Criminology subject — cannot be removed',
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.lock_outline_rounded,
                        size: 20, color: Colors.grey),
                  ),
                )
              : IconButton(
                  tooltip: 'Delete',
                  icon: Icon(Icons.delete_outline_rounded,
                      color: Colors.red.shade400, size: 22),
                  onPressed: () => _confirmDelete(s),
                ),
        ),
      );
}