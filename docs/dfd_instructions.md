# FieldTrip360 — DFD Draw.io Instructions

---

## SHAPE LEGEND (gamitin sa lahat ng diagram)

| Type | Shape sa draw.io | Fill Color | Border | Text |
|---|---|---|---|---|
| **External Entity** | Rectangle (sharp corners) | White | Black, 1.5px | Bold, 12pt |
| **Process** | Rounded Rectangle | #DBEAFE (light blue) | #2563EB (blue), 1.5px | Bold, 11pt — ilagay ang number sa top-left (smaller text), pangalan sa center |
| **Data Store** | Ang shape sa draw.io ay yung "Horizontal Line" o "Partial Rectangle" — dalawang horizontal na linya lang, walang left/right border. Sa draw.io: search "data store" sa shapes panel | White | Black top & bottom lines lang | Normal, 10pt — format: "D1  Trip Details" |
| **Arrow / Flow** | Connector with Arrow | — | Black, 1px | Italic, 9pt — ilagay ang label sa gitna ng arrow |

> **Tip sa draw.io para sa Data Store shape:**
> Shape panel → search **"data"** → piliin ang **"Data Store"** under Flowchart shapes.
> Ito yung may dalawang linya lang (open sa left at right).

---

## DFD LEVEL 0 — Context Diagram

### Shapes:

| ID | Type | Label |
|---|---|---|
| SYS | Process (malaking rounded rect, center ng diagram) | FieldTrip360 System |
| STU | External Entity | Student |
| TCH | External Entity | Teacher |
| PAR | External Entity | Parent |
| ADM | External Entity | School Admin |

### Layout:
- **SYS** — gitna ng diagram (malaki, ~200x100)
- **STU** — kaliwa ng SYS
- **PAR** — kaliwa-baba ng SYS
- **TCH** — kanan ng SYS
- **ADM** — kanan-baba ng SYS

### Arrows (lahat straight/orthogonal):

| Mula | Patungo | Label |
|---|---|---|
| STU | SYS | QR Attendance, GPS Data |
| STU | SYS | SOS Alert |
| SYS | STU | Trip Notifications (Depart / Arrive) |
| SYS | STU | Geofence Warning |
| STU | SYS | Communication via Chat |
| SYS | STU | Communication via Chat |
| PAR | SYS | Child Link Request (QR / LRN) |
| PAR | SYS | Communication via Chat |
| SYS | PAR | Student Location Updates & SOS Notif |
| SYS | PAR | Communication via Chat |
| TCH | SYS | Roll Call |
| TCH | SYS | Communication via Chat |
| SYS | TCH | Attendance Confirmation |
| SYS | TCH | Geofence & SOS Alerts |
| SYS | TCH | Communication via Chat |
| ADM | SYS | Trip Info, Destination Details |
| ADM | SYS | Geofence Configuration |
| SYS | ADM | Monitoring Reports |
| SYS | ADM | Communication via Chat |

---

## DFD LEVEL 1 — System Level

### External Entities:

| ID | Label | Position |
|---|---|---|
| STU | Student | kaliwa, taas |
| PAR | Parent | kaliwa, baba |
| TCH | Teacher | kanan, taas |
| ADM | School Admin | taas, gitna |

### Processes:

| ID | Label | Position (approx) |
|---|---|---|
| P1 | **1** — Setup Trip & Geofence | taas-gitna |
| P2 | **2** — Manage Student & Parent Info | kanan-gitna |
| P3 | **3** — Log Attendance & GPS | kaliwa-gitna |
| P4 | **4** — Monitor Geofence | gitna |
| P5 | **5** — Trigger SOS | baba-kaliwa |
| P6 | **6** — Chat & Direct Messaging | baba-kanan |
| P7 | **7** — Generate Reports | baba-gitna |

### Data Stores:

