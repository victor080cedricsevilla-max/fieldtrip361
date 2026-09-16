/// The Terms of Service and Privacy Notice a new account holder must read
/// before signing up.
///
/// The wording is written in plain language and describes what this app
/// actually does: roster matching, QR attendance, live trip location, guardian
/// activation codes, trip chat, SOS alerts, and the AI screening of uploaded
/// waivers and medical clearances. It is a starting draft, not legal advice —
/// have the school's Data Protection Officer or counsel review it before
/// launch, and replace [kPrivacyContactEmail] with a mailbox someone reads.
///
/// Bump [kTermsVersion] whenever the meaning changes. The version the user
/// agreed to is stored on their user document, so an old version is how you
/// tell who still needs to accept the new one.
library;

/// Shown in the panel header and written to `termsAcceptedVersion` at sign-up.
const String kTermsVersion = '1.0';

/// Date this wording took effect, shown under the heading.
const String kTermsLastUpdated = '16 September 2026';

/// TODO: point this at the school's real privacy mailbox before launch.
const String kPrivacyContactEmail = 'privacy@fieldtrip360.ph';

/// One headed block of the notice.
class TermsSection {
  const TermsSection(this.heading, this.body);

  final String heading;
  final String body;
}

const String kTermsIntro =
    'FieldTrip360 helps your school plan field trips, take attendance, follow '
    'the bus in real time, and reach guardians fast when something happens. '
    'Because it handles information about children — including where they are '
    'during a trip — please read this before you create an account. Scroll to '
    'the end to continue.';

const String kTermsClosing =
    'By ticking the box below you confirm that you have read this notice, that '
    'you agree to these terms, and that you consent to the collection and use '
    'of your personal information as described here. If you are the parent or '
    'guardian of a learner who is a minor, you are also giving that consent on '
    'their behalf.';

