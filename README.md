# 🛡️ Guardian Safety - Personal Safety & Emergency Response App

**Guardian Safety** is a comprehensive personal safety and emergency response application built with Flutter. It leverages cutting-edge technologies including AI, offline capabilities, mesh networking, and real-time emergency alerts to keep users protected in critical situations.

[![Flutter](https://img.shields.io/badge/Flutter-3.0+-blue.svg?logo=flutter)](https://flutter.dev)
[![Firebase](https://img.shields.io/badge/Firebase-Enabled-orange.svg?logo=firebase)](https://firebase.google.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-iOS%20%7C%20Android%20%7C%20Web-blueviolet.svg)](https://flutter.dev)

---

## 📱 Features

### 🚨 Emergency Response
- **One-Tap Emergency Alert**: Instantly notify emergency contacts with real-time location
- **Automated Emergency Contacts**: Pre-configured trusted contacts for rapid response
- **Location Sharing**: Share live GPS coordinates with emergency services and trusted contacts
- **Emergency Call Integration**: Direct integration with emergency services

### 📍 Location & Mapping
- **Real-Time GPS Tracking**: Continuous location tracking with high accuracy
- **Google Maps Integration**: Interactive map visualization for location-based services
- **Geofencing**: Define safe zones and receive alerts when entering/leaving boundaries
- **Offline Maps Support**: Access maps even without internet connectivity

### 🤖 AI & Smart Features
- **Gemini AI Integration**: Leverages Google's Generative AI for intelligent analysis and recommendations
- **Voice Commands**: Hands-free operation using speech-to-text technology
- **Sound Detection**: YAMNet-powered audio analysis for detecting distressing sounds (e.g., breaking glass, alarms)
- **Offline AI Models**: 
  - TFLite Flutter for on-device ML inference
  - Whisper GGML for offline speech recognition

### 📡 Connectivity & Communication
- **Mesh Networking**: Connect with nearby users via Nearby Connections for offline communication
- **Background SMS Support**: Send emergency SMS even without active internet
- **Multi-Protocol Support**: Works over WiFi, cellular, and mesh networks
- **Offline Functionality**: Core features work without internet connection

### 🔐 Security & Privacy
- **Firebase Authentication**: Secure user authentication
- **Encrypted Storage**: Sensitive data encrypted with shared preferences
- **Firebase Security Rules**: Firestore rules for data protection
- **Minimal Data Collection**: Privacy-first design approach

### 📱 Cross-Platform Support
- **iOS**: Full support for Apple devices
- **Android**: Optimized for Android 16+ (with SMS handling fixes)
- **Web**: Responsive web interface for emergency coordination
- **Desktop**: Windows, macOS, and Linux support

---

## 🛠️ Tech Stack

### Frontend & Framework
- **Flutter** (3.0+) - Cross-platform mobile framework
- **Riverpod** (2.6.1) - State management
- **Material Design** - UI/UX components

### Backend & Services
- **Firebase Core** - Backend infrastructure
- **Cloud Firestore** - Real-time database
- **Firebase Auth** - Authentication
- **Firebase Storage** - File storage
- **Firebase Cloud Messaging** - Push notifications

### Sensors & Location
- **Geolocator** (14.0.3) - GPS and location services
- **Sensors Plus** (5.0.1) - Accelerometer, gyroscope, magnetometer
- **Google Maps Flutter** (2.5.3) - Map integration

### AI & ML
- **Google Generative AI** (0.4.7) - Gemini API integration
- **TFLite Flutter** (0.11.0) - On-device TensorFlow Lite models
- **Whisper GGML Plus** (1.5.2) - Offline speech-to-text
- **Speech to Text** (7.4.0) - Voice input

### Communication & Networking
- **Background SMS** (0.0.4) - SMS sending in background
- **Nearby Connections** (4.2.1) - Mesh networking
- **Connectivity Plus** (6.0.0) - Network status monitoring
- **Fast Contacts** (6.0.0) - Contact access

### Audio & Media
- **Record** (5.0.4) - Audio recording
- **Flutter Local Notifications** (22.3.0) - Local notifications

### System & Storage
- **Shared Preferences** (2.3.2) - Local storage
- **Path Provider** (2.1.2) - File system access
- **Flutter Background Service** (5.0.0) - Background task execution
- **Permission Handler** (11.4.0) - Runtime permissions

---

## 🚀 Getting Started

### Prerequisites
- **Flutter SDK**: 3.0.0 or higher
- **Dart SDK**: Compatible with Flutter 3.0+
- **Android Studio** or **Xcode** for mobile development
- **Firebase Project**: Set up a Firebase project for authentication and database
- **Google Cloud Project**: For Gemini API access

### Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/zaim090606-ai/Guardian-FINAL.git
   cd Easy_help
   ```

2. **Get Flutter dependencies:**
   ```bash
   flutter pub get
   ```

3. **Configure Firebase:**
   - Download your `google-services.json` (Android) and `GoogleService-Info.plist` (iOS) from Firebase Console
   - Place Android config in: `android/app/google-services.json`
   - Place iOS config in: `ios/Runner/GoogleService-Info.plist`
   - Update `lib/firebase_options.dart` with your Firebase configuration

4. **Configure Gemini API:**
   - Set up your Google Cloud API key
   - Add it to your environment configuration or secure storage

5. **Install platform-specific dependencies:**

   **Android:**
   ```bash
   cd android
   ./gradlew build
   cd ..
   ```

   **iOS:**
   ```bash
   cd ios
   pod install
   cd ..
   ```

### Running the Application

**Development Mode:**
```bash
flutter run
```

**Release Build:**
```bash
flutter run --release
```

**Build APK (Android):**
```bash
flutter build apk
```

**Build iOS IPA:**
```bash
flutter build ios
```

**Build Web:**
```bash
flutter build web
```

---

## 📂 Project Structure

```
Easy_help/
├── lib/
│   ├── main.dart              # Application entry point
│   ├── firebase_options.dart  # Firebase configuration
│   ├── navbar/                # Navigation components
│   ├── screens/               # UI screens
│   └── services/              # Business logic & services
├── assets/
│   └── models/                # ML models
│       ├── yamnet.tflite      # Sound detection model
│       ├── yamnet_labels.txt  # Sound labels
│       └── ggml-tiny.bin      # Whisper speech model
├── android/                   # Android native code
├── ios/                       # iOS native code
├── web/                       # Web platform code
├── windows/                   # Windows platform code
├── macos/                     # macOS platform code
├── linux/                     # Linux platform code
├── test/                      # Unit and widget tests
└── pubspec.yaml               # Flutter dependencies
```

---

## 🔒 Security & Privacy

- **End-to-End Encryption**: Sensitive communications are encrypted
- **No Unnecessary Permissions**: Only requests permissions when needed
- **GDPR Compliant**: Respects user privacy and data rights
- **Open Source**: Code transparency for security audits
- **Regular Updates**: Security patches and vulnerability fixes

---

## 📊 Features in Detail

### Emergency Alert System
1. **Quick Emergency Button**: Large, easy-to-access emergency trigger
2. **Location Capture**: Automatically captures and shares current location
3. **Contact Notification**: Sends alert to pre-configured emergency contacts
4. **Live Tracking**: Allows continuous location sharing during emergency

### Offline Capabilities
- **Sound Detection**: Works offline using local TFLite models
- **Voice Commands**: Offline speech recognition using Whisper GGML
- **Mesh Networking**: Connect to nearby users without internet
- **Local Database**: Firestore offline persistence

### AI-Powered Safety
- **Context-Aware Recommendations**: AI provides safety recommendations based on user location and time
- **Intelligent Alert Analysis**: AI helps determine if a situation requires emergency response
- **Natural Language Processing**: Understand user voice commands

---

## 🧪 Testing

Run tests with:
```bash
flutter test
```

### Test Coverage
- Unit tests for services
- Widget tests for UI components
- Integration tests for critical flows

---

## 📝 Important Reports

- **[AUDIT_REPORT.md](./AUDIT_REPORT.md)** - Security and code audit findings
- **[REPAIR_COMPLETION_REPORT.md](./REPAIR_COMPLETION_REPORT.md)** - Bug fixes and improvements completed
- **[SMS_FIX_IMPLEMENTATION_REPORT.md](./SMS_FIX_IMPLEMENTATION_REPORT.md)** - SMS functionality fixes
- **[ANDROID_16_SMS_FIX_REPORT.md](./ANDROID_16_SMS_FIX_REPORT.md)** - Android 16+ compatibility fixes
- **[DEPLOYMENT_VERIFICATION_GUIDE.md](./DEPLOYMENT_VERIFICATION_GUIDE.md)** - Deployment checklist

---

## 🤝 Contributing

We welcome contributions from the community! To contribute:

1. **Fork the repository**
2. **Create a feature branch** (`git checkout -b feature/amazing-feature`)
3. **Commit your changes** (`git commit -m 'Add amazing feature'`)
4. **Push to the branch** (`git push origin feature/amazing-feature`)
5. **Open a Pull Request**

### Code Guidelines
- Follow Dart style guide (dartfmt)
- Write meaningful commit messages
- Add tests for new features
- Update documentation as needed

---

## 🐛 Bug Reports & Feature Requests

Found a bug? Have a feature request? Please create an issue on GitHub with:
- Clear description of the problem/feature
- Steps to reproduce (for bugs)
- Expected behavior
- Screenshots or logs (if applicable)

---

## 📞 Support

For questions or support, please:
- Open an issue on GitHub
- Check existing documentation and reports
- Review the [Flutter Documentation](https://flutter.dev/docs)
- Consult [Firebase Documentation](https://firebase.google.com/docs)

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## 👥 Authors & Contributors

- **Guardian Safety Team** - Initial development and maintenance

---

## 🔗 References & Resources

- [Flutter Official Documentation](https://flutter.dev)
- [Firebase Documentation](https://firebase.google.com/docs)
- [Google Generative AI API](https://ai.google.dev)
- [TensorFlow Lite Flutter](https://www.tensorflow.org/lite/flutter)
- [Nearby Connections Protocol](https://developers.google.com/nearby/connections)

---

## 📈 Roadmap

- [ ] Enhanced offline capabilities
- [ ] Multi-language support
- [ ] Advanced AI threat analysis
- [ ] Community safety features
- [ ] Smart home integration
- [ ] Wearable device support

---

**Stay Safe! 🛡️**
