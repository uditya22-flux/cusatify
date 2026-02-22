import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'qr_scanner_page.dart';
import 'library_session_page.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  static const int totalSeats = 30;
  int occupiedSeats = 0;
  bool loading = true;

  static const String validQr = "LIBRARY-ENTRY";

  @override
  void initState() {
    super.initState();
    loadSeatCount();
  }

  Future<void> loadSeatCount() async {
    // Count library_logs with status "checked_in" (not checked_out)
    final query = await FirebaseFirestore.instance
        .collection("library_logs")
        .where("status", isEqualTo: "checked_in")
        .get();

    if (mounted) {
      setState(() {
        occupiedSeats = query.docs.length;
        loading = false;
      });
    }
  }

  int get availableSeats => (totalSeats - occupiedSeats).clamp(0, totalSeats);

  // 🔥 PROCESS A SCANNED QR CODE
  Future<void> processScan(String scanned) async {
    // 1. Check for Attendance QR
    if (scanned.startsWith("ATTENDANCE:")) {
      await handleAttendanceScan(scanned);
      return;
    }

    // 2. Check for Library Entry QR
    if (scanned != validQr) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Invalid QR Code")),
      );
      return;
    }

    // Check seat availability
    if (availableSeats <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No seats available! Library is full.")),
      );
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // Check if student already checked in
    final existingCheckin = await FirebaseFirestore.instance
        .collection("library_logs")
        .where("uid", isEqualTo: user.uid)
        .where("status", isEqualTo: "checked_in")
        .get();

    if (existingCheckin.docs.isNotEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You are already checked in!")),
      );
      // Go to session page with existing log
      final logId = existingCheckin.docs.first.id;
      final checkedOut = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => LibrarySessionPage(logId: logId),
        ),
      );
      if (checkedOut == true) {
        loadSeatCount();
      }
      return;
    }

    final studentDoc = await FirebaseFirestore.instance
        .collection("students")
        .doc(user.uid)
        .get();

    if (!studentDoc.exists) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Student record not found")),
      );
      return;
    }

    final studentData = studentDoc.data()!;
    final now = DateTime.now();

    // Create library log entry
    final logRef = await FirebaseFirestore.instance.collection("library_logs").add({
      "uid": user.uid,
      "name": studentData["name"],
      "studentId": studentData["studentId"],
      "department": studentData["department"],
      "semester": studentData["semester"],
      "timestamp": FieldValue.serverTimestamp(),
      "date": "${now.year}-${now.month}-${now.day}",
      "time": "${now.hour}:${now.minute}:${now.second}",
      "status": "checked_in",
    });

    // Save student details to the scanned_students table
    await FirebaseFirestore.instance.collection("scanned_students").add({
      "uid": user.uid,
      "name": studentData["name"],
      "studentId": studentData["studentId"],
      "department": studentData["department"],
      "semester": studentData["semester"],
      "scannedAt": FieldValue.serverTimestamp(),
      "date": "${now.year}-${now.month}-${now.day}",
    });

    // Update occupied count
    setState(() {
      occupiedSeats++;
    });

    if (!mounted) return;

    // Navigate to session/timer page
    final checkedOut = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LibrarySessionPage(logId: logRef.id),
      ),
    );

    if (checkedOut == true) {
      loadSeatCount(); // refresh seat count after checkout
    }
  }

  Future<void> handleAttendanceScan(String scanned) async {
    // Format: ATTENDANCE:facultyUid:subject:semester:date
    final parts = scanned.split(":");
    if (parts.length < 5) return;

    final facultyUid = parts[1];
    final subject = parts[2];
    final semester = parts[3];
    final date = parts[4];

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // Get student details
    final studentDoc = await FirebaseFirestore.instance
        .collection("students")
        .doc(user.uid)
        .get();

    if (!studentDoc.exists) return;
    final studentData = studentDoc.data()!;

    // 1. Verify Semester matches
    if (studentData["semester"] != semester) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Mismatch: This QR is for Semester $semester")),
      );
      return;
    }

    // 2. Verify student has this subject
    final subjects = List<String>.from(studentData["subjects"] ?? []);
    if (!subjects.contains(subject)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: You are not registered for $subject")),
      );
      return;
    }

    // 3. Mark Attendance
    // Check if already marked for this subject and date
    final existing = await FirebaseFirestore.instance
        .collection("attendance")
        .where("studentUid", isEqualTo: user.uid)
        .where("subject", isEqualTo: subject)
        .where("date", isEqualTo: date)
        .get();

    if (existing.docs.isNotEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Attendance already marked for today!")),
      );
      return;
    }

    await FirebaseFirestore.instance.collection("attendance").add({
      "studentUid": user.uid,
      "studentName": studentData["name"],
      "studentId": studentData["studentId"],
      "facultyUid": facultyUid,
      "subject": subject,
      "semester": semester,
      "present": true,
      "date": date,
      "timestamp": FieldValue.serverTimestamp(),
    });

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Icon(Icons.check_circle, color: Colors.green, size: 60),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "Attendance Marked!",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Text("Present for $subject", textAlign: TextAlign.center),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Great!"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F1EB),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Column(
                children: [
                  header(),
                  const SizedBox(height: 20),
                  qrCard(),
                  const SizedBox(height: 20),
                  seatInfoCard(),
                  const SizedBox(height: 40),
                ],
              ),
            ),
    );
  }

  Widget header() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(top: 50, left: 20, right: 20, bottom: 40),
      decoration: const BoxDecoration(
        color: Color(0xFF5D1F1E),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(70),
          bottomRight: Radius.circular(70),
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: const Icon(Icons.arrow_back, color: Colors.white),
          ),
          const SizedBox(width: 10),
          const Text(
            "Library",
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget qrCard() {
    final isFull = availableSeats <= 0;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(25),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 8)],
      ),
      child: Column(
        children: [
          Icon(
            isFull ? Icons.block : Icons.qr_code_2,
            size: 50,
            color: isFull ? Colors.red : Colors.brown,
          ),
          const SizedBox(height: 10),
          Text(
            isFull ? "Library is Full" : "Scan QR to Check In",
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: isFull ? Colors.red : Colors.black,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            isFull
                ? "All $totalSeats seats are currently occupied. Please try again later."
                : "Scan the QR code at the library entrance to mark attendance",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isFull ? Colors.red.shade300 : Colors.black54,
            ),
          ),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: isFull
                ? null
                : () async {
                    final scanned = await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const QRScannerPage()),
                    );

                    if (scanned != null) {
                      await processScan(scanned);
                    }
                  },
            child: Container(
              height: 55,
              decoration: BoxDecoration(
                color: isFull ? Colors.grey.shade400 : const Color(0xFF5D1F1E),
                borderRadius: BorderRadius.circular(30),
              ),
              alignment: Alignment.center,
              child: Text(
                isFull ? "No Seats Available" : "Open Camera to Scan",
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget seatInfoCard() {
    final percentage = occupiedSeats / totalSeats;
    final color = percentage >= 1.0
        ? Colors.red
        : percentage >= 0.7
            ? Colors.orange
            : Colors.green;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF5D1F1E),
        borderRadius: BorderRadius.circular(25),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.event_seat, color: Colors.white, size: 28),
              const SizedBox(width: 15),
              Expanded(
                child: Text(
                  "Available: $availableSeats / $totalSeats seats",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: percentage.clamp(0.0, 1.0),
              minHeight: 10,
              backgroundColor: Colors.white24,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "$occupiedSeats occupied",
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              Text(
                "$availableSeats free",
                style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ],
      ),
    );
  }
}