const List<TermsSection> kTermsSections = <TermsSection>[
  TermsSection(
    '1. Who this agreement is between',
    'Your school subscribes to FieldTrip360 and decides who may join, which '
        'trips run, and what records are kept. Under the Data Privacy Act of '
        '2012 (Republic Act No. 10173), your school is the personal '
        'information controller and FieldTrip360 processes information on its '
        'instructions. These terms cover your use of the app; your school '
        'handbook and its own privacy policy apply alongside them.',
  ),
  TermsSection(
    '2. Who may create an account',
    'Accounts are for learners listed on their school roster, parents and '
        'guardians holding a valid activation code from the school, and '
        'teachers and staff authorised by a school administrator.\n\n'
        'Sign up with your real name and the email address your school has on '
        'file, so the app can match you to the right records. If the account '
        'holder is a minor, a parent or guardian must agree to these terms on '
        'their behalf.\n\n'
        'Accounts are personal. Never share your password or your activation '
        'code — the code is what links a guardian to a specific child. Signing '
        'in on a new device signs the account out on the previous one.',
  ),
  TermsSection(
    '3. What information we collect',
    'Account details: your first name and surname, email address, role, and — '
        'for learners — your Learner Reference Number (LRN). Your password is '
        'stored by Google Firebase Authentication in hashed form; nobody at '
        'your school or at FieldTrip360 can read it.\n\n'
        'School records: the roster entry your school uploads (which may '
        'include your section, your guardian email, and your LRN), the '
        'guardian-to-learner links created by activation codes, and your '
        'school and class membership.\n\n'
        'Trip records: which trips you belong to, QR attendance scans, '
        'boarding and head-count times, stops, and who marked you present.\n\n'
        'Location: the GPS position of your device while a trip you belong to '
        'is running. Section 6 explains this in full.\n\n'
        'Documents: parental consent waivers and medical clearances uploaded '
        'for a trip. These can contain health information, which the Data '
        'Privacy Act treats as sensitive personal information.\n\n'
        'Messages and alerts: trip chat messages, announcements, and any '
        'emergency or SOS alert you raise, with the time and place it was '
        'sent.\n\n'
        'Technical data: push notification tokens, basic device and app '
        'information, sign-in times, the active session for your account, and '
        'error logs used to fix problems.',
  ),
  TermsSection(
    '4. How your information is used',
    'We use it to create and secure your account, verify your email, and match '
        'you to your school roster; to link guardians to their own children '
        'and nobody else; to run attendance and head counts; to show the trip '
        'in progress and raise geofence and arrival alerts; to deliver chat '
        'messages, announcements, and emergency notifications; to keep the '
        'safety and attendance records your school is required to keep; to '
        'answer support requests; and to detect misuse and keep the service '
        'working.\n\n'
        'We do not sell personal information, and we do not use it for '
        'advertising or profiling unrelated to the service.',
  ),
  TermsSection(
    '5. Automated checking of waivers and medical clearances',
    'To spare teachers from reading hundreds of scans, uploaded waivers and '
        'medical clearances are screened automatically by an AI service '
        '(Google Gemini). The check looks at whether the document belongs to '
        'the named learner and trip, whether it is signed, and whether it is '
        'complete and legible.\n\n'
        'The result is advice, not a decision. A teacher or administrator '
        'makes the final call on whether a learner may join a trip, and you '
        'can ask them to review a document by hand if you disagree with the '
        'automated result.',
  ),
  TermsSection(
    '6. Location during trips',
    'While a trip you belong to is active, the app collects your device '
        'location so the school and the guardians of the learners on board can '
        'see where the group is, and so the app can warn everyone if the group '
        'leaves its safe zone. On phones this can continue while the app is in '
        'the background, which your device will tell you about.\n\n'
        'Collection stops when the trip ends. Guardians see the trips of their '
        'own children only. You can switch location off in your device '
        'settings at any time; live tracking, geofence alerts, and some safety '
        'features will not work if you do.',
  ),
  TermsSection(
    '7. Who can see your information',
    'Administrators at your school, and the teachers assigned to a trip you '
        'are on, for the records that trip needs.\n\n'
        'Parents and guardians, for the children linked to them by a '
        'school-issued activation code or by the roster — not for any other '
        'learner.\n\n'
        'Other people on the same trip, who see your display name on chat '
        'messages and in the trip roster.\n\n'
        'Service providers who process data for us under contract: Google '
        'Firebase (sign-in, database, file storage, push notifications) and '
        'Google Gemini (the document checks in section 5).\n\n'
        'Emergency responders, your school, or public authorities where it is '
        'needed to protect someone from harm or where the law requires it.',
  ),
  TermsSection(
    '8. Keeping your information safe',
    'Traffic between the app and our servers is encrypted. Access is limited '
        'by role and by school, so one school cannot see another school data. '
        'Email addresses must be verified, only one device may hold an active '
        'session per account, and administrative actions are logged.\n\n'
        'No system is perfectly secure. Tell your school administrator '
        'immediately if you think someone else is using your account.',
  ),
  TermsSection(
    '9. How long we keep it',
    'Your account information is kept while your account is active and while '
        'your school subscribes. Trip, attendance, and incident records are '
        'kept for as long as your school policy and Philippine law require '
        'them, because they are safety records. Uploaded waivers and medical '
        'clearances are kept until the school deletes them or the trip records '
        'are disposed of.\n\n'
        'When a retention period ends, information is deleted or anonymised. '
        'Location points are only useful during a trip and are not kept for '
        'marketing or profiling.',
  ),
  TermsSection(
    '10. Your rights under the Data Privacy Act',
    'You have the right to be informed about how your information is used; to '
        'access it; to correct anything inaccurate; to object to certain '
        'processing; to ask that information be erased or blocked where the '
        'law allows; to receive a copy in a portable format; to be indemnified '
        'for damage caused by false or unlawfully obtained data; and to '
        'complain to the National Privacy Commission (privacy.gov.ph).\n\n'
        'To exercise any of these, contact your school administrator or Data '
        'Protection Officer first, since your school holds the records. You '
        'may also write to $kPrivacyContactEmail. Some records, such as '
        'attendance and incident logs, cannot be erased on request while the '
        'school is required to keep them.',
  ),
  TermsSection(
    '11. Learners who are minors',
    'An account for a learner under 18 may only be created with the knowledge '
        'and consent of a parent or guardian and the school. Guardians may ask '
        'the school to show them what the app holds about their child, to '
        'correct it, or to stop location sharing for that child, understanding '
        'that this also switches off the safety alerts that depend on it. '
        'Health information in a medical clearance is handled with extra care '
        'and shown only to the staff responsible for the trip.',
  ),
  TermsSection(
    '12. What we ask of you',
    'Give accurate information and keep it up to date. Keep your password and '
        'activation code to yourself. Do not create an account for someone '
        'else or pretend to be another person. Do not share another family '
        'photos, documents, or location outside the app. Use chat and the '
        'emergency alert for their real purpose — a false SOS wastes the '
        'response of people who are trying to keep children safe. Do not try '
        'to break, scrape, or reverse-engineer the service. Accounts that are '
        'misused can be suspended by your school.',
  ),
  TermsSection(
    '13. What the service is not',
    'FieldTrip360 is a tool that supports supervision. It does not replace the '
        'teachers and chaperones responsible for the learners, and it is not '
        'an emergency service. Location depends on the device, its battery, '
        'and mobile signal, and can be delayed or unavailable. In a real '
        'emergency, call your local emergency number first and use the app '
        'afterwards. The service is provided as is, without a guarantee of '
        'uninterrupted availability.',
  ),
  TermsSection(
    '14. Changes to these terms',
    'We may update this notice as the app changes or the law requires. The '
        'version and date at the top of this panel tell you which wording you '
        'agreed to. If a change materially affects your rights, we will ask '
        'you to read and accept the new version the next time you sign in.',
  ),
  TermsSection(
    '15. Governing law and contact',
    'These terms are governed by the laws of the Republic of the Philippines, '
        'including the Data Privacy Act of 2012 and its implementing rules.\n\n'
        'For questions, requests, or complaints, start with your school '
        'administrator or Data Protection Officer. You can also reach us at '
        '$kPrivacyContactEmail.',
  ),
];
