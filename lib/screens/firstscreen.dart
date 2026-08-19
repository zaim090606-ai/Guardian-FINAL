import 'package:easy_help/screens/Guardian.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const Firstscreen());
}

class Firstscreen extends StatelessWidget {
  const Firstscreen({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Guardian UI',
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.white,
        fontFamily: 'Roboto', // Using default font, adjust if you have a specific font family
      ),
      home: const GuardianSplashScreen(),
    );
  }
}

class GuardianSplashScreen extends StatelessWidget {
  const GuardianSplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Title Text
              const Text(
                'Guardian',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 24),
              
              // Subtitle 1
              Text(
                'Your emergency-response companion.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 16),
              
              // Subtitle 2
              Text(
                'Detect. Check. Respond. Resolve.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 40),
              
              // "Set up Guardian" Button
              SizedBox(
                width: double.infinity,
                height: 56, // Fixed height for the button
                child: ElevatedButton(
                  onPressed: () {
                     Navigator.push(context, MaterialPageRoute(builder: (context)=> Guardianscreen()));                // Add your set up logic here
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF121212), // Near black
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Align(
                    alignment: Alignment.centerLeft, // Aligns text to the left like the image
                    child: Padding(
                      padding: EdgeInsets.only(left: 8.0),
                      child: Text(
                        'Set up Guardian',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              
              
              
            ],
          ),
        ),
      ),
    );
  }
}