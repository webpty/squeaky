import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

// Shared drawing: the clock, the low-power page and the sending line.
module Draw {
    function clock() as String {
        var c = System.getClockTime();
        var h = c.hour;
        if (!System.getDeviceSettings().is24Hour) {
            h = h % 12;
            if (h == 0) { h = 12; }
        }
        return h + ":" + c.min.format("%02d");
    }

    function lowPower() as Boolean {
        return (System has :getDisplayMode) && System.getDisplayMode() == System.DISPLAY_MODE_LOW_POWER;
    }

    // Grey on black, a few pixels lit, moved a little every minute against burn-in.
    function lowPowerPage(dc as Dc, second as String?) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        var shift = (System.getClockTime().min % 5) * 4 - 8;
        dc.setColor(0x555555, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2 + shift, h * 0.40 + shift, Graphics.FONT_MEDIUM, clock(), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        if (second != null) {
            dc.drawText(w / 2 + shift, h * 0.58 + shift, Graphics.FONT_SMALL, second, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // "Sending 3 of 12", "Waiting for the phone" or "Received by the phone" for one track.
    function sendLine(id as Number) as String {
        var s = app().sender;
        var st = s.statusOf(id);
        if (st == Sender.RECEIVED) { return WatchUi.loadResource(Rez.Strings.Received) as String; }
        if (st == Sender.SENDING && s.trackId == id) {
            return Lang.format(WatchUi.loadResource(Rez.Strings.Sending) as String, [s.part + 1, s.parts]);
        }
        return WatchUi.loadResource(Rez.Strings.Waiting) as String;
    }

    function sendColour(id as Number) as Number {
        var st = app().sender.statusOf(id);
        if (st == Sender.RECEIVED) { return Graphics.COLOR_GREEN; }
        if (st == Sender.WAITING) { return Graphics.COLOR_ORANGE; }
        return Graphics.COLOR_WHITE;
    }
}

// Opening screen: the GPS loading bar. Start begins the hike.
class ReadyView extends WatchUi.View {
    private var timer as Timer.Timer?;

    function initialize() {
        View.initialize();
    }

    function onShow() as Void {
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
        if (Draw.lowPower()) {
            Draw.lowPowerPage(dc, null);
            return;
        }
        var w = dc.getWidth();
        var h = dc.getHeight();
        var gps = app().gps;
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.13, Graphics.FONT_SMALL, Draw.clock(), Graphics.TEXT_JUSTIFY_CENTER);

        var pct = gps.percent();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.36, Graphics.FONT_NUMBER_MEDIUM, pct + "%", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        var barW = (w * 0.64).toNumber();
        var barH = 18;
        var x = (w - barW) / 2;
        var y = (h * 0.50).toNumber();
        dc.setColor(0x333333, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(x, y, barW, barH, barH / 2);
        if (pct > 0) {
            dc.setColor(pct == 100 ? Graphics.COLOR_GREEN : Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(x, y, barW * pct / 100, barH, barH / 2);
        }

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.58, Graphics.FONT_SMALL, gps.word(), Graphics.TEXT_JUSTIFY_CENTER);

        var s = app().sender;
        var id = s.trackId != null ? s.trackId : s.lastDone;
        if (id != null) {
            dc.setColor(Draw.sendColour(id), Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.78, Graphics.FONT_XTINY, Draw.sendLine(id), Graphics.TEXT_JUSTIFY_CENTER);
        }
    }
}

class ReadyDelegate extends WatchUi.BehaviorDelegate {
    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onKey(evt as WatchUi.KeyEvent) as Boolean {
        if (evt.getKey() == WatchUi.KEY_ENTER) {
            app().recorder.start();
            WatchUi.switchToView(new RecordView(), new RecordDelegate(), WatchUi.SLIDE_IMMEDIATE);
            return true;
        }
        return BehaviorDelegate.onKey(evt);
    }

    // Holding Up: the tracks kept on the watch.
    function onMenu() as Boolean {
        var menu = new TracksMenu();
        WatchUi.pushView(menu, new TracksDelegate(), WatchUi.SLIDE_UP);
        return true;
    }
}
