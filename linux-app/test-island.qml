import QtQuick
import Quickshell
import Quickshell.Wayland

PanelWindow {
    id: win
    anchors {
        top: true
    }
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "coucou-island"
    width: 320
    height: 48
    color: "transparent"

    Rectangle {
        id: island
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: 260
        height: 40
        radius: 20
        color: "#0d0f12"
        border.color: "#33ffffff"
        border.width: 1

        Row {
            anchors.centerIn: parent
            spacing: 12

            Rectangle {
                width: 20
                height: 20
                radius: 10
                color: "#22c55e"
                anchors.verticalCenter: parent.verticalCenter
            }

            Text {
                text: "✨ Hermes Mochi Active"
                color: "#ffffff"
                font.pixelSize: 13
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
