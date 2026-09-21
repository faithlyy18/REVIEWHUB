import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'login_screen.dart';
import 'teacher_home_screen.dart';
import 'student_home_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _redirect();
    });
  }

  Future<void> _redirect() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      _goTo(const LoginScreen());
      return;
    }

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (!mounted) return;

      if (!doc.exists) {
        await FirebaseAuth.instance.signOut();
        _goTo(const LoginScreen());
        return;
      }

      final role = doc.data()?['role'] ?? 'student';

      // Both instructors and admins share role: 'teacher' and land on
      // TeacherHomeScreen — that screen internally checks accountType
      // and shows an extra "Overview" tab for admin accounts. There's
      // no separate AdminScreen route anymore.
      if (role == 'teacher') {
        _goTo(const TeacherHomeScreen());
      } else {
        _goTo(const StudentHomeScreen());
      }
    } catch (e) {
      await FirebaseAuth.instance.signOut();
      _goTo(const LoginScreen());
    }
  }

  void _goTo(Widget screen) {
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFFF0F2F8),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.menu_book_rounded,
              size: 64,
              color: Color(0xFF1A237E),
            ),
            SizedBox(height: 24),
            CircularProgressIndicator(color: Color(0xFF1A237E)),
            SizedBox(height: 16),
            Text(
              'Loading your account...',
              style: TextStyle(
                color: Color(0xFF757575),
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}