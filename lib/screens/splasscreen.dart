import 'dart:async';
import 'package:easy_help/screens/firstscreen.dart';
import 'package:flutter/material.dart';

// Import your Firstscreen here
// import 'package:easy_help/screens/first_screen.dart'; 

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  void _startTimer() {
    // Wait for 2 seconds
    Timer(const Duration(seconds: 2), () {
      // Safety check: ensure the widget is still in the tree before navigating
      if (!mounted) return;

      // Navigate to Firstscreen and remove the splash screen from the back stack
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => const Firstscreen(), // Ensure Firstscreen is imported
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white, // Match this to your brand color
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo Text
              const Text(
                'Easy Help',
                style: TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 24), // Spacing between logo and loader
              
              // Subtle Loading Indicator (Optional but recommended for UX)
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.black54,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

