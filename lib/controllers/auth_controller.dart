import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../utils/messaging_service.dart';
import '../utils/background_location_service.dart';
import '../views/admin/admin_dashboard.dart';
import '../views/teacher/teacher_dashboard.dart';
import '../views/parent/parent_dashboard.dart';
import '../views/student/student_dashboard.dart';

class AuthController {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<String?> registerUser({
    required String email,
    required String password,
    required String name,
    required String role,
    String? firstName,
    String? surname,
    String? lrn,
  }) async {
    try {
      UserCredential userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      String uid = userCredential.user!.uid;

      Map<String, dynamic> userData = {
        'uid': uid,
        'name': name,
        if (firstName != null) 'firstName': firstName,
        if (surname != null) 'surname': surname,
        'email': email,
        'role': role,
        'status': 'approved',
        'createdAt': FieldValue.serverTimestamp(),
      };

      if (role == 'student' && lrn != null) {
        userData['lrn'] = lrn;
      }

      await _firestore.collection('users').doc(uid).set(userData);

      // Send verification email so the user must confirm the address.
      try {
        await userCredential.user?.sendEmailVerification();
      } catch (_) {
        // Non-fatal: account is created; user can resend from the verify screen.
      }

      // Sign out: forbid auto-routing to a dashboard until the email is verified.
      await _auth.signOut();

      return null;
    } on FirebaseAuthException catch (e) {
      return e.message;
    } catch (e) {
      return "System Error";
    }
  }
  Future<String?> resendVerificationEmail({
    required String email,
    required String password,
  }) async {
    try {
      final cred = await _auth.signInWithEmailAndPassword(email: email, password: password);
      await cred.user?.reload();
      if (cred.user?.emailVerified == true) {
        await _auth.signOut();
        return "Email is already verified. Please log in.";
      }
      await cred.user?.sendEmailVerification();
      await _auth.signOut();
      return null;
    } on FirebaseAuthException catch (e) {
      return e.message;
    } catch (e) {
      return "System Error";
    }
  }

  Future<String?> loginUser({
    required BuildContext context,
    required String email,
    required String password,
  }) async {
    try {
      UserCredential userCredential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      // Block unverified accounts (admin role is exempt — checked after we read the user doc).
      await userCredential.user?.reload();
      final bool emailVerified = userCredential.user?.emailVerified ?? false;

      String uid = userCredential.user!.uid;
      DocumentSnapshot userDoc = await _firestore.collection('users').doc(uid).get();
      if (userDoc.exists) {
        final Map<String, dynamic> data = userDoc.data() as Map<String, dynamic>;
        final String role = (data['role'] ?? '').toString();
        if (!emailVerified && role != 'admin') {
          await _auth.signOut();
          return "Please verify your email before logging in. Check your inbox for the confirmation link.";
        }
      }

      if (userDoc.exists) {
        Map<String, dynamic> data = userDoc.data() as Map<String, dynamic>;
        String? role = data['role'];

        if (role != null && context.mounted) {
          // Register FCM token so the user receives push notifications.
          unawaited(MessagingService.instance.init());
          // Start the background location/geofence service for roles that
          // actually move (teacher/student/parent). Admins don't need it.
          if (!kIsWeb && (role == 'teacher' || role == 'student' || role == 'parent')) {
            unawaited(BackgroundLocationService.start(uid));
          }
          _navigateToRole(role, context);
          return null;
        } else {
          await _auth.signOut();
          return "Error: No role assigned.";
        }
      } else {
        await _auth.signOut();
        return "User record not found.";
      }
    } on FirebaseAuthException catch (e) {
      return e.message;
    } catch (e) {
      return "An unexpected error occurred. Please try again.";
    }
  }

  void _navigateToRole(String role, BuildContext context) {
    Widget targetScreen;

    switch (role) {
      case 'admin':
        targetScreen = const AdminDashboard();
        break;
      case 'teacher':
        targetScreen = const TeacherDashboard();
        break;
      case 'parent':
        targetScreen = const ParentDashboard();
        break;
      case 'student':
        targetScreen = const StudentDashboard();
        break;
      default:
        return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => targetScreen),
    );
  }
  
  Future<void> logout() async {
    await MessagingService.instance.clearTokenForCurrentUser();
    if (!kIsWeb) await BackgroundLocationService.stop();
    await _auth.signOut();
  }

  /// Sends the standard Firebase password-reset email (Firebase-hosted page).
  /// Returns null on success, or a human-readable error message.
  Future<String?> sendPasswordReset(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
      return null;
    } on FirebaseAuthException catch (e) {
      return e.message;
    } catch (e) {
      return "System Error: $e";
    }
  }
}