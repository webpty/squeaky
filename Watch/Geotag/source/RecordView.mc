import Toybox.Activity;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Position;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

// The one page while recording: six fields around the dial, three in the middle.
// To change the page, change these two lists.
module Layout {
    // Clockwise from the top.
    const AROUND = [:time, :heartRate, :steps, :altitude, :gps, :battery];
    // Top to bottom.
    const MIDDLE = [:distance, :elapsed, :pace];
}

class RecordView extends WatchUi.View {
    private var timer as Timer.Timer?;

    function initialize() {
        View.initialize();
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
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var r = w * 0.37;
        for (var i = 0; i < Layout.AROUND.size(); i++) {
            var angle = Math.toRadians(-90 + i * 60);
            var x = cx + r * Math.cos(angle);
            var y = cy + r * Math.sin(angle);
            var f = Fields.value(Layout.AROUND[i], info);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, y - 20, Graphics.FONT_XTINY, f[0], Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, y + 8, Graphics.FONT_SMALL, f[1], Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        var paused = app().recorder.state == Recorder.PAUSED;
        var fonts = [Graphics.FONT_MEDIUM, Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_MEDIUM];
        var rows = [cy - 70, cy, cy + 70];
        for (var j = 0; j < Layout.MIDDLE.size(); j++) {
            var f = Fields.value(Layout.MIDDLE[j], info);
            var big = Layout.MIDDLE[j] == :elapsed;
            dc.setColor(big && paused ? Graphics.COLOR_YELLOW : Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, rows[j], fonts[j], f[1], Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
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
            return [text(Rez.Strings.HeartRate), hr != null ? hr.toString() : "--"];
        }
        if (field == :steps) {
            return [text(Rez.Strings.Steps), app().recorder.steps().toString()];
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
