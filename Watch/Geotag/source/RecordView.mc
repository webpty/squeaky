import Toybox.Activity;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

// The one page while recording, laid out like David's fenix watch face (Watch 0.2.3):
// six fields round the edge inside a purple ring, three in the middle.
// To change the page, change these two lists.
module Layout {
    // Top, top right, bottom right, bottom, bottom left, top left.
    const AROUND = [:battery, :steps, :altitude, :time, :gps, :heartRate];
    // Large in the middle, then below it on the left and on the right.
    const MIDDLE = [:elapsed, :distance, :pace];

    const RING = 0x7755CC;
    const TICK = 0xAA88FF;
    // Where each side field is centred, degrees counter-clockwise from 3 o'clock.
    const SIDE_ANGLES = [31, -31, 211, 149];
}

class RecordView extends WatchUi.View {
    private var timer as Timer.Timer?;
    private var edgeFont as Graphics.VectorFont?;
    private var lowerFonts as Array<Graphics.VectorFont?> = [] as Array<Graphics.VectorFont?>;

    function initialize() {
        View.initialize();
    }

    function onLayout(dc as Dc) as Void {
        var w = dc.getWidth();
        edgeFont = Ring.font((w * 0.073).toNumber());
        lowerFonts = [Ring.font((w * 0.085).toNumber()), Ring.font((w * 0.073).toNumber()), Ring.font((w * 0.062).toNumber())];
    }

    function onShow() as Void {
        var r = app().recorder;
        if (r.state == Recorder.IDLE) {
            // Saved or discarded from the menu.
            if (r.saved) {
                WatchUi.switchToView(new SendView(r.trackId), new SendDelegate(false), WatchUi.SLIDE_IMMEDIATE);
            } else {
                WatchUi.switchToView(new ReadyView(), new ReadyDelegate(), WatchUi.SLIDE_IMMEDIATE);
            }
            return;
        }
        timer = new Timer.Timer();
        timer.start(method(:onTick), 1000, true);
    }

    function onHide() as Void {
        if (timer != null) { timer.stop(); }
    }

