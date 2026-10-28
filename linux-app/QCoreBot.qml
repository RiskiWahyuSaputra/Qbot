import QtQuick
import QtQuick.Effects
import QtQuick3D
import QtQuick3D.Helpers

// "Q-Core Bot" 3D — port dari QBotFab (three.js) di portofolio ke Qt Quick 3D.
// API sama dengan BibleStrongAvatar: size, avatarType, expression, targetLookX/Y.
//
// Idle: melayang, glow bernapas, berkedip, antena bergoyang, mengikuti kursor.
// Hover (wave/happy/dance): membesar, kepala miring, mata ^ ^, glow lebih terang.
// Klik (task_start/celebrate/poke()): squash & stretch, putar 360°, kilat glow, gelombang cincin.
// Pusing (dizzy): kepala berputar-putar, mata berputar, bintang mengitari kepala.
Item {
    id: avatarRoot

    property int size: 28
    property string avatarType: "white" // menentukan warna neon
    property string expression: "proud"  // "neutral" | "proud" | "happy" | "working" | "celebrate" | "idle" | "angry" | "dizzy" | "wave" | "task_start" | "sleepy" | "sweat" | "dance"

    // Eye Tracking Target Offset (-1.0 .. 1.0)
    property real targetLookX: 0.0
    property real targetLookY: 0.0

    width: size
    height: size

    // Warna neon per model (badan selalu putih mengilap seperti di portofolio)
    readonly property var neonColors: {
        "white":  "#00f2fe",
        "strobi": "#5b8cff",
        "nova":   "#2dd4bf",
        "citrus": "#ffcf24",
        "kirby":  "#ff7ac8",
        "amber":  "#ff9a3c",
        "green":  "#22e57a",
        "grok":   "#e5e7eb",
        "freddy": "#ff8a5c",
        "mochi":  "#00f2fe"
    }

    property color neonColor: {
        if (expression === "angry") return "#ff3b4e";
        if (expression === "celebrate") return "#4ade80";
        return neonColors[avatarType] || neonColors["white"];
    }
    Behavior on neonColor { ColorAnimation { duration: 250 } }

    readonly property bool happyMood: expression === "happy" || expression === "wave"
                                      || expression === "dance" || expression === "celebrate"
    readonly property bool hoverMood: expression === "happy" || expression === "wave" || expression === "dance"

    // Setara SphereGeometry three.js dengan phi/theta parsial
    function spherePatch(r, ws, hs, phiStart, phiLength, thetaStart, thetaLength) {
        const positions = [], normals = [], indexes = [];
        for (let iy = 0; iy <= hs; iy++) {
            const theta = thetaStart + (iy / hs) * thetaLength;
            for (let ix = 0; ix <= ws; ix++) {
                const phi = phiStart + (ix / ws) * phiLength;
                const n = Qt.vector3d(-Math.cos(phi) * Math.sin(theta), Math.cos(theta), Math.sin(phi) * Math.sin(theta));
                normals.push(n);
                positions.push(n.times(r));
            }
        }
        for (let iy = 0; iy < hs; iy++) {
            for (let ix = 0; ix < ws; ix++) {
                const a = iy * (ws + 1) + ix + 1, b = iy * (ws + 1) + ix;
                const c = (iy + 1) * (ws + 1) + ix, d = (iy + 1) * (ws + 1) + ix + 1;
                indexes.push(a, b, d, b, c, d);
            }
        }
        return { positions: positions, normals: normals, indexes: indexes };
    }

    // Setara TorusGeometry three.js dengan arc parsial (bidang XY)
    function torusArc(radius, tube, radialSegs, tubularSegs, arc) {
        const positions = [], normals = [], indexes = [];
        for (let j = 0; j <= radialSegs; j++) {
            const v = (j / radialSegs) * Math.PI * 2;
            for (let i = 0; i <= tubularSegs; i++) {
                const u = (i / tubularSegs) * arc;
                const p = Qt.vector3d((radius + tube * Math.cos(v)) * Math.cos(u), (radius + tube * Math.cos(v)) * Math.sin(u), tube * Math.sin(v));
                positions.push(p);
                normals.push(p.minus(Qt.vector3d(radius * Math.cos(u), radius * Math.sin(u), 0)).normalized());
            }
        }
        for (let j = 1; j <= radialSegs; j++) {
            for (let i = 1; i <= tubularSegs; i++) {
                const a = (tubularSegs + 1) * j + i - 1, b = (tubularSegs + 1) * (j - 1) + i - 1;
                const c = (tubularSegs + 1) * (j - 1) + i, d = (tubularSegs + 1) * j + i;
                indexes.push(a, b, d, b, c, d);
            }
        }
        return { positions: positions, normals: normals, indexes: indexes };
    }

    // Reaksi klik: putar 360°, pantulan squash, kilat glow, gelombang cincin
    function poke() {
        anim.spinTarget += 360;
        anim.squashVel += 5;
        anim.flash = 1;
        anim.waveAge = 0;
    }

    onExpressionChanged: if (expression === "task_start" || expression === "celebrate") poke()

    // Status animasi; di-step setiap frame oleh FrameAnimation di bawah
    QtObject {
        id: anim
        property real t: 0
        property real hover: 0
        property real happy: 0
        property real spinTarget: 0
        property real squash: 0
        property real squashVel: 0
        property real flash: 0
        property real waveAge: 99
        property real nextBlink: 2 + Math.random() * 3
        property real blinkAge: 99
        property real rotX: 0
        property real rotY: 0
        property real rotZ: 0
    }

    FrameAnimation {
        running: avatarRoot.visible
        onTriggered: {
            const dt = Math.min(frameTime, 0.05);
            const a = anim;
            const expr = avatarRoot.expression;
            a.t += dt;
            const t = a.t;
            const ease = Math.min(1, dt * 10);

            a.hover += ((avatarRoot.hoverMood ? 1 : 0) - a.hover) * ease;
            a.happy += ((avatarRoot.happyMood ? 1 : 0) - a.happy) * ease;

            // Pegas squash: kaku dan sedikit underdamped, jadi memantul
            a.squashVel += (-260 * a.squash - 11 * a.squashVel) * dt;
            a.squash += a.squashVel * dt;
            a.flash = Math.max(0, a.flash - dt * 2.2);

            // Melayang + skala
            const sleepy = expr === "sleepy";
            const bob = Math.sin(t * (sleepy ? 1.2 : 2.6)) * (sleepy ? 0.05 : 0.12);
            floatNode.y = bob + a.hover * 0.06;
            const s = 1 + a.hover * 0.1;
            floatNode.scale = Qt.vector3d(s * (1 + a.squash * 0.5), s * (1 - a.squash * 0.6), s * (1 + a.squash * 0.5));

            // Menghadap kursor, plus putaran dan kepala miring
            let tilt = a.hover * (0.16 + Math.sin(t * 5) * 0.05);
            const dizzy = expr === "dizzy";
            if (dizzy) tilt = Math.sin(t * 6) * 0.28;
            else if (sleepy) tilt = 0.18;
            else if (expr === "working") tilt = -0.1;
            const lookDown = expr === "working" ? 0.25 : (sleepy ? 0.2 : 0);
            const k = Math.min(1, dt * 8);
            a.rotY += (avatarRoot.targetLookX * 31 + a.spinTarget - a.rotY) * k;
            const swirlX = dizzy ? Math.cos(t * 6) * 14 : 0;
            a.rotX += ((avatarRoot.targetLookY + lookDown) * 18 - a.hover * 7 + swirlX - a.rotX) * k;
            a.rotZ += (tilt * 57.3 - a.rotZ) * k;
            bot.eulerRotation = Qt.vector3d(a.rotX, a.rotY, a.rotZ);

            // Antena: goyang malas, bergetar heboh saat hover
            antenna.eulerRotation.z = (Math.sin(t * 1.8) * 0.06 + Math.sin(t * 16) * 0.22 * a.hover - a.squash * 0.8) * 57.3;

            // Glow: bernapas + boost hover + kilat klik
            const dim = sleepy ? 0.5 : 1;
            const glow = (1.4 + Math.sin(t * 2.2) * 0.25 + a.hover * 0.9 + a.flash * 2.5) * dim;
            const c = avatarRoot.neonColor;
            neonMat.emissiveFactor = Qt.vector3d(c.r * glow * 0.55, c.g * glow * 0.55, c.b * glow * 0.55);
            tip.scale = Qt.vector3d(1, 1, 1).times(1 + Math.sin(t * (expr === "working" ? 9 : 4)) * 0.12 + a.flash * 0.5);
            rimLight.brightness = (14 + a.hover * 10 + a.flash * 30) * 0.12;

            // Mata: berkedip saat idle, berubah jadi ^ ^ saat senang / klik
            const happy = Math.min(1, a.happy + a.flash);
            a.blinkAge += dt;
            if (t > a.nextBlink && happy < 0.5) {
                a.blinkAge = 0;
                a.nextBlink = t + 2.5 + Math.random() * 3.5;
            }
            const blink = a.blinkAge < 0.16 ? Math.sin((a.blinkAge / 0.16) * Math.PI) : 0;
            let lid = 1;
            if (sleepy) lid = 0.12;
            else if (expr === "working") lid = 0.6;
            else if (expr === "angry") lid = 0.55;
            const open = (1 - happy) * (1 - blink * 0.92) * lid;
            const eyeAngle = expr === "angry" ? 28 : (expr === "sweat" ? -14 : 0);
            for (let i = 0; i < 2; i++) {
                const side = i === 0 ? -1 : 1;
                const eye = i === 0 ? eyeL : eyeR;
                const arc = i === 0 ? happyL : happyR;
                eye.scale = Qt.vector3d(0.85, 1.35 * Math.max(open, 0.001), 0.45);
                eye.visible = open > 0.02;
                eye.eulerRotation.z = -side * eyeAngle;
                // Pusing: mata berputar kecil berlawanan arah
                const orbit = dizzy ? 0.06 : 0;
                eye.x = side * 0.25 + Math.cos(t * 12 * side) * orbit;
                eye.y = 0.08 + Math.sin(t * 12 * side) * orbit;
                arc.scale = Qt.vector3d(1, 1, 1).times(Math.max(happy, 0.001));
                arc.visible = happy > 0.02;
            }

            // Bintang mengitari kepala saat pusing
            dizzyStars.visible = dizzy;
            if (dizzy) {
                for (let i = 0; i < 3; i++) {
                    const ang = t * 4 + i * Math.PI * 2 / 3;
                    const star = dizzyStars.children[i];
                    star.x = Math.cos(ang) * 0.85;
                    star.z = Math.sin(ang) * 0.5;
                    star.y = Math.sin(ang * 2) * 0.06;
                    star.eulerRotation.z = t * 300;
                }
            }

            // Gelombang cincin saat klik
            if (a.waveAge < 0.7) {
                a.waveAge += dt;
                const p = Math.min(1, a.waveAge / 0.7);
                wave.visible = true;
                wave.y = floatNode.y;
                wave.scale = Qt.vector3d(1, 1, 1).times(0.9 + p * 0.75);
                waveMat.opacity = (1 - p) * 0.85;
            } else {
                wave.visible = false;
            }
        }
    }

    // Goyang (dance), napas (sleepy), melambai, hentakan, getar — di level 2D
    Item {
        id: bodyContainer
        anchors.fill: parent

        transform: [
            Rotation { id: swayRot; origin.x: avatarRoot.size / 2; origin.y: avatarRoot.size; angle: 0 },
            Scale { id: breathScale; origin.x: avatarRoot.size / 2; origin.y: avatarRoot.size; xScale: 1; yScale: 1 }
        ]

        SequentialAnimation {
            running: avatarRoot.expression === "dance"
            loops: Animation.Infinite
            onRunningChanged: if (!running) swayRot.angle = 0
            NumberAnimation { target: swayRot; property: "angle"; to: -11; duration: 260; easing.type: Easing.InOutSine }
            NumberAnimation { target: swayRot; property: "angle"; to: 11; duration: 520; easing.type: Easing.InOutSine }
            NumberAnimation { target: swayRot; property: "angle"; to: 0; duration: 260; easing.type: Easing.InOutSine }
        }

        SequentialAnimation {
            running: avatarRoot.expression === "sleepy"
            loops: Animation.Infinite
            onRunningChanged: if (!running) breathScale.yScale = 1
            NumberAnimation { target: breathScale; property: "yScale"; to: 0.93; duration: 1400; easing.type: Easing.InOutSine }
            NumberAnimation { target: breathScale; property: "yScale"; to: 1.0; duration: 1400; easing.type: Easing.InOutSine }
        }

        SequentialAnimation on rotation {
            running: avatarRoot.expression === "wave"
            loops: Animation.Infinite
            NumberAnimation { to: -14; duration: 130; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 14; duration: 130; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 0; duration: 100; easing.type: Easing.InOutQuad }
        }

        SequentialAnimation on x {
            running: avatarRoot.expression === "angry"
            loops: Animation.Infinite
            NumberAnimation { to: -1.8; duration: 45 }
            NumberAnimation { to: 1.8; duration: 45 }
            NumberAnimation { to: 0; duration: 45 }
        }

        SequentialAnimation on y {
            running: avatarRoot.expression === "celebrate"
            loops: 4
            NumberAnimation { to: -4; duration: 120; easing.type: Easing.OutQuad }
            NumberAnimation { to: 0; duration: 120; easing.type: Easing.InQuad }
        }

        View3D {
            id: view
            anchors.fill: parent

            environment: SceneEnvironment {
                backgroundMode: SceneEnvironment.Transparent
                antialiasingMode: SceneEnvironment.MSAA
                antialiasingQuality: SceneEnvironment.High
                // Pantulan studio lembut (pengganti RoomEnvironment three.js)
                lightProbe: Texture { textureData: ProceduralSkyTextureData {} }
                probeExposure: 0.6
            }

            // Glow neon di sekitar robot (pengganti drop-shadow CSS)
            layer.enabled: true
            layer.effect: MultiEffect {
                autoPaddingEnabled: true
                shadowEnabled: true
                shadowColor: Qt.alpha(avatarRoot.neonColor, 0.55)
                shadowBlur: 0.6
                shadowHorizontalOffset: 0
                shadowVerticalOffset: avatarRoot.size * 0.03
            }

            PerspectiveCamera {
                position: Qt.vector3d(0, 0.22, 4.6)
                fieldOfView: 38
                clipNear: 0.1
                clipFar: 50
            }

            DirectionalLight {
                eulerRotation: Qt.vector3d(-42, 30, 0)
                brightness: 1.6
            }
            // Pengisi lembut dari depan (pengganti AmbientLight + environment map)
            DirectionalLight {
                eulerRotation: Qt.vector3d(10, -20, 0)
                brightness: 0.75
            }
            PointLight {
                id: rimLight
                position: Qt.vector3d(-1.8, 1.2, -2.2)
                color: avatarRoot.neonColor
                brightness: 1.7
                quadraticFade: 0.3
            }

            PrincipledMaterial {
                id: bodyMat
                baseColor: "#f8fafc"
                roughness: 0.25
                clearcoatAmount: 1
                clearcoatRoughnessAmount: 0.08
            }
            PrincipledMaterial {
                id: visorMat
                baseColor: "#050811"
                roughness: 0.05
                metalness: 0.2
                clearcoatAmount: 1
                clearcoatRoughnessAmount: 0.02
                cullMode: Material.NoCulling
            }
            PrincipledMaterial {
                id: metalMat
                baseColor: "#9aa4b2"
                roughness: 0.3
                metalness: 0.9
            }
            PrincipledMaterial {
                id: neonMat
                baseColor: avatarRoot.neonColor
                emissiveFactor: Qt.vector3d(0, 1, 1)
                cullMode: Material.NoCulling
            }
            PrincipledMaterial {
                id: starMat
                baseColor: "#ffd84d"
                emissiveFactor: Qt.vector3d(1, 0.85, 0.3)
            }
            PrincipledMaterial {
                id: waveMat
                baseColor: avatarRoot.neonColor
                lighting: PrincipledMaterial.NoLighting
                alphaMode: PrincipledMaterial.Blend
                depthDrawMode: Material.NeverDepthDraw
                opacity: 0
            }

            // floatNode: melayang + skala hover / squash. bot: rotasi (kursor, putar, miring).
            Node {
                id: floatNode

                Node {
                    id: bot

                    Model {
                        geometry: SphereGeometry { radius: 1.05; rings: 32; segments: 48 }
                        materials: bodyMat
                    }

                    // Potongan bola yang sedikit lebih besar, berpusat di +Z, jadi visor
                    Model {
                        geometry: ProceduralMesh {
                            property var mesh: avatarRoot.spherePatch(1.07, 48, 32, Math.PI / 2 - 0.62, 1.24, Math.PI / 2 - 0.42, 0.84)
                            positions: mesh.positions
                            normals: mesh.normals
                            indexes: mesh.indexes
                        }
                        materials: visorMat
                    }

                    // Cincin "Q" + ekornya
                    Model {
                        z: 0.72
                        eulerRotation.x: 90
                        geometry: TorusGeometry { radius: 0.76; tubeRadius: 0.1; rings: 72; segments: 20 }
                        materials: neonMat
                    }
                    Model {
                        position: Qt.vector3d(0.7, -0.7, 0.4)
                        eulerRotation.z: -45
                        geometry: ConeGeometry { topRadius: 0.13; bottomRadius: 0.19; length: 0.9; segments: 24 }
                        materials: neonMat
                    }

                    // Mata normal (kedip = squash Y)
                    Model {
                        id: eyeL
                        position: Qt.vector3d(-0.25, 0.08, 1.07)
                        geometry: eyeGeo
                        materials: neonMat
                    }
                    Model {
                        id: eyeR
                        position: Qt.vector3d(0.25, 0.08, 1.07)
                        geometry: eyeGeo
                        materials: neonMat
                    }
                    SphereGeometry { id: eyeGeo; radius: 0.12; rings: 16; segments: 20 }

                    // Mata senang ^ ^: busur torus setengah lingkaran
                    ProceduralMesh {
                        id: arcGeo
                        property var mesh: avatarRoot.torusArc(0.11, 0.038, 10, 24, Math.PI)
                        positions: mesh.positions
                        normals: mesh.normals
                        indexes: mesh.indexes
                    }
                    Model {
                        id: happyL
                        position: Qt.vector3d(-0.25, 0.02, 1.08)
                        geometry: arcGeo
                        materials: neonMat
                    }
                    Model {
                        id: happyR
                        position: Qt.vector3d(0.25, 0.02, 1.08)
                        geometry: arcGeo
                        materials: neonMat
                    }

                    // Antena
                    Node {
                        id: antenna
                        y: 0.98
                        Model {
                            y: 0.2
                            geometry: ConeGeometry { topRadius: 0.035; bottomRadius: 0.05; length: 0.42; segments: 12 }
                            materials: metalMat
                        }
                        Model {
                            id: tip
                            y: 0.46
                            geometry: SphereGeometry { radius: 0.095; rings: 14; segments: 20 }
                            materials: neonMat
                        }
                    }

                    // Pod telinga + cincin glow
                    Repeater3D {
                        model: [-1, 1]
                        delegate: Node {
                            required property int modelData
                            Model {
                                x: modelData * 1.04
                                eulerRotation.z: 90
                                geometry: CylinderGeometry { radius: 0.21; length: 0.16; segments: 28 }
                                materials: metalMat
                            }
                            Model {
                                x: modelData * 1.13
                                eulerRotation.y: 90
                                geometry: TorusGeometry { radius: 0.16; tubeRadius: 0.025; rings: 32; segments: 10 }
                                materials: neonMat
                            }
                        }
                    }
                }
            }

            Node {
                id: dizzyStars
                y: 1.3
                visible: false
                Model { geometry: starGeo; materials: starMat }
                Model { geometry: starGeo; materials: starMat }
                Model { geometry: starGeo; materials: starMat }
            }
            CuboidGeometry { id: starGeo; xExtent: 0.16; yExtent: 0.16; zExtent: 0.16 }

            Model {
                id: wave
                z: 0.4
                visible: false
                eulerRotation.x: 90
                geometry: TorusGeometry { radius: 1.1; tubeRadius: 0.035; rings: 80; segments: 8 }
                materials: waveMat
            }
        }
    }

    // "z" melayang saat mengantuk (dua huruf, bergantian)
    Repeater {
        model: avatarRoot.expression === "sleepy" ? 2 : 0
        Text {
            id: zText
            required property int index
            text: "z"
            color: "#c7d2fe"
            font.pixelSize: Math.max(7, avatarRoot.size * (0.26 + index * 0.08))
            font.bold: true
            x: avatarRoot.size * (0.8 + index * 0.12)
            opacity: 0
            SequentialAnimation {
                running: true
                loops: Animation.Infinite
                PauseAnimation { duration: zText.index * 900 }
                ParallelAnimation {
                    NumberAnimation { target: zText; property: "y"; from: avatarRoot.size * 0.15; to: -avatarRoot.size * 0.35; duration: 1800; easing.type: Easing.OutSine }
                    SequentialAnimation {
                        NumberAnimation { target: zText; property: "opacity"; from: 0; to: 1; duration: 500 }
                        NumberAnimation { target: zText; property: "opacity"; to: 0; duration: 1300 }
                    }
                }
                PauseAnimation { duration: (1 - zText.index) * 900 }
            }
        }
    }

    // Tetes keringat saat sistem kepanasan (CPU tinggi)
    Canvas {
        id: sweatDrop
        visible: avatarRoot.expression === "sweat"
        width: Math.max(5, avatarRoot.size * 0.16)
        height: width * 1.4
        x: avatarRoot.size * 0.8
        y: avatarRoot.size * 0.05
        onPaint: {
            let ctx = getContext("2d");
            ctx.reset();
            ctx.fillStyle = "#7dd3fc";
            ctx.beginPath();
            ctx.moveTo(width / 2, 0);
            ctx.quadraticCurveTo(width, height * 0.6, width / 2, height);
            ctx.quadraticCurveTo(0, height * 0.6, width / 2, 0);
            ctx.fill();
        }
        SequentialAnimation {
            running: sweatDrop.visible
            loops: Animation.Infinite
            ParallelAnimation {
                NumberAnimation { target: sweatDrop; property: "y"; from: avatarRoot.size * 0.02; to: avatarRoot.size * 0.42; duration: 1100; easing.type: Easing.InQuad }
                NumberAnimation { target: sweatDrop; property: "opacity"; from: 1; to: 0; duration: 1100; easing.type: Easing.InQuad }
            }
            PauseAnimation { duration: 400 }
        }
    }
}
