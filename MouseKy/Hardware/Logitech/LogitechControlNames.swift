import Foundation

enum LogitechControlNames {
    static func hidppName(for cid: UInt16) -> String {
        cidNameGroups.first(where: { $0.cids.contains(cid) })?.name ??
            String(format: "Button 0x%04X", cid)
    }

    static func buttonSpyName(productID: Int, index: Int) -> String {
        guard let names = buttonSpyNamesByProductID[productID],
              names.indices.contains(index)
        else {
            return "Button \(index + 1)"
        }
        return names[index]
    }

    private static let cidNameGroups: [(name: String, cids: [UInt16])] = [
        ("Left Click", [0x0050]),
        ("Right Click", [0x0051]),
        ("Middle Click", [0x0052]),
        ("Back", [0x0053, 0x0054, 0x0055, 0x00CE]),
        ("Forward", [0x0056, 0x0057, 0x0058, 0x00CF]),
        ("Button 6", [0x0059]),
        ("Wheel Tilt Left", [0x005A, 0x005B]),
        ("Wheel Tilt Right", [0x005C, 0x005D]),
        ("Button 9", [0x005E]),
        ("Button 10", [0x005F]),
        ("Button 11", [0x0060]),
        ("Button 12", [0x0061]),
        ("Button 13", [0x0062]),
        ("Button 14", [0x0063]),
        ("Button 15", [0x0064]),
        ("Button 16", [0x0065]),
        ("Button 17", [0x0066]),
        ("Button 18", [0x0067]),
        ("Button 19", [0x0068]),
        ("Button 20", [0x0069]),
        ("Button 21", [0x006A]),
        ("Button 22", [0x006B]),
        ("Button 23", [0x006C]),
        ("Button 24", [0x006D]),
        ("Show Desktop", [0x006E, 0x00FE]),
        ("Lock Screen", [0x006F]),
        ("Horizontal Scroll", [0x0097]),
        ("Gesture Button", [0x00C3, 0x00D0]),
        ("SmartShift", [0x00C4]),
        ("Virtual Gesture Button", [0x00D7]),
        ("Right Arrow", [0x00EB]),
        ("Left Arrow", [0x00EC]),
        ("DPI Change", [0x00ED]),
        ("DPI Switch", [0x00FD]),
        ("App Switch", [0x00FF])
    ]

    private static let buttonSpyNamesByProductID: [Int: [String]] = [
        0xC08B: [
            "Left Click", "Right Click", "Middle Click", "Back", "Forward",
            "DPI Switch", "DPI Down", "DPI Up", "Wheel Tilt Left",
            "Wheel Tilt Right", "Profile Select"
        ],
        0xC08D: [
            "Left Click", "Right Click", "Middle Click", "Back", "Forward",
            "DPI Switch", "DPI Down", "DPI Up", "Battery Status",
            "Wheel Tilt Right", "Wheel Tilt Left"
        ]
    ]
}
