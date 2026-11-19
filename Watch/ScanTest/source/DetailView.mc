import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

// Every field the watch has for one device.
class DetailView extends WatchUi.View {
    var model as ScanModel;
    var device as Seen;
    var scroll as Number = 0;
    var timer as Timer.Timer?;

    function initialize(m as ScanModel, d as Seen) {
        View.initialize();
        model = m;
        device = d;
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

    static function chunks(out as Array<String>, s as String, size as Number) as Void {
        if (s.equals("")) {
            out.add("None");
            return;
        }
        for (var i = 0; i < s.length(); i += size) {
            var end = i + size < s.length() ? i + size : s.length();
            out.add(s.substring(i, end));
        }
    }

    function lines() as Array<String> {
        var d = device;
        var out = [] as Array<String>;
        out.add(d.name != null ? d.name : "No name");
        out.add(d.label + (d.gone ? ", gone" : ""));
        out.add("Signal " + d.rssi + " dBm");
        out.add("Maker");
        chunks(out, d.maker, 18);
        out.add("Data");
        chunks(out, d.data, 18);
        out.add("Services");
        chunks(out, d.services, 18);
        out.add("Appearance " + d.appearance);
        out.add("Raw");
        chunks(out, d.raw, 18);
        out.add("First seen " + d.first);
        out.add("Last seen " + ListView.ago(Time.now().value() - d.last) + " ago");
        out.add("Seen " + d.times + (d.times == 1 ? " time" : " times"));
        return out;
    }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        var all = lines();
        var lineH = dc.getFontHeight(Graphics.FONT_XTINY);
        var fit = ((h * 0.76) / lineH).toNumber();
        if (scroll > all.size() - fit) { scroll = all.size() - fit; }
        if (scroll < 0) { scroll = 0; }
        var labels = ["Maker", "Data", "Services", "Raw"];
        for (var i = 0; i < fit && scroll + i < all.size(); i++) {
            var t = all[scroll + i];
            var isLabel = labels.indexOf(t) >= 0;
            dc.setColor(isLabel ? Graphics.COLOR_BLUE : Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 0.12 + i * lineH, Graphics.FONT_XTINY, t, Graphics.TEXT_JUSTIFY_CENTER);
        }
    }
}

class DetailDelegate extends WatchUi.BehaviorDelegate {
    var view as DetailView;

    function initialize(v as DetailView) {
        BehaviorDelegate.initialize();
        view = v;
    }

    function onNextPage() as Boolean {
        view.scroll += 3;
        WatchUi.requestUpdate();
        return true;
    }

    function onPreviousPage() as Boolean {
        view.scroll -= 3;
        WatchUi.requestUpdate();
        return true;
    }

    function onBack() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        return true;
    }
}
