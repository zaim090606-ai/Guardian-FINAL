import 'package:easy_help/screens/home.dart';
import 'package:easy_help/screens/sensor.dart';
import 'package:easy_help/services/voice_service.dart';
import 'package:flutter/material.dart';

class MainBottomNavBar extends StatefulWidget {
  const MainBottomNavBar({super.key});

  @override
  State<MainBottomNavBar> createState() => _MainBottomNavBarState();
}

class _MainBottomNavBarState extends State<MainBottomNavBar> {
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    // Start background speech monitoring when the main app UI initializes
    VoiceService.startListening();
  }

  final List<Widget> _screenList = const [
    Home(),
    SensorScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screenList,
      ),
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: Colors.white,
        elevation: 8,
        selectedItemColor: Colors.black,
        unselectedItemColor: Colors.grey.shade500,
        currentIndex: _currentIndex,
        onTap: (int index) {
          setState(() {
            _currentIndex = index;
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_rounded),
            label: "Home",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.sensors_rounded),
            label: "Sensor",
          ),
        ],
      ),
    );
  }
}