import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';

import 'providers/obd_state.dart';
import 'screens/dashboard_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => OBDState(),
      child: const DriveSyncApp(),
    ),
  );
}

class DriveSyncApp extends StatelessWidget {
  const DriveSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SomPhot',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.light().copyWith(
        scaffoldBackgroundColor: const Color(0xFFF6F8FA),
        primaryColor: Colors.green,
        textTheme: GoogleFonts.outfitTextTheme(ThemeData.light().textTheme),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 1,
          iconTheme: const IconThemeData(color: Colors.black87),
          titleTextStyle: GoogleFonts.outfit(
            color: Colors.black87,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        cardTheme: const CardTheme(
          color: Colors.white,
          elevation: 1,
        ),
        colorScheme: const ColorScheme.light(
          primary: Colors.green,
          secondary: Colors.cyan,
          surface: Colors.white,
          error: Colors.redAccent,
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}
