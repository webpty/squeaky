import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Timer;
import Toybox.WatchUi;

// Resume, Save Geotrac, Save Geotrac & Garmin, Discard.
module StopMenu {
    function show() as Void {
        var menu = new WatchUi.Menu2({});
        menu.addItem(new WatchUi.MenuItem(Fields.text(Rez.Strings.Resume), null, :resume, null));
        menu.addItem(new WatchUi.MenuItem(Fields.text(Rez.Strings.SaveGeotrac), null, :geotrac, null));
        menu.addItem(new WatchUi.MenuItem(Fields.text(Rez.Strings.SaveBoth), null, :both, null));
        menu.addItem(new WatchUi.MenuItem(Fields.text(Rez.Strings.Discard), null, :discard, null));
        WatchUi.pushView(menu, new StopDelegate(), WatchUi.SLIDE_UP);
    }
}

class StopDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        var r = app().recorder;
        if (id == :resume) {
            r.resume();
            WatchUi.popView(WatchUi.SLIDE_DOWN);
        } else if (id == :geotrac || id == :both) {
            var track = r.trackId;
            var any = r.points > 0;
            r.save(id == :both);
            if (any) { app().sender.send(track); }
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        } else if (id == :discard) {
            var ask = new WatchUi.Menu2({ :title => Fields.text(Rez.Strings.DiscardAsk) });
            ask.addItem(new WatchUi.MenuItem(Fields.text(Rez.Strings.Discard), null, :yes, null));
            ask.addItem(new WatchUi.MenuItem(Fields.text(Rez.Strings.Resume), null, :no, null));
            WatchUi.switchToView(ask, new DiscardDelegate(), WatchUi.SLIDE_LEFT);
        }
    }

    // Back from the menu keeps the hike paused; Start opens the menu again.
    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}

class DiscardDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        if (item.getId() == :yes) {
            app().recorder.discard();
        } else {
            app().recorder.resume();
        }
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}

// After saving: where the track's sending stands.
class SendView extends WatchUi.View {
    var trackId as Number;
    private var timer as Timer.Timer?;

    function initialize(id as Number) {
        View.initialize();
        trackId = id;
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
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        var e = Tracks.entry(trackId);
        if (e == null) {
            dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h / 2, Graphics.FONT_SMALL, Fields.text(Rez.Strings.NoPoints), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.28, Graphics.FONT_SMALL, Tracks.label(trackId), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(w / 2, h * 0.38, Graphics.FONT_SMALL, Tracks.length(e), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        var s = app().sender;
        if (s.trackId == trackId && s.parts > 0) {
            var barW = (w * 0.64).toNumber();
            var x = (w - barW) / 2;
            var y = (h * 0.50).toNumber();
            dc.setColor(0x333333, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(x, y, barW, 14, 7);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(x, y, barW * s.part / s.parts, 14, 7);
        }
        dc.setColor(Draw.sendColour(trackId), Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, h * 0.64, Graphics.FONT_SMALL, Draw.sendLine(trackId), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}

class SendDelegate extends WatchUi.BehaviorDelegate {
    var pushed as Boolean;

    function initialize(fromTracks as Boolean?) {
        BehaviorDelegate.initialize();
        pushed = fromTracks == true;
    }

    function onBack() as Boolean {
        if (pushed) {
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
        } else {
            WatchUi.switchToView(new ReadyView(), new ReadyDelegate(), WatchUi.SLIDE_RIGHT);
        }
        return true;
    }

    function onSelect() as Boolean {
        return onBack();
    }
}

// The tracks kept on the watch, newest first, Sent or Not sent.
class TracksMenu extends WatchUi.Menu2 {
    function initialize() {
        Menu2.initialize({ :title => Fields.text(Rez.Strings.Tracks) });
        fill();
    }

    function fill() as Void {
        var list = Tracks.all();
        if (list.size() == 0) {
            addItem(new WatchUi.MenuItem(Fields.text(Rez.Strings.NoTracks), null, -1, null));
            return;
        }
        for (var i = list.size() - 1; i >= 0; i--) {
            var e = list[i];
            addItem(new WatchUi.MenuItem(Tracks.label(e["id"] as Number), sub(e), e["id"], null));
        }
    }

    static function sub(e as Dictionary) as String {
        var sent = e["sent"] == true ? Fields.text(Rez.Strings.Sent) : Fields.text(Rez.Strings.NotSent);
        return Tracks.length(e) + ", " + sent;
    }

    // Sent or Not sent may have changed while another page was open.
    function onShow() as Void {
        Menu2.onShow();
        var list = Tracks.all();
        for (var i = 0; i < list.size(); i++) {
            var k = findItemById(list[i]["id"]);
            if (k >= 0) {
                var item = getItem(k);
                if (item != null) { item.setSubLabel(sub(list[i])); }
            }
        }
    }
}

class TracksDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (!(id instanceof Number) || id < 0) { return; }
        var menu = new WatchUi.Menu2({ :title => Tracks.label(id) });
        menu.addItem(new WatchUi.MenuItem(Fields.text(Rez.Strings.SendAgain), null, id, null));
        WatchUi.pushView(menu, new SendAgainDelegate(), WatchUi.SLIDE_LEFT);
    }
}

class SendAgainDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId() as Number;
        app().sender.sendAgain(id);
        WatchUi.switchToView(new SendView(id), new SendDelegate(true), WatchUi.SLIDE_LEFT);
    }
}
