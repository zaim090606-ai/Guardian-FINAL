import 'package:easy_help/screens/home.dart';
import 'package:easy_help/screens/sensor.dart';
import 'package:flutter/material.dart';

// Class names should use UpperCamelCase
class MainBottomNavBar extends StatefulWidget {
  // The constructor name must match the class name
  const MainBottomNavBar({super.key});
   
  @override
  State<MainBottomNavBar> createState() => _MainBottomNavBarState();
}

class _MainBottomNavBarState extends State<MainBottomNavBar> {
  // Good practice to make state variables private using an underscore
  int _currentIndex = 0;
  
  // Define the type of the list for better safety
  final List<Widget> _screenList = const [
    Home(),
    Sensor(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // appBar: AppBar(
      //   title: const Text("Easy Help"),
      // ),
      body: _screenList[_currentIndex],
      bottomNavigationBar: BottomNavigationBar(
        selectedItemColor: Colors.green,
        unselectedItemColor: Colors.black
        ,
        currentIndex: _currentIndex,
        // FIX: The parameter name must match what you use inside setState
        onTap: (int index) { 
          setState(() {
            _currentIndex = index; 
          });
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home), 
            label: "Home",
          ), // FIX: Added the missing comma here
          BottomNavigationBarItem(
            icon: Icon(Icons.sensors), 
            label: "Sensor",
          ),
        ],
      ),
    );
  }
}