| ID | Label | Position (approx) |
|---|---|---|
| D1 | D1   Trip Details | sa pagitan ng P1 at P4 |
| D2 | D2   Student & Parent Information | sa pagitan ng P2 at P3 |
| D3 | D3   Attendance Records | malapit sa P3, baba |
| D4 | D4   Chat History | malapit sa P6 |
| D5 | D5   SOS & Geofence Alerts | sa pagitan ng P4 at P5 |
| D6 | D6   GPS Location Data | sa pagitan ng P3 at P4 |
| D7 | D7   Reports Log | malapit sa P7 |

### Arrows:

**Process 1 — Setup Trip & Geofence:**

| Mula | Patungo | Label |
|---|---|---|
| ADM | P1 | fieldtrip details (destination, date, time) |
| ADM | P1 | geofence coordinates (1–4000m per stop) |
| P1 | D1 | trip & geofence data |
| P1 | TCH | trip itinerary |
| P1 | STU | trip itinerary |
| P1 | PAR | trip notification |

**Process 2 — Manage Student & Parent Info:**

| Mula | Patungo | Label |
|---|---|---|
| STU | P2 | QR display / approve link |
| PAR | P2 | link request (QR scan / LRN) |
| TCH | P2 | view student list & QR |
| P2 | D2 | student & parent records |
| D2 | P2 | student & parent data |
| P2 | STU | identity QR code & text code |
| P2 | TCH | student & parent info |

**Process 3 — Log Attendance & GPS:**

| Mula | Patungo | Label |
|---|---|---|
| STU | P3 | GPS location data |
| TCH | P3 | QR scan (attendance marking) |
| D1 | P3 | trip schedule |
| D2 | P3 | student profile data |
| P3 | D3 | attendance record (QR + GPS + timestamp) |
| P3 | D6 | GPS location data |
| P3 | TCH | attendance status update |

**Process 4 — Monitor Geofence:**

| Mula | Patungo | Label |
|---|---|---|
| D6 | P4 | GPS data stream |
| D1 | P4 | geofence boundaries |
| P4 | TCH | geofence alert (alarm) |
| P4 | STU | geofence warning (alarm until re-entry) |
| P4 | D5 | alert record |

**Process 5 — Trigger SOS:**

| Mula | Patungo | Label |
|---|---|---|
| STU | P5 | SOS manual trigger |
| P5 | TCH | SOS notification |
| P5 | PAR | SOS notification |
| P5 | D5 | SOS alert record |

**Process 6 — Chat & Direct Messaging:**

| Mula | Patungo | Label |
|---|---|---|
| STU | P6 | chat messages & replies |
| TCH | P6 | chat & direct messages |
| PAR | P6 | chat messages & replies |
| ADM | P6 | communication via chat |
| P6 | D4 | save chat history |
| D4 | P6 | retrieve chat history |
| P6 | STU | messages delivered |
| P6 | TCH | messages delivered |
| P6 | PAR | messages delivered |
| P6 | ADM | messages delivered |

**Process 7 — Generate Reports:**

| Mula | Patungo | Label |
|---|---|---|
| ADM | P7 | filter parameters (date, teacher, bus number) |
| D1 | P7 | trip details |
| D3 | P7 | attendance data |
| D5 | P7 | geofence violations & SOS data |
| P7 | ADM | generated PDF report |
| P7 | D7 | report record |

---

## LEVEL 2 — Process 1: Setup Trip & Geofence

### External Entities: School Admin, Teacher, Student, Parent

### Processes:

| ID | Label |
|---|---|
| P1.1 | **1.1** — Receive Trip Details |
| P1.2 | **1.2** — Define Stop Locations (Auto-fill Name via Reverse Geocode) |
| P1.3 | **1.3** — Define Geofence Boundaries (1–4000 m per stop, kasama Origin) |
| P1.4 | **1.4** — Save Trip Information |
| P1.5 | **1.5** — Share Trip Information |

### Data Stores: D1 — Trip Details

### Arrows:

