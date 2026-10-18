import QtQuick

Item {
    id: avatarRoot

    property int size: 28
    property string avatarType: "strobi" // "strobi" | "grok" | "citrus" | "nova" | "kirby" | "freddy"
    property string expression: "proud"  // "neutral" | "proud" | "happy" | "working" | "celebrate" | "idle" | "angry" | "dizzy" | "wave" | "task_start"

    // Eye Tracking Target Offset (-1.0 .. 1.0)
    property real targetLookX: 0.0
    property real targetLookY: 0.0

    property bool isBlinking: false

    width: size
    height: size

    // Palette & Shape Profiles dari Bible Strong Avatar Lab
    readonly property var avatarConfigs: {
        "strobi":  { body: "#5b7fe5", eyes: "#111316", radiusRatio: 0.5,  shape: "sphere" },
        "grok":    { body: "#0a0a0c", eyes: "#ffffff", radiusRatio: 0.5,  shape: "sphere" },
        "citrus":  { body: "#ffcf24", eyes: "#000000", radiusRatio: 0.35, shape: "cone" },
        "nova":    { body: "#55b6c3", eyes: "#111316", radiusRatio: 0.45, shape: "capsule" },
        "kirby":   { body: "#ffb6e0", eyes: "#2a3a50", radiusRatio: 0.5,  shape: "sphere" },
        "freddy":  { body: "#e6855c", eyes: "#ffffff", radiusRatio: 0.28, shape: "cube" },
        "mochi":   { body: "#f4f4f5", eyes: "#09090b", radiusRatio: 0.36, shape: "squircle" },
        "white":   { body: "#f8fafc", eyes: "#0f172a", radiusRatio: 0.5,  shape: "sphere" },
        "green":   { body: "#22c55e", eyes: "#052e16", radiusRatio: 0.45, shape: "capsule" },
        "amber":   { body: "#b45309", eyes: "#ffffff", radiusRatio: 0.35, shape: "cone" }
    }

    readonly property var currentConfig: avatarConfigs[avatarType] || avatarConfigs["strobi"]

    // Smoothed Look Offset
    property real lookX: 0.0
    property real lookY: 0.0
    Behavior on lookX { NumberAnimation { duration: 100; easing.type: Easing.OutQuad } }
    Behavior on lookY { NumberAnimation { duration: 100; easing.type: Easing.OutQuad } }
    onTargetLookXChanged: lookX = Math.max(-1.0, Math.min(1.0, targetLookX))
    onTargetLookYChanged: lookY = Math.max(-1.0, Math.min(1.0, targetLookY))

    // Head Tilt & Bounce saat Celebrate / Dizzy
    property real headTiltZ: {
        if (expression === "dizzy") return 14.0;
        if (expression === "proud") return -10.0;
        if (expression === "happy") return 12.0;
        if (expression === "celebrate") return -8.0;
        if (expression === "working") return -8.0;
        if (expression === "angry") return 0.0;
        return 0.0;
    }
    Behavior on headTiltZ { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

    // Blink Interval acak (hanya saat normal)
    Timer {
        interval: 3000 + Math.random() * 2000
        running: expression !== "angry" && expression !== "celebrate" && expression !== "dizzy"
        repeat: true
        onTriggered: {
            avatarRoot.isBlinking = true;
            blinkEndTimer.restart();
            interval = 2800 + Math.random() * 2500;
        }
    }

    Timer {
        id: blinkEndTimer
        interval: 220
        onTriggered: avatarRoot.isBlinking = false
    }

    // Avatar Body
    Item {
        id: bodyContainer
        anchors.fill: parent

        // Efek melambai & bergoyang senang saat menyapa (Wave / Welcome)
        SequentialAnimation on rotation {
            running: avatarRoot.expression === "wave"
            loops: Animation.Infinite
            NumberAnimation { to: -14; duration: 130; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 14; duration: 130; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 0; duration: 100; easing.type: Easing.InOutQuad }
        }

        // Efek hentakan siap kerja saat Task Baru dimulai (Task Start Punch)
        SequentialAnimation on scale {
            running: avatarRoot.expression === "task_start"
            loops: 2
            NumberAnimation { to: 1.25; duration: 120; easing.type: Easing.OutBack }
            NumberAnimation { to: 0.95; duration: 100; easing.type: Easing.InQuad }
            NumberAnimation { to: 1.0; duration: 100; easing.type: Easing.OutQuad }
        }

        // Efek getar intens saat marah
        SequentialAnimation on x {
            running: avatarRoot.expression === "angry"
            loops: Animation.Infinite
            NumberAnimation { to: -1.8; duration: 45 }
            NumberAnimation { to: 1.8; duration: 45 }
            NumberAnimation { to: 0; duration: 45 }
        }

        // Efek getar cepat bergelombang saat pusing diklik (Dizzy Shaking)
        SequentialAnimation on x {
            running: avatarRoot.expression === "dizzy"
            loops: Animation.Infinite
            NumberAnimation { to: -2.5; duration: 35 }
            NumberAnimation { to: 2.5; duration: 35 }
            NumberAnimation { to: 0; duration: 35 }
        }

        SequentialAnimation on rotation {
            running: avatarRoot.expression === "dizzy"
            loops: Animation.Infinite
            NumberAnimation { to: -6; duration: 60 }
            NumberAnimation { to: 6; duration: 60 }
            NumberAnimation { to: 0; duration: 60 }
        }

        // Efek lompat kegirangan saat celebrate (Task Selesai)
        SequentialAnimation on y {
            running: avatarRoot.expression === "celebrate"
            loops: 4
            NumberAnimation { to: -4; duration: 120; easing.type: Easing.OutQuad }
            NumberAnimation { to: 0; duration: 120; easing.type: Easing.InQuad }
        }

        Rectangle {
            id: bodyShape
            anchors.fill: parent
            radius: avatarRoot.size * currentConfig.radiusRatio

            // Warna Body dinamis: Merah (Angry), Hijau (Celebrate), Tetap Warna Asli (Dizzy/Normal)
            gradient: Gradient {
                GradientStop {
                    position: 0.0
                    color: {
                        if (avatarRoot.expression === "angry") return "#ef4444";
                        if (avatarRoot.expression === "celebrate") return "#4ade80";
                        return Qt.lighter(currentConfig.body, 1.25);
                    }
                }
                GradientStop {
                    position: 0.7
                    color: {
                        if (avatarRoot.expression === "angry") return "#dc2626";
                        if (avatarRoot.expression === "celebrate") return "#22c55e";
                        return currentConfig.body;
                    }
                }
                GradientStop {
                    position: 1.0
                    color: {
                        if (avatarRoot.expression === "angry") return "#991b1b";
                        if (avatarRoot.expression === "celebrate") return "#15803d";
                        return Qt.darker(currentConfig.body, 1.35);
                    }
                }
            }

            border.color: {
                if (avatarRoot.expression === "angry") return "#b91c1c";
                if (avatarRoot.expression === "celebrate") return "#86efac";
                return Qt.rgba(0, 0, 0, 0.25);
            }
            border.width: 1

            // Pantulan cahaya kubah 3D
            Rectangle {
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.topMargin: avatarRoot.size * 0.08
                width: avatarRoot.size * 0.7
                height: avatarRoot.size * 0.32
                radius: height / 2
                color: Qt.rgba(1, 1, 1, 0.45)
            }

            rotation: avatarRoot.headTiltZ

            // Wajah & Mata
            Item {
                id: faceLayer
                width: avatarRoot.size * 0.72
                height: avatarRoot.size * 0.55
                anchors.centerIn: parent

                anchors.horizontalCenterOffset: avatarRoot.lookX * (avatarRoot.size * 0.18) + (expression === "proud" ? avatarRoot.size * 0.08 : 0)
                anchors.verticalCenterOffset: avatarRoot.lookY * (avatarRoot.size * 0.14) + (expression === "proud" ? -avatarRoot.size * 0.06 : (expression === "angry" ? avatarRoot.size * 0.06 : (expression === "celebrate" ? -avatarRoot.size * 0.04 : 0)))

                // Dimensi Mata
                readonly property real eyeWidth: avatarRoot.size * 0.16
                readonly property real eyeHeight: {
                    if (avatarRoot.isBlinking && expression !== "angry" && expression !== "celebrate" && expression !== "dizzy") return 2.2;
                    if (expression === "celebrate") return avatarRoot.size * 0.22;
                    if (expression === "proud") return avatarRoot.size * 0.32;
                    if (expression === "dizzy") return avatarRoot.size * 0.26;
                    return avatarRoot.size * 0.26;
                }

                // ==================== MATA KIRI ====================
                Item {
                    id: leftEyeWrapper
                    width: faceLayer.eyeWidth
                    height: faceLayer.eyeHeight
                    anchors.verticalCenter: parent.verticalCenter
                    x: parent.width * 0.25 - width / 2

                    // Normal Pill Eye
                    Rectangle {
                        visible: avatarRoot.expression !== "angry" && avatarRoot.expression !== "celebrate" && avatarRoot.expression !== "dizzy"
                        anchors.fill: parent
                        radius: width / 2
                        color: currentConfig.eyes

                        rotation: {
                            if (expression === "proud") return -12;
                            if (expression === "working") return -18;
                            if (expression === "happy") return 15;
                            return 0;
                        }
                        Behavior on rotation { NumberAnimation { duration: 250 } }
                    }

                    // Dizzy Eye Kiri (Mata Spiral Pusing Berputar @)
                    Canvas {
                        id: leftDizzyCanvas
                        visible: avatarRoot.expression === "dizzy"
                        anchors.fill: parent

                        property real spinAngle: 0
                        NumberAnimation on spinAngle {
                            running: avatarRoot.expression === "dizzy"
                            from: 0; to: 360; duration: 500; loops: Animation.Infinite
                        }

                        onPaint: {
                            let ctx = getContext("2d");
                            ctx.reset();
                            ctx.strokeStyle = currentConfig.eyes;
                            ctx.lineWidth = 1.8;
                            ctx.lineCap = "round";

                            // Gambar spiral pusing
                            ctx.beginPath();
                            let cx = width / 2;
                            let cy = height / 2;
                            let rad = Math.min(width, height) * 0.45;
                            for (let a = 0; a < Math.PI * 4; a += 0.25) {
                                let r = (a / (Math.PI * 4)) * rad;
                                let rot = a + (spinAngle * Math.PI / 180);
                                let x = cx + r * Math.cos(rot);
                                let y = cy + r * Math.sin(rot);
                                if (a === 0) ctx.moveTo(x, y);
                                else ctx.lineTo(x, y);
                            }
                            ctx.stroke();
                        }
                    }

                    // Celebrate Eye Kiri (^ Senang Melengkung)
                    Canvas {
                        id: leftCelebrateCanvas
                        visible: avatarRoot.expression === "celebrate"
                        anchors.fill: parent
                        onPaint: {
                            let ctx = getContext("2d");
                            ctx.reset();
                            ctx.strokeStyle = "#ffffff";
                            ctx.lineWidth = 2.4;
                            ctx.lineCap = "round";
                            ctx.beginPath();
                            ctx.arc(width / 2, height * 0.8, width * 0.65, Math.PI * 1.15, Math.PI * 1.85, false);
                            ctx.stroke();
                        }
                    }

                    // Angry Eye Kiri (Tajam Miring)
                    Canvas {
                        id: leftAngryCanvas
                        visible: avatarRoot.expression === "angry"
                        anchors.fill: parent
                        onPaint: {
                            let ctx = getContext("2d");
                            ctx.reset();
                            ctx.fillStyle = "#ffffff";
                            ctx.beginPath();
                            ctx.moveTo(0, height * 0.15);
                            ctx.lineTo(width, height * 0.65);
                            ctx.lineTo(width * 0.85, height * 0.95);
                            ctx.lineTo(0, height * 0.7);
                            ctx.closePath();
                            ctx.fill();
                        }
                    }
                }

                // ==================== MATA KANAN ====================
                Item {
                    id: rightEyeWrapper
                    width: faceLayer.eyeWidth
                    height: faceLayer.eyeHeight
                    anchors.verticalCenter: parent.verticalCenter
                    x: parent.width * 0.75 - width / 2

                    // Normal Pill Eye
                    Rectangle {
                        visible: avatarRoot.expression !== "angry" && avatarRoot.expression !== "celebrate" && avatarRoot.expression !== "dizzy"
                        anchors.fill: parent
                        radius: width / 2
                        color: currentConfig.eyes

                        rotation: {
                            if (expression === "proud") return 12;
                            if (expression === "working") return 18;
                            if (expression === "happy") return -15;
                            return 0;
                        }
                        Behavior on rotation { NumberAnimation { duration: 250 } }
                    }

                    // Dizzy Eye Kanan (Mata Spiral Pusing Berputar @ arah berlawanan)
                    Canvas {
                        id: rightDizzyCanvas
                        visible: avatarRoot.expression === "dizzy"
                        anchors.fill: parent

                        property real spinAngle: 0
                        NumberAnimation on spinAngle {
                            running: avatarRoot.expression === "dizzy"
                            from: 360; to: 0; duration: 500; loops: Animation.Infinite
                        }

                        onPaint: {
                            let ctx = getContext("2d");
                            ctx.reset();
                            ctx.strokeStyle = currentConfig.eyes;
                            ctx.lineWidth = 1.8;
                            ctx.lineCap = "round";

                            ctx.beginPath();
                            let cx = width / 2;
                            let cy = height / 2;
                            let rad = Math.min(width, height) * 0.45;
                            for (let a = 0; a < Math.PI * 4; a += 0.25) {
                                let r = (a / (Math.PI * 4)) * rad;
                                let rot = a + (spinAngle * Math.PI / 180);
                                let x = cx + r * Math.cos(rot);
                                let y = cy + r * Math.sin(rot);
                                if (a === 0) ctx.moveTo(x, y);
                                else ctx.lineTo(x, y);
                            }
                            ctx.stroke();
                        }
                    }

                    // Celebrate Eye Kanan (^ Senang Melengkung)
                    Canvas {
                        id: rightCelebrateCanvas
                        visible: avatarRoot.expression === "celebrate"
                        anchors.fill: parent
                        onPaint: {
                            let ctx = getContext("2d");
                            ctx.reset();
                            ctx.strokeStyle = "#ffffff";
                            ctx.lineWidth = 2.4;
                            ctx.lineCap = "round";
                            ctx.beginPath();
                            ctx.arc(width / 2, height * 0.8, width * 0.65, Math.PI * 1.15, Math.PI * 1.85, false);
                            ctx.stroke();
                        }
                    }

                    // Angry Eye Kanan (Tajam Miring)
                    Canvas {
                        id: rightAngryCanvas
                        visible: avatarRoot.expression === "angry"
                        anchors.fill: parent
                        onPaint: {
                            let ctx = getContext("2d");
                            ctx.reset();
                            ctx.fillStyle = "#ffffff";
                            ctx.beginPath();
                            ctx.moveTo(width, height * 0.15);
                            ctx.lineTo(0, height * 0.65);
                            ctx.lineTo(width * 0.15, height * 0.95);
                            ctx.lineTo(width, height * 0.7);
                            ctx.closePath();
                            ctx.fill();
                        }
                    }
                }
            }
        }
    }
}
