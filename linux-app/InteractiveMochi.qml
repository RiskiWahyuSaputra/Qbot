import QtQuick

Item {
    id: mochi

    property int size: 28
    property color bodyColor: "#f4f4f5"
    property real targetLookX: 0.0 // -1.0 .. 1.0
    property real targetLookY: 0.0 // -1.0 .. 1.0
    property bool isSmiling: false
    property bool isBlinking: false
    property bool isHappy: false

    width: size
    height: size

    // Smoothed look coordinates
    property real currentLookX: 0.0
    property real currentLookY: 0.0

    Behavior on currentLookX { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
    Behavior on currentLookY { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }

    onTargetLookXChanged: currentLookX = Math.max(-1.0, Math.min(1.0, targetLookX))
    onTargetLookYChanged: currentLookY = Math.max(-1.0, Math.min(1.0, targetLookY))

    // Kedipan Mata Alami
    Timer {
        id: blinkTimer
        interval: 3200 + Math.random() * 2000
        running: true
        repeat: true
        onTriggered: {
            mochi.isBlinking = true;
            blinkDurationTimer.restart();
            interval = 2800 + Math.random() * 3000;
        }
    }

    Timer {
        id: blinkDurationTimer
        interval: 160
        repeat: false
        onTriggered: mochi.isBlinking = false
    }

    // Body Squircle Mochi (Lembut & Bergradasi Halus)
    Rectangle {
        id: body
        anchors.fill: parent
        radius: mochi.size * 0.36
        gradient: Gradient {
            GradientStop { position: 0.0; color: mochi.isHappy ? "#bbf7d0" : mochi.bodyColor }
            GradientStop { position: 1.0; color: mochi.isHappy ? "#4ade80" : "#d4d4d8" }
        }
        border.color: mochi.isHappy ? "#22c55e" : "#a1a1aa"
        border.width: 1.0

        // Highlight pantulan cahaya atas
        Rectangle {
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.topMargin: mochi.size * 0.1
            width: mochi.size * 0.65
            height: mochi.size * 0.28
            radius: height / 2
            color: Qt.rgba(1, 1, 1, 0.45)
        }

        // Wadah Wajah (Mata & Mulut) yang bergerak mengikuti arah pandangan (Eye Tracking)
        Item {
            id: faceContainer
            width: mochi.size * 0.72
            height: mochi.size * 0.6
            anchors.centerIn: parent
            anchors.horizontalCenterOffset: mochi.currentLookX * (mochi.size * 0.16)
            anchors.verticalCenterOffset: mochi.currentLookY * (mochi.size * 0.12)

            // Mata Kiri
            Item {
                id: leftEyeContainer
                width: mochi.size * 0.16
                height: mochi.size * 0.26
                x: parent.width * 0.22 - width / 2
                y: parent.height * 0.35 - height / 2

                // Mata Normal (Pill)
                Rectangle {
                    visible: !mochi.isSmiling && !mochi.isHappy && !mochi.isBlinking
                    anchors.centerIn: parent
                    width: parent.width
                    height: parent.height
                    radius: width / 2
                    color: "#09090b"
                }

                // Mata Berkedip (Garis Datar)
                Rectangle {
                    visible: mochi.isBlinking && !mochi.isSmiling && !mochi.isHappy
                    anchors.centerIn: parent
                    width: parent.width * 1.1
                    height: 2.2
                    radius: 1
                    color: "#09090b"
                }

                // Mata Tersenyum / Gembira (^ shape)
                Canvas {
                    id: leftSmileCanvas
                    visible: mochi.isSmiling || mochi.isHappy
                    anchors.fill: parent
                    onPaint: {
                        let ctx = getContext("2d");
                        ctx.reset();
                        ctx.lineWidth = 2.4;
                        ctx.lineCap = "round";
                        ctx.strokeStyle = "#09090b";
                        ctx.beginPath();
                        ctx.arc(width / 2, height * 0.8, width * 0.75, Math.PI * 1.15, Math.PI * 1.85, false);
                        ctx.stroke();
                    }
                }
            }

            // Mata Kanan
            Item {
                id: rightEyeContainer
                width: mochi.size * 0.16
                height: mochi.size * 0.26
                x: parent.width * 0.78 - width / 2
                y: parent.height * 0.35 - height / 2

                // Mata Normal (Pill)
                Rectangle {
                    visible: !mochi.isSmiling && !mochi.isHappy && !mochi.isBlinking
                    anchors.centerIn: parent
                    width: parent.width
                    height: parent.height
                    radius: width / 2
                    color: "#09090b"
                }

                // Mata Berkedip (Garis Datar)
                Rectangle {
                    visible: mochi.isBlinking && !mochi.isSmiling && !mochi.isHappy
                    anchors.centerIn: parent
                    width: parent.width * 1.1
                    height: 2.2
                    radius: 1
                    color: "#09090b"
                }

                // Mata Tersenyum / Gembira (^ shape)
                Canvas {
                    id: rightSmileCanvas
                    visible: mochi.isSmiling || mochi.isHappy
                    anchors.fill: parent
                    onPaint: {
                        let ctx = getContext("2d");
                        ctx.reset();
                        ctx.lineWidth = 2.4;
                        ctx.lineCap = "round";
                        ctx.strokeStyle = "#09090b";
                        ctx.beginPath();
                        ctx.arc(width / 2, height * 0.8, width * 0.75, Math.PI * 1.15, Math.PI * 1.85, false);
                        ctx.stroke();
                    }
                }
            }

            // Mulut Senyum Mochi (Cute Smile Arc)
            Canvas {
                id: mouthCanvas
                visible: mochi.isSmiling || mochi.isHappy
                width: mochi.size * 0.28
                height: mochi.size * 0.16
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: parent.height * 0.58

                onPaint: {
                    let ctx = getContext("2d");
                    ctx.reset();
                    ctx.lineWidth = 2.0;
                    ctx.lineCap = "round";
                    ctx.strokeStyle = "#09090b";
                    ctx.beginPath();
                    ctx.arc(width / 2, 0, width * 0.45, Math.PI * 0.1, Math.PI * 0.9, false);
                    ctx.stroke();
                }
            }

            // Blush Pipi Merah Muda Lucu saat Senyum/Happy
            Row {
                visible: mochi.isSmiling || mochi.isHappy
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: parent.height * 0.44
                spacing: parent.width * 0.52

                Rectangle {
                    width: mochi.size * 0.14
                    height: mochi.size * 0.08
                    radius: height / 2
                    color: Qt.rgba(0.96, 0.45, 0.55, 0.65)
                }
                Rectangle {
                    width: mochi.size * 0.14
                    height: mochi.size * 0.08
                    radius: height / 2
                    color: Qt.rgba(0.96, 0.45, 0.55, 0.65)
                }
            }
        }
    }
}
