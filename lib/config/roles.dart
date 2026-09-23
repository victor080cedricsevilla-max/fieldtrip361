/// Role and account-status vocabulary shared by every client screen.
///
/// These strings are the same ones Firestore security rules and Cloud Functions
/// compare against, so they are defined once here rather than typed inline —
/// a typo in a role string is an authorization bug that no analyzer catches.
class AppRoles {
  AppRoles._();

  /// Operates the FieldTrip360 platform: subscribing schools, their admin
  /// accounts, announcements and support. Deliberately has no access to any
  /// school's students, parents, teachers, locations or documents.
  static const String superAdmin = 'super_admin';

  /// Administers one school.
  static const String admin = 'admin';

  static const String teacher = 'teacher';
  static const String student = 'student';
  static const String parent = 'parent';

  /// Someone applying for a school subscription. Holds no school access at all
  /// until a super admin approves the application and provisions a separate
  /// admin account.
  static const String applicant = 'applicant';

  /// Roles a person may choose for themselves at sign-up.
  static const List<String> selfService = [student, parent, teacher];

  /// Roles whose dashboard is the web build.
  static const List<String> web = [admin, superAdmin];

  static bool isSchoolStaff(String? role) => role == admin || role == teacher;
}

/// Values of `users.accountStatus`.
class AccountStatus {
  AccountStatus._();

  static const String active = 'active';

  /// Set by a super admin. Firebase Auth sign-in is disabled and refresh tokens
  /// are revoked at the same time, so this is not a UI-only state.
  static const String disabled = 'disabled';
}

/// Named routes used across the app.
class AppRoutes {
  AppRoutes._();

  static const String adminLogin = '/admin-login';
  static const String mobileLogin = '/mobile-login';
  static const String adminDashboard = '/admin/dashboard';
  static const String superAdminDashboard = '/super-admin/dashboard';
  static const String teacherDashboard = '/teacher/dashboard';
  static const String studentDashboard = '/student/dashboard';
  static const String parentDashboard = '/parent/dashboard';
  static const String apply = '/apply';
  static const String applicationStatus = '/apply/status';
}
