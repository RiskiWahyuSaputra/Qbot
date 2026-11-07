import QtQuick

// Teks UI: render native + hinting penuh jauh lebih tajam di ukuran kecil daripada
// distance field bawaan Qt Quick. Roboto statis dipakai karena font sistem (Roboto
// Flex, font variabel) membuat teks tebal menggumpal. Teks yang di-scale animasi
// tetap memakai Text biasa supaya gerakannya halus.
Text {
    renderType: Text.NativeRendering
    font.family: "Roboto"
    font.weight: Font.Medium
    font.hintingPreference: Font.PreferFullHinting
}
