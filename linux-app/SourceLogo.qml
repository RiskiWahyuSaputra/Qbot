import QtQuick

// Logo sumber event: "hermes" | "claude" | "opencode" (aset di linux-app/assets).
// Gaya lencana bulat: badan bergradasi lembut + sorot tipis di tepi atas,
// glyph dirender pada resolusi layar agar tetap tajam di ukuran kecil.
Item {
    id: logoItem
    property string kind: "hermes"
    property int size: 16
    width: size
    height: size

    readonly property bool isHermes: kind === "hermes"
    readonly property bool isClaude: kind === "claude"
    // Porsi glyph terhadap lencana; glyph OpenCode punya padding bawaan di SVG-nya.
    readonly property real glyphRatio: isHermes ? 1.0 : (isClaude ? 0.68 : 0.74)

    // Claude: starburst krem di atas terakota. OpenCode: glyph putih di atas grafit.
    Rectangle {
        anchors.fill: parent
        radius: width / 2
        visible: !logoItem.isHermes
        gradient: Gradient {
            GradientStop { position: 0.0; color: logoItem.isClaude ? "#e8906f" : "#34343b" }
            GradientStop { position: 1.0; color: logoItem.isClaude ? "#c25d3b" : "#121215" }
        }
    }

    Image {
        anchors.centerIn: parent
        width: Math.round(logoItem.size * logoItem.glyphRatio)
        height: width
        source: logoItem.kind ? Qt.resolvedUrl("assets/" + (logoItem.isHermes ? "hermes.png" : logoItem.kind + ".svg")) : ""
        sourceSize: Qt.size(width * 4, height * 4)
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
    }

    // Sorot tepi: garis halus terang di atas, meredup ke bawah (kesan kaca/enamel).
    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: "transparent"
        border.width: logoItem.size >= 20 ? 1.5 : 1
        border.color: logoItem.isHermes ? Qt.rgba(1, 1, 1, 0.22)
                    : (logoItem.isClaude ? Qt.rgba(1, 0.86, 0.78, 0.45) : Qt.rgba(1, 1, 1, 0.16))
    }
}
