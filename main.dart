import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'welcome_screen.dart';

void main() async {
 
  WidgetsFlutterBinding.ensureInitialized();

  
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(const BisuExamReviewerApp());
}

class BisuExamReviewerApp extends StatelessWidget {    
  
  const BisuExamReviewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BISU Exam Reviewer',
      debugShowCheckedModeBanner: false,

      // ── Theme ──────────────────────────────────────────────────────────────
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1A237E),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF0F2F8),

        // AppBar
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1A237E),
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),

        // Cards
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),

        // Elevated buttons
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1A237E),
            foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),

        // Outlined buttons
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF1A237E),
            side: const BorderSide(color: Color(0xFF1A237E)),
            minimumSize: const Size(double.infinity, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            textStyle: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),

        // Input fields
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFBDBDBD)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Color(0xFFBDBDBD)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:
                const BorderSide(color: Color(0xFF1A237E), width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Colors.red),
          ),
          labelStyle: const TextStyle(color: Color(0xFF757575)),
          prefixIconColor: const Color(0xFF1A237E),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),

        // Checkbox
        checkboxTheme: CheckboxThemeData(
          fillColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return const Color(0xFF1A237E);
            }
            return null;
          }),
        ),

        // FloatingActionButton
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Color(0xFF1A237E),
          foregroundColor: Colors.white,
        ),
      ),

      // ── Entry point ────────────────────────────────────────────────────────
      home: const WelcomeScreen(),
    );
  }
}