    function onTick() as Void {
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Dc) as Void {
        var info = Activity.getActivityInfo();
        if (Draw.lowPower()) {
            Draw.lowPowerPage(dc, Fields.elapsed(info));
            return;
        }
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;
        var R = w / 2;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var rr = (R * 0.755).toNumber();
        Ring.draw(dc, cx, cy, rr);

        var font = edgeFont;
        if (font != null) {
            var rt = (R * 0.88).toNumber();
            var straightY = (R * 0.85).toNumber();
            // Top and bottom, straight.
            Ring.straight(dc, cx, cy - straightY, font, Layout.AROUND[0], info);
            Ring.straight(dc, cx, cy + straightY, font, Layout.AROUND[3], info);
            // The four sides, along the edge.
            var sides = [Layout.AROUND[1], Layout.AROUND[2], Layout.AROUND[4], Layout.AROUND[5]];
            for (var i = 0; i < 4; i++) {
                var a = Layout.SIDE_ANGLES[i];
                var dir = a > 0 && a < 180 ? Graphics.RADIAL_TEXT_DIRECTION_CLOCKWISE : Graphics.RADIAL_TEXT_DIRECTION_COUNTER_CLOCKWISE;
                Ring.curved(dc, cx, cy, rt, a, dir, font, sides[i], info);
            }
        }

        // The middle: elapsed large, distance and pace below it.
        var paused = app().recorder.state == Recorder.PAUSED;
        var big = Fields.value(Layout.MIDDLE[0], info)[1];
        var bigFont = Graphics.FONT_NUMBER_MEDIUM;
        if (dc.getTextWidthInPixels(big, bigFont) > rr * 1.8) { bigFont = Graphics.FONT_NUMBER_MILD; }
        dc.setColor(paused ? Graphics.COLOR_YELLOW : Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, cy - (R * 0.06).toNumber(), bigFont, big, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        var left = Fields.value(Layout.MIDDLE[1], info)[1];
        var right = Fields.value(Layout.MIDDLE[2], info)[1];
        var room = (R * 0.64).toNumber();
        var lower = Ring.fitting(dc, lowerFonts, [left, right], room);
        var y = cy + (R * 0.30).toNumber();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        if (lower != null) {
            dc.drawText(cx - (R * 0.34).toNumber(), y, lower, left, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(cx + (R * 0.34).toNumber(), y, lower, right, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }
}

// The purple ring, the edge fields and their icons.
module Ring {
    function font(size as Number) as Graphics.VectorFont? {
        if (!(Graphics has :getVectorFont)) { return null; }
        var lang = System.getDeviceSettings().systemLanguage;
        var faces = lang == System.LANGUAGE_CHT || lang == System.LANGUAGE_CHS
            ? ["NotoSansSCMedium", "RobotoCondensedBold"]
            : ["RobotoCondensedBold", "RobotoMedium", "RobotoRegular"];
        return Graphics.getVectorFont({ :face => faces, :size => size });
    }

    // The largest of the fonts in which every text fits the room.
    function fitting(dc as Dc, fonts as Array<Graphics.VectorFont?>, texts as Array<String>, room as Number) as Graphics.VectorFont? {
        var last = null;
        for (var i = 0; i < fonts.size(); i++) {
            var f = fonts[i];
            if (f == null) { continue; }
            last = f;
            var fits = true;
            for (var j = 0; j < texts.size(); j++) {
                if (dc.getTextWidthInPixels(texts[j], f) > room) { fits = false; }
            }
            if (fits) { return f; }
        }
        return last;
    }

    function point(cx as Number, cy as Number, r as Numeric, deg as Numeric) as [Numeric, Numeric] {
        var a = Math.toRadians(deg);
        return [cx + r * Math.cos(a), cy - r * Math.sin(a)];
    }

    // The ring on both sides, the dividers, and the frames at top and bottom.
    function draw(dc as Dc, cx as Number, cy as Number, rr as Number) as Void {
        dc.setColor(Layout.RING, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(4);
        dc.drawArc(cx, cy, rr, Graphics.ARC_COUNTER_CLOCKWISE, -62, 62);
        dc.drawArc(cx, cy, rr, Graphics.ARC_COUNTER_CLOCKWISE, 118, 242);
        var inner = (rr * 0.74).toNumber();
        var half = (rr * 0.34).toNumber();
        for (var s = -1; s <= 1; s += 2) {
            var p1 = point(cx, cy, rr, s < 0 ? 118 : 242);
            var p2 = point(cx, cy, rr, s < 0 ? 62 : -62);
            var y = cy + s * inner;
            dc.drawLine(p1[0], p1[1], cx - half, y);
            dc.drawLine(cx - half, y, cx + half, y);
            dc.drawLine(cx + half, y, p2[0], p2[1]);
        }
        dc.setColor(Layout.TICK, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(7);
        var ticks = [0, 62, 118, 180, 242, 298];
        for (var i = 0; i < ticks.size(); i++) {
            var a = point(cx, cy, rr - 12, ticks[i]);
            var b = point(cx, cy, rr + 12, ticks[i]);
            dc.drawLine(a[0], a[1], b[0], b[1]);
        }
        dc.setPenWidth(1);
    }

    // "BATT 89%": the label in capitals, then the value.
    function line(field as Symbol, info as Activity.Info?) as String {
        var f = Fields.value(field, info);
        return f[0].length() > 0 ? f[0].toUpper() + " " + f[1].toUpper() : f[1].toUpper();
    }

    function colour(field as Symbol) as Number {
        return field == :heartRate ? Graphics.COLOR_RED : Graphics.COLOR_WHITE;
    }

    function straight(dc as Dc, x as Number, y as Number, font as Graphics.VectorFont, field as Symbol, info as Activity.Info?) as Void {
        dc.setColor(colour(field), Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, font, line(field, info), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }

    // A side field along the edge; the heart and the shoe go before the value.
    function curved(dc as Dc, cx as Number, cy as Number, rt as Number, centre as Number, dir as Graphics.RadialTextDirection,
                    font as Graphics.VectorFont, field as Symbol, info as Activity.Info?) as Void {
        var text = line(field, info);
        var icon = field == :heartRate || field == :steps;
        var size = (rt * 0.13).toNumber();
        var gap = icon ? (size * 0.4).toNumber() : 0;
        var iconW = icon ? size : 0;
        var textW = dc.getTextWidthInPixels(text, font);
        var total = iconW + gap + textW;
        // Clockwise text reads towards smaller angles.
        var sign = dir == Graphics.RADIAL_TEXT_DIRECTION_CLOCKWISE ? -1 : 1;
        var startDeg = centre - sign * Math.toDegrees((total / 2.0) / rt);
        dc.setColor(colour(field), Graphics.COLOR_TRANSPARENT);
        if (icon) {
            var iconDeg = startDeg + sign * Math.toDegrees((iconW / 2.0) / rt);
            if (field == :heartRate) {
                Icons.heart(dc, cx, cy, rt, iconDeg, size);
            } else {
                Icons.shoe(dc, cx, cy, rt, iconDeg, size);
            }
        }
        var textDeg = startDeg + sign * Math.toDegrees((iconW + gap + textW / 2.0) / rt);
        dc.drawRadialText(cx, cy, font, text, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER, textDeg, rt, dir);
    }
}

// Small filled icons, turned to sit upright along the top of the ring.
module Icons {
    // Local points (x right, y down, about 1 unit across) placed at an angle on the circle.
    function place(cx as Number, cy as Number, r as Number, deg as Numeric, size as Number, pts as Array) as Array<[Numeric, Numeric]> {
        var a = Math.toRadians(deg);
        var c = Math.cos(a);
        var s = Math.sin(a);
        var ox = cx + r * c;
        var oy = cy - r * s;
        var out = [] as Array<[Numeric, Numeric]>;
        for (var i = 0; i < pts.size(); i++) {
            var lx = pts[i][0] * size;
            var ly = pts[i][1] * size;
            out.add([ox + lx * s - ly * c, oy + lx * c + ly * s]);
        }
        return out;
    }

    function heart(dc as Dc, cx as Number, cy as Number, r as Number, deg as Numeric, size as Number) as Void {
        var pts = [];
        for (var i = 0; i < 28; i++) {
            var t = Math.PI * 2 * i / 28;
            var st = Math.sin(t);
            var x = 16 * st * st * st;
            var y = -(13 * Math.cos(t) - 5 * Math.cos(2 * t) - 2 * Math.cos(3 * t) - Math.cos(4 * t));
            pts.add([x / 34.0, (y + 2.5) / 34.0]);
        }
        dc.fillPolygon(place(cx, cy, r, deg, size, pts));
    }

    // A trainer seen from the side, toe to the right.
    function shoe(dc as Dc, cx as Number, cy as Number, r as Number, deg as Numeric, size as Number) as Void {
        var pts = [
            [-0.50, 0.30], [0.50, 0.30], [0.50, 0.16], [0.42, 0.06], [0.14, -0.02],
            [0.00, -0.14], [-0.10, -0.32], [-0.36, -0.32], [-0.44, -0.20], [-0.50, 0.02]
        ];
        dc.fillPolygon(place(cx, cy, r, deg, size, pts));
    }
}

class RecordDelegate extends WatchUi.BehaviorDelegate {
    function initialize() {
        BehaviorDelegate.initialize();
    }

    // Start pauses and opens the stop menu.
    function onKey(evt as WatchUi.KeyEvent) as Boolean {
        if (evt.getKey() == WatchUi.KEY_ENTER) {
            app().recorder.pause();
            StopMenu.show();
            return true;
        }
        return BehaviorDelegate.onKey(evt);
    }

    // Back never closes the app mid-hike.
    function onBack() as Boolean {
        return true;
    }
}

// Each field as [label, value].
module Fields {
    function text(id as ResourceId) as String {
        return WatchUi.loadResource(id) as String;
    }

    function value(field as Symbol, info as Activity.Info?) as [String, String] {
        var statute = System.getDeviceSettings().distanceUnits == System.UNIT_STATUTE;
        if (field == :time) {
            return [text(Rez.Strings.Time), Draw.clock()];
        }
        if (field == :heartRate) {
            var hr = info != null ? info.currentHeartRate : null;
            return ["", hr != null ? hr.toString() : "--"];
        }
        if (field == :steps) {
            var n = app().recorder.steps();
            return ["", n < 1000 ? n.toString() : (n / 1000.0).format("%.1f") + "K"];
        }
        if (field == :battery) {
            return [text(Rez.Strings.Battery), System.getSystemStats().battery.format("%d") + "%"];
        }
        if (field == :altitude) {
            var alt = info != null ? info.altitude : null;
            if (alt == null) { return [text(Rez.Strings.Altitude), "--"]; }
            var feet = System.getDeviceSettings().elevationUnits == System.UNIT_STATUTE;
            return [text(Rez.Strings.Altitude), feet ? (alt * 3.28084).format("%d") + " ft" : alt.format("%d") + " m"];
        }
        if (field == :gps) {
            return [text(Rez.Strings.Gps), app().gps.word()];
        }
        if (field == :elapsed) {
            return ["", elapsed(info)];
        }
        if (field == :distance) {
            var m = info != null && info.elapsedDistance != null ? info.elapsedDistance as Float : 0.0;
            return ["", statute ? (m / 1609.344).format("%.2f") + " mi" : (m / 1000).format("%.2f") + " km"];
        }
        if (field == :pace) {
            var v = info != null && info.currentSpeed != null ? info.currentSpeed as Float : 0.0;
            var unit = statute ? 1609.344 : 1000.0;
            if (v < 0.3) { return ["", "--:-- " + (statute ? "/mi" : "/km")]; }
            var s = (unit / v).toNumber();
            if (s > 5999) { return ["", "--:-- " + (statute ? "/mi" : "/km")]; }
            return ["", (s / 60) + ":" + (s % 60).format("%02d") + (statute ? " /mi" : " /km")];
        }
        return ["", ""];
    }

    function elapsed(info as Activity.Info?) as String {
        var ms = info != null && info.timerTime != null ? info.timerTime as Number : 0;
        var s = ms / 1000;
        return (s / 3600) + ":" + ((s % 3600) / 60).format("%02d") + ":" + (s % 60).format("%02d");
    }
}
