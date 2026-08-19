import 'package:easy_help/navbar/navbar.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const Guardianscreen());
}

class Guardianscreen extends StatelessWidget {
  const Guardianscreen({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Guardian Setup UI',
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.white,
        fontFamily: 'Roboto', 
      ),
      home: const MakeGuardianReadyScreen(),
    );
  }
}

class MakeGuardianReadyScreen extends StatelessWidget {
  const MakeGuardianReadyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Header Text
                const Text(
                  'Set up Guardian',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 32),
                
                // Main Title
                const Text(
                  'Make Guardian ready',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 16),
                
                // Description
                Text(
                  "We'll only ask for access needed for the features you enable.",
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey.shade700,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 32),

                // Permission Cards
                const PermissionCard(
                  title: 'Trusted contacts',
                  description:
                      'People Guardian can alert, call, and share your emergency location with.',
                  buttonText: 'Add trusted contact',
                ),
                const SizedBox(height: 16),
                
                const PermissionCard(
                  title: 'Location',
                  description:
                      'Used for emergency response and optional location sharing.',
                  buttonText: 'Allow location',
                ),
                const SizedBox(height: 16),
                
                const PermissionCard(
                  title: 'Notifications',
                  description: 'Used for Guardian alerts and status.',
                  buttonText: 'Enabled ✓ notifications',
                ),
                const SizedBox(height: 16),
                
                const PermissionCard(
                  title: 'Motion & sensors',
                  description: 'Used for possible-emergency detection.',
                  buttonText: 'Allow sensors',
                ),
                const SizedBox(height: 16),
                
                const PermissionCard(
                  title: 'Calls',
                  description:
                      'Used to contact trusted people during an emergency, where supported.',
                  buttonText: 'Allow calls',
                ),
                const SizedBox(height: 32),

                // Finish Button
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.push(context, MaterialPageRoute(builder: (context)=> const MainBottomNavBar()));   // Add finish action logic here
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
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.only(left: 8.0),
                        child: Text(
                          'Finish',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24), // Bottom padding
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Reusable widget for the permission items
class PermissionCard extends StatelessWidget {
  final String title;
  final String description;
  final String buttonText;

  const PermissionCard({
    super.key,
    required this.title,
    required this.description,
    required this.buttonText,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.grey.shade300,
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            description,
            style: TextStyle(
              fontSize: 15,
              color: Colors.grey.shade700,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          
          // Outline Button inside the card
          Container(
            width: double.infinity,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.grey.shade400,
                width: 1,
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () {
                  // Add permission request logic here
                },
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Text(
                      buttonText,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}