| Mula | Patungo | Label |
|---|---|---|
| ADM | P1.1 | trip details (title, date, time, bus) |
| P1.1 | P1.2 | raw trip data |
| P1.2 | P1.2 | Google Geocoding API (auto-fill location name) *(self-loop o note lang)* |
| P1.2 | P1.3 | stop locations & names |
| P1.3 | P1.4 | geofence config (radius per stop) |
| P1.4 | D1 | store trip record |
| D1 | P1.5 | trip data |
| P1.5 | TCH | trip itinerary |
| P1.5 | STU | trip notification |
| P1.5 | PAR | trip notification |

---

## LEVEL 2 — Process 2: Manage Student & Parent Information

### External Entities: Student, Parent, Teacher

### Processes:

| ID | Label |
|---|---|
| P2.1 | **2.1** — Generate Student Identity QR Code (ID, Name, LRN, Code) |
| P2.2 | **2.2** — Receive Parent Link Request (QR Scan / LRN Entry) |
| P2.3 | **2.3** — Verify & Enforce Link Limit (Max 2 Parents per Student) |
| P2.4 | **2.4** — Student Approves Link Request |
| P2.5 | **2.5** — Store Student & Parent Record |

### Data Stores: D2 — Student & Parent Information

### Arrows:

| Mula | Patungo | Label |
|---|---|---|
| D2 | P2.1 | student profile (name, LRN, student ID) |
| P2.1 | STU | static QR code & text code (e.g. VCS-161430) |
| P2.1 | TCH | student QR & code (teacher view) |
| PAR | P2.2 | QR scan data or LRN |
| P2.2 | P2.3 | link request data |
| D2 | P2.3 | existing parentIds array |
| P2.3 | P2.4 | validated link request (if current parents < 2) |
| STU | P2.4 | approve / reject |
| P2.4 | P2.5 | approved link data |
| P2.5 | D2 | update parentIds array & linked children list |

---

## LEVEL 2 — Process 3: Log Attendance & GPS

### External Entities: Student, Teacher, Parent

### Processes:

| ID | Label |
|---|---|
| P3.1 | **3.1** — Scan Student Identity QR Code |
| P3.2 | **3.2** — Capture GPS Location (Background, 5s Heartbeat) |
| P3.3 | **3.3** — Verify Attendance Data |
| P3.4 | **3.4** — Store Attendance Record |
| P3.5 | **3.5** — Provide Attendance Status |

### Data Stores: D1 — Trip Details, D2 — Student & Parent Info, D3 — Attendance Records, D6 — GPS Location Data

### Arrows:

| Mula | Patungo | Label |
|---|---|---|
| STU | P3.1 | QR code display (static identity QR) |
| P3.1 | P3.3 | scanned student ID |
| STU | P3.2 | GPS coordinates (background service) |
| P3.2 | D6 | GPS location data |
| D1 | P3.3 | trip schedule & stop data |
| D2 | P3.3 | student profile data |
| P3.3 | P3.4 | validated attendance entry |
| P3.4 | D3 | attendance log (QR + GPS + timestamp) |
| D3 | P3.5 | attendance data |
| P3.5 | TCH | attendance status update (present/absent per stop) |
| D6 | PAR | live GPS data of child |

---

## LEVEL 2 — Process 4: Monitor Geofence

### External Entities: Teacher, Student

### Processes:

| ID | Label |
|---|---|
| P4.1 | **4.1** — Receive GPS Data |
| P4.2 | **4.2** — Compare Location with Geofence Boundaries |
| P4.3 | **4.3** — Generate Geofence Alert (if Outside Boundary) |
| P4.4 | **4.4** — Notify Teacher (Alarm + Dialog, 1 Alert per Student) |
| P4.5 | **4.5** — Warn Student (Alarm Until Re-entry) |

### Data Stores: D1 — Trip Details, D5 — SOS & Geofence Alerts, D6 — GPS Location Data

### Arrows:

