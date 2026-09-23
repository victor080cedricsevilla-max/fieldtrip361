import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/roles.dart';
import '../utils/messaging_service.dart';
import '../utils/background_location_service.dart';
import '../utils/school_context.dart';
import '../views/admin/admin_dashboard.dart';
import '../views/teacher/teacher_dashboard.dart';
import '../views/parent/parent_dashboard.dart';
import '../views/student/student_dashboard.dart';
import '../views/superadmin/super_admin_dashboard.dart';

class AuthController {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Why the activation code supplied at sign-up was not accepted, if it wasn't.
  ///
  /// Registration deliberately still succeeds in that case, so this is reported
  /// separately from [registerUser]'s return value — which stays reserved for
  /// failures that actually prevented the account from being created.
  String? _lastActivationError;
  String? get lastActivationError => _lastActivationError;

  Future<String?> registerUser({
    required String email,
    required String password,
    required String name,
    required String role,
    String? firstName,
    String? surname,
    String? lrn,
    String? activationCode,
    String? acceptedTermsVersion,
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
        // The consent record: which wording they agreed to, and when. An older
        // version here is how you find who must accept a revised notice.
        if (acceptedTermsVersion != null) ...{
          'termsAcceptedVersion': acceptedTermsVersion,
          'termsAcceptedAt': FieldValue.serverTimestamp(),
        },
      };

      if (role == 'student' && lrn != null) {
        userData['lrn'] = lrn;
      }

      await _firestore.collection('users').doc(uid).set(userData);

      // Match this account against the roster their school uploaded. A student
      // inherits their school (and any parent link the admin declared in the
      // CSV); a parent is linked to the children listed under their email.
      // Must run before signOut below — the callable needs an authenticated user.
      if (role == 'student' || role == 'parent') {
        await claimRosterRecord(uid);
      }

      // Redeem the school-issued code that names this parent's child. It has to
      // run here, before the sign-out below, because the callable needs an
      // authenticated caller. A bad code never blocks the sign-up — the account
      // is already valid and the code can be entered again from the dashboard.
      if (role == 'parent' && (activationCode ?? '').trim().isNotEmpty) {
        _lastActivationError = null;
        try {
          await FirebaseFunctions.instance
              .httpsCallable('activateGuardianCode')
              .call(<String, dynamic>{'code': activationCode!.trim()});
        } on FirebaseFunctionsException catch (e) {
          _lastActivationError = e.message ?? 'That activation code could not be used.';
        } catch (_) {
          _lastActivationError =
              'Your account was created, but the activation code could not be checked.';
        }
      }

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
  /// Matches this account against its school's roster, recording the outcome.
  ///
  /// This used to be fire-and-forget with a swallowed error, which meant a
  /// student whose claim never landed looked exactly like one who was never on
  /// the roster. The result is now written to `rosterClaimNote` on the user
  /// document, and [loginUser] retries whenever `schoolId` is still missing — so
  /// a single failure is no longer permanent.
  Future<void> claimRosterRecord(String uid) async {
    String? note;
    try {
      final res =
          await FirebaseFunctions.instance.httpsCallable('claimRosterRecord').call();
      final data = Map<String, dynamic>.from(res.data as Map);
      if (data['claimed'] != true) {
        note = 'No roster entry matched this email (${data['reason'] ?? 'no match'}).';
      }
    } on FirebaseFunctionsException catch (e) {
      note = 'Roster link failed: ${e.code} ${e.message ?? ''}'.trim();
    } catch (e) {
      note = 'Roster link failed: $e';
    }

    // The school may have just been attached, so drop the cached lookup.
    SchoolContext.clear();

    try {
      await _firestore.collection('users').doc(uid).update({
        'rosterClaimNote': note ?? FieldValue.delete(),
      });
    } catch (_) {
      // Diagnostic only — never block sign-up or sign-in over this note.
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

      // Block unverified accounts (admin role is exempt -- checked after we read the user doc).
      await userCredential.user?.reload();
      final bool emailVerified = userCredential.user?.emailVerified ?? false;

      String uid = userCredential.user!.uid;
      DocumentSnapshot userDoc = await _firestore.collection('users').doc(uid).get();
      if (userDoc.exists) {
        final Map<String, dynamic> data = userDoc.data() as Map<String, dynamic>;
        final String role = (data['role'] ?? '').toString();

        // A suspended administrator is blocked in Firebase Auth and by the
        // security rules as well; this only turns that into a sentence they can
        // act on instead of a permission error deeper in the app.
        if ((data['accountStatus'] ?? AccountStatus.active) == AccountStatus.disabled) {
          await _auth.signOut();
          final reason = (data['disabledReason'] ?? '').toString().trim();
          return reason.isEmpty
              ? "This account has been disabled. Please contact FieldTrip360 support."
              : "This account has been disabled: $reason";
        }

        // Admin and super-admin accounts are provisioned with a verified
        // address, so the verification gate applies to self-service roles.
        if (!emailVerified && role != AppRoles.admin && role != AppRoles.superAdmin) {
          await _auth.signOut();
          return "Please verify your email before logging in. Check your inbox for the confirmation link.";
        }
      }

      if (userDoc.exists) {
        Map<String, dynamic> data = userDoc.data() as Map<String, dynamic>;
        String? role = data['role'];

        // Retry a roster claim that never landed — an app build predating the
        // claim call, or a transient failure, would otherwise leave this account
        // unlinked from its school forever.
        final existingSchool = (data['schoolId'] as String?)?.trim();
        if ((role == 'student' || role == 'parent') &&
            (existingSchool == null || existingSchool.isEmpty)) {
          await claimRosterRecord(uid);
        }

        if (role != null && context.mounted) {
          // Write a session token so other devices are displaced (one-device-per-account).
          if (!kIsWeb) {
            final sessionToken = '${uid}_${DateTime.now().millisecondsSinceEpoch}';
            unawaited(_firestore.collection('users').doc(uid).update({'activeSession': sessionToken}));
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('activeSession', sessionToken);
          }
          if (!context.mounted) return null;
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
      // The destination follows the role stored on the server. Nothing the
      // client sends can change it, which is why there is no role picker on the
      // sign-in screen.
      case AppRoles.superAdmin:
        targetScreen = const SuperAdminDashboard();
        break;
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
    if (!kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('activeSession');
    }
    await MessagingService.instance.clearTokenForCurrentUser();
    if (!kIsWeb) await BackgroundLocationService.stop();
    SchoolContext.clear(); // don't let the next user inherit this school
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