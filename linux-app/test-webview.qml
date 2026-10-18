import QtQuick
import Quickshell
import Quickshell.Wayland
import QtWebEngine

PanelWindow {
    id: win
    anchors {
        top: true
    }
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "coucou-island-webview"
    width: 700
    height: 350
    color: "transparent"

    WebEngineView {
        anchors.fill: parent
        backgroundColor: "transparent"
        url: "file:///home/kiiyuu/Projects/project-web/hermes-coucou/dist/index.html"
    }
}