| Mula | Patungo | Label |
|---|---|---|
| D6 | P4.1 | GPS data stream (5s interval) |
| D1 | P4.2 | geofence boundaries (per stop, lahat ng stops) |
| P4.1 | P4.2 | current coordinates |
| P4.2 | P4.3 | location status (outside geofence) |
| P4.3 | D5 | alert record |
| P4.3 | P4.4 | geofence alert (student name, distance) |
| P4.3 | P4.5 | out-of-bounds flag |
| P4.4 | TCH | alarm + notification dialog (deduped per student) |
| P4.5 | STU | alarm (rings until re-entry, walang dismiss button) |

---

## LEVEL 2 — Process 5: Trigger SOS

### External Entities: Student, Teacher, Parent

### Processes:

| ID | Label |
|---|---|
| P5.1 | **5.1** — Receive SOS Request (Manual Trigger) |
| P5.2 | **5.2** — Capture Current GPS Location |
| P5.3 | **5.3** — Log SOS Alert (with Location & Timestamp) |
| P5.4 | **5.4** — Notify Concerned Parties via FCM |

### Data Stores: D5 — SOS & Geofence Alerts, D6 — GPS Location Data

### Arrows:

| Mula | Patungo | Label |
|---|---|---|
| STU | P5.1 | SOS manual trigger |
| P5.1 | P5.2 | SOS request |
| D6 | P5.2 | current GPS coordinates |
| P5.2 | P5.3 | SOS data + location |
| P5.3 | D5 | store SOS alert record |
| D5 | P5.4 | SOS alert |
| P5.4 | TCH | SOS notification (alarm + rescue dialog) |
| P5.4 | PAR | SOS notification (push notification) |

---

## LEVEL 2 — Process 6: Chat & Direct Messaging

### External Entities: Student, Teacher, Parent, School Admin

### Processes:

| ID | Label |
|---|---|
| P6.1 | **6.1** — Receive Message |
| P6.2 | **6.2** — Route Message (Group Trip Channel o Direct Message) |
| P6.3 | **6.3** — Save Chat History |
| P6.4 | **6.4** — Deliver Messages to Recipients |

### Data Stores: D4 — Chat History

### Arrows:

| Mula | Patungo | Label |
|---|---|---|
| STU | P6.1 | message (text) |
| TCH | P6.1 | message (text / DM) |
| PAR | P6.1 | message (text) |
| ADM | P6.1 | message (text) |
| P6.1 | P6.2 | raw message + sender ID |
| P6.2 | P6.3 | routed message |
| P6.3 | D4 | save chat record |
| D4 | P6.4 | chat history |
| P6.2 | P6.4 | recipient list |
| P6.4 | STU | delivered message |
| P6.4 | TCH | delivered message |
| P6.4 | PAR | delivered message |
| P6.4 | ADM | delivered message |

---

## LEVEL 2 — Process 7: Generate Reports *(BAGONG PROCESS)*

### External Entities: School Admin

### Processes:

| ID | Label |
|---|---|
| P7.1 | **7.1** — Receive Filter Parameters (Date, Teacher, Bus) |
| P7.2 | **7.2** — Retrieve Geofence Violations |
| P7.3 | **7.3** — Retrieve Trip & Attendance Data |
| P7.4 | **7.4** — Compile Report Data |
| P7.5 | **7.5** — Generate PDF Export |

### Data Stores: D1 — Trip Details, D3 — Attendance Records, D5 — SOS & Geofence Alerts, D7 — Reports Log

### Arrows:

| Mula | Patungo | Label |
|---|---|---|
| ADM | P7.1 | filter parameters (date range, teacher, bus number) |
| ADM | P7.1 | selected checkboxes (violations, trips) |
| P7.1 | P7.2 | filter criteria |
| P7.1 | P7.3 | filter criteria |
| D5 | P7.2 | geofence violations (student name, bus, time) |
| D1 | P7.3 | trip details (route, stops, status) |
| D3 | P7.3 | attendance records |
| P7.2 | P7.4 | violation data |
| P7.3 | P7.4 | trip & attendance data |
| P7.4 | P7.5 | compiled report data |
| P7.5 | ADM | PDF report |
| P7.5 | D7 | report record |
