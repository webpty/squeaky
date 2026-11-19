import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

class ListView extends WatchUi.View {
    var model as ScanModel;
    var timer as Timer.Timer?;
    // Rows on screen last time, for taps: [top, height, device].
    var rowsShown as Array = [];

    function initialize(m as ScanModel) {
        View.initialize();
        model = m;
    }

    function onShow() as Void {
        timer = new Timer.Timer();
        timer.start(method(:onTick), 1000, true);
    }

    function onHide() as Void {
        if (timer != null) { timer.stop(); }
    }

    function onTick() as Void {
        model.tick();
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var now = Time.now().value();
        var devices = model.sorted();
        if (model.selected >= devices.size()) { model.selected = devices.size() - 1; }
        if (model.selected < 0) { model.selected = 0; }

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var title = model.presentCount() + " devices";
        if (model.scanStatus != 0) {
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            title = "Scan failed: " + model.scanStatus;
        }
        dc.drawText(w / 2, h * 0.07, Graphics.FONT_XTINY, title, Graphics.TEXT_JUSTIFY_CENTER);

        var rowH = (h * 0.135).toNumber();
        var top = (h * 0.17).toNumber();
        var count = ((h * 0.80 - top) / rowH).toNumber();
        var start = model.selected - count / 2;
        if (start > devices.size() - count) { start = devices.size() - count; }
        if (start < 0) { start = 0; }

        rowsShown = [];
        for (var i = 0; i < count && start + i < devices.size(); i++) {
            var d = devices[start + i];
            var y = top + i * rowH;
            rowsShown.add([y, rowH, d]);
            if (start + i == model.selected) {
                dc.setColor(0x1E3A66, Graphics.COLOR_TRANSPARENT);
                dc.fillRoundedRectangle(w * 0.1, y, w * 0.8, rowH - 4, 10);
            }
            var main = d.gone ? Graphics.COLOR_DK_GRAY : Graphics.COLOR_WHITE;
            var sub = d.gone ? Graphics.COLOR_DK_GRAY : Graphics.COLOR_LT_GRAY;
            dc.setColor(main, Graphics.COLOR_TRANSPARENT);
            var name = d.name != null ? d.name : "No name";
            dc.drawText(w / 2, y + 2, Graphics.FONT_XTINY, name + "  " + d.rssi, Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(sub, Graphics.COLOR_TRANSPARENT);
            var maker = d.maker.equals("") ? "No maker" : d.maker;
            dc.drawText(w / 2, y + rowH / 2, Graphics.FONT_XTINY, maker + "  " + ago(now - d.last), Graphics.TEXT_JUSTIFY_CENTER);
        }

        if (devices.size() == 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h / 2, Graphics.FONT_SMALL, model.scanning ? "Scanning" : "Starting", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        if (now < model.markerUntil) {
            dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(w * 0.2, h * 0.4, w * 0.6, h * 0.2, 10);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h / 2, Graphics.FONT_MEDIUM, "Marker " + model.marker, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        } else if (model.marker > 0) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.84, Graphics.FONT_XTINY, "Marker " + model.marker, Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    static function ago(s as Number) as String {
        if (s < 60) { return s + " s"; }
        if (s < 3600) { return (s / 60) + " min"; }
        return (s / 3600) + " h";
    }

    function deviceAt(y as Number) as Seen? {
        for (var i = 0; i < rowsShown.size(); i++) {
            var r = rowsShown[i] as Array;
            if (y >= (r[0] as Number) && y < (r[0] as Number) + (r[1] as Number)) {
                return r[2] as Seen;
            }
        }
        return null;
    }
}

class ListDelegate extends WatchUi.BehaviorDelegate {
    var model as ScanModel;
    var view as ListView;

    function initialize(m as ScanModel, v as ListView) {
        BehaviorDelegate.initialize();
        model = m;
        view = v;
    }

    // The Start button drops a numbered marker in the log.
    function onKey(evt as WatchUi.KeyEvent) as Boolean {
        if (evt.getKey() == WatchUi.KEY_ENTER) {
            model.mark();
            WatchUi.requestUpdate();
            return true;
        }
        return false;
    }

    function onSelect() as Boolean {
        return true;
    }

    function onNextPage() as Boolean {
        model.selected += 1;
        WatchUi.requestUpdate();
        return true;
    }

    function onPreviousPage() as Boolean {
        model.selected -= 1;
        WatchUi.requestUpdate();
        return true;
    }

    // Holding Up opens the highlighted device.
    function onMenu() as Boolean {
        var devices = model.sorted();
        if (model.selected >= 0 && model.selected < devices.size()) {
            open(devices[model.selected]);
        }
        return true;
    }

    function onTap(evt as WatchUi.ClickEvent) as Boolean {
        var d = view.deviceAt(evt.getCoordinates()[1]);
        if (d != null) { open(d); }
        return true;
    }

    function open(d as Seen) as Void {
        var v = new DetailView(model, d);
        WatchUi.pushView(v, new DetailDelegate(v), WatchUi.SLIDE_LEFT);
    }
}
