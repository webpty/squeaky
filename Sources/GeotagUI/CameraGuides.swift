import Foundation

extension CameraGuide {
    /// The family's cameras, in the order of the menu. The steps and the
    /// pictures come from each maker's own manual (looked up 18 October 2026);
    /// the names in quotes are the cameras' own, spelt as they spell them.
    public static let all: [CameraGuide] = [r5m2, r7, p950, t3i]

    static let r5m2 = CameraGuide(
        id: "r5m2", name: "Canon EOS R5 Mark II",
        path: "MENU, \"Set-up\" tab, \"Date/Time/Zone\"",
        steps: [
            Step(text: "Press the MENU button.", picture: nil),
            Step(text: "Turn Quick control dial 2 to the \"Set-up\" tab, the wrench.", picture: nil),
            Step(text: "Turn the Main dial to the page that lists \"Date/Time/Zone\".", picture: "step-01.png"),
            Step(text: "Turn Quick control dial 1 to \"Date/Time/Zone\", then press SET.", picture: nil),
            Step(text: "Select \"Time zone\", then press SET.", picture: "step-02.png"),
            Step(text: "Turn Quick control dial 1 to the zone where you are, then press SET.", picture: "step-04.png"),
            Step(text: "Only if your zone is not in the list: press MENU, set \"Time difference\" from UTC, then press SET.",
                 picture: "step-05.png"),
            Step(text: "Select \"OK\", then press SET.", picture: nil),
            Step(text: "Select each date and time field, press SET, turn Quick control dial 1 to the right value, and press SET again.",
                 picture: "step-06.png"),
            Step(text: "Select daylight saving on or off, then press SET.", picture: "step-07.png"),
            Step(text: "Select \"OK\", then press SET.", picture: "step-08.png"),
            Step(text: "Press the MENU button to go back to shooting.", picture: nil),
        ],
        notes: [
            "Set the time zone first: the camera then keeps the right time when only the zone changes later.",
            "Daylight saving on moves the clock one hour ahead; off moves it back.",
            "The date, time and zone can be lost when the camera is kept without its battery, when the battery runs flat, or after a long time in freezing cold. Set them again then.",
        ],
        source: URL(string: "https://cam.start.canon/en/C017/manual/html/UG-07_Set-up_0110.html")!)

    static let r7 = CameraGuide(
        id: "r7", name: "Canon EOS R7",
        path: "MENU, \"Set-up 1\", \"Date/Time/Zone\"",
        steps: [
            Step(text: "Press the MENU button.", picture: nil),
            Step(text: "Press the INFO button until the \"Set-up\" tab, the wrench, is selected.", picture: nil),
            Step(text: "Turn the Main dial to \"Set-up 1\".", picture: "step-01.png"),
            Step(text: "Turn the Quick control dial to \"Date/Time/Zone\", then press the Quick Control/Set button.", picture: nil),
            Step(text: "Select \"Time zone\", then press the Quick Control/Set button.", picture: "step-02.png"),
            Step(text: "Select the zone where you are.", picture: "step-04.png"),
            Step(text: "Only if your zone is not in the list: press MENU and set \"Time difference\" from UTC.", picture: "step-05.png"),
            Step(text: "Select \"OK\".", picture: nil),
            Step(text: "Select each date and time field, press the Quick Control/Set button, set the value, and press the button again.",
                 picture: "step-06.png"),
            Step(text: "Select daylight saving on or off, then press the Quick Control/Set button.", picture: "step-07.png"),
            Step(text: "Select \"OK\".", picture: "step-08.png"),
            Step(text: "Press the MENU button to go back to shooting.", picture: nil),
        ],
        notes: [
            "Set the time zone first: the camera then keeps the right time when only the zone changes later.",
            "Daylight saving on moves the clock one hour ahead; off moves it back.",
            "The date, time and zone can be lost when the camera is kept without its battery, when the battery runs flat, or after a long time in freezing cold. Set them again then.",
        ],
        source: URL(string: "https://cam.start.canon/en/C005/manual/html/UG-08_Set-up_0100.html")!)

    static let p950 = CameraGuide(
        id: "p950", name: "Nikon COOLPIX P950",
        path: "MENU, setup menu, \"Time zone and date\"",
        steps: [
            Step(text: "Press the MENU button.", picture: nil),
            Step(text: "Press ◀ on the multi selector to reach the menu icons on the left.", picture: nil),
            Step(text: "Press ▲ or ▼ to the setup menu, the wrench, then press OK.", picture: nil),
            Step(text: "Press ▲ or ▼ to \"Time zone and date\", then press OK.", picture: nil),
            Step(text: "Select \"Time zone\", then press OK.", picture: "step-01.png"),
            Step(text: "Select \"Home time zone\", or \"Travel destination\" when travelling, then press OK.", picture: "step-02.png"),
            Step(text: "Press ▶.", picture: "step-03.png"),
            Step(text: "Press ◀ or ▶ to the zone where you are. Press ▲ for daylight saving on, ▼ for off. Then press OK.",
                 picture: "step-04.png"),
            Step(text: "Select \"Date and time\", then press OK.", picture: "step-05.png"),
            Step(text: "Press ◀ or ▶ to select a field and ▲ or ▼ to change it. With the minutes selected, press OK.", picture: nil),
            Step(text: "Press the MENU button when finished.", picture: nil),
        ],
        notes: [
            "If the SnapBridge app on a phone is set to sync the time, the camera's own date and time cannot be set: turn that sync off in SnapBridge first.",
            "A small battery inside keeps the clock going for several days without the main battery. When it runs out, the settings go back to their defaults.",
            "The camera's clock drifts more than a watch: compare it now and then, and set it again when it is out.",
        ],
        source: URL(string: "https://onlinemanual.nikonimglib.com/p950/en/pages/08-04.html")!)

    static let t3i = CameraGuide(
        id: "t3i", name: "Canon EOS Rebel T3i",
        path: "MENU, \"Set-up 2\" tab, \"Date/Time\"",
        steps: [
            Step(text: "Press the MENU button.", picture: "step-01.png"),
            Step(text: "Press ◀ or ▶ to the \"Set-up 2\" tab, the second yellow wrench.", picture: "step-02.png"),
            Step(text: "Press ▲ or ▼ to \"Date/Time\", then press SET.", picture: nil),
            Step(text: "Press ◀ or ▶ to select a date or time number, then press SET.", picture: "step-03.png"),
            Step(text: "Press ▲ or ▼ to set it, then press SET. Do the same for each number.", picture: nil),
            Step(text: "Press ◀ or ▶ to \"OK\", then press SET. The clock starts from that moment.", picture: nil),
            Step(text: "Press the MENU button to go back to shooting.", picture: nil),
        ],
        notes: [
            "This camera has no time zone setting: set its clock to the time where you are, and give it the same zone in Geotag, in Settings under Cameras.",
            "The date and time can be lost when the camera is kept without its battery or the battery runs flat. Set them again then.",
        ],
        source: URL(string: "https://asia.canon/en/support/0300472001")!)
}
