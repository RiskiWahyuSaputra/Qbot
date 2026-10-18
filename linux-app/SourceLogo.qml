import QtQuick

// Logo sumber event: "hermes" | "claude" | "opencode" (aset di linux-app/assets).
Item {
    id: logoItem
    property string kind: "hermes"
    property int size: 16
    width: size
    height: size

    readonly property bool isHermes: kind === "hermes"

    // Claude: starburst krem di lingkaran oranye (gaya ikon app Claude).
    // OpenCode: glyph putih di lingkaran gelap. Hermes: ikon bulat (wajah).
    Rectangle {
        anchors.fill: parent
        radius: width / 2
        visible: !logoItem.isHermes
        color: logoItem.kind === "claude" ? "#d97757" : "#1c1c20"
        border.color: logoItem.kind === "claude" ? "#e8957a" : "#52525b"
        border.width: 1
    }

    Image {
        id: logoImage
        anchors.centerIn: parent
        width: logoItem.isHermes ? logoItem.size : Math.round(logoItem.size * 0.62)
        height: width
        source: logoItem.kind ? Qt.resolvedUrl("assets/" + (logoItem.isHermes ? "hermes.png" : logoItem.kind + ".svg")) : ""
        sourceSize: Qt.size(width * 3, height * 3)
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
    }

}
