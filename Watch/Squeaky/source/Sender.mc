import Toybox.Communications;
import Toybox.Lang;
import Toybox.StringUtil;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

// Sends a track part by part and waits for the phone to confirm each one
// before the next. Message to the phone:
//   { "k" => "part", "id" => start seconds, "n" => part, "of" => parts, "pts" => points, "end" => seconds, "d" => base64 }
// The phone answers { "k" => "ack", "id", "n" }, or { "k" => "have", "id" } when it already has the whole track.
class Sender {
    static const SENDING = 1;
    static const WAITING = 2;
    static const RECEIVED = 3;

    var trackId as Number? = null;
    var part as Number = 0;
    var parts as Number = 0;
    var status as Number = 0;
    var lastDone as Number? = null;
    private var queue as Array<Number> = [] as Array<Number>;
    private var sentAt as Number = 0;
    private var retryAt as Number = 0;
    private var timer as Timer.Timer;

    function initialize() {
        timer = new Timer.Timer();
        timer.start(method(:onTick), 5000, true);
    }

    function send(id as Number) as Void {
        if (trackId == id || queue.indexOf(id) >= 0) { return; }
        queue.add(id);
        if (trackId == null) { next(); }
    }

    function sendAgain(id as Number) as Void {
        Tracks.markSent(id, false);
        if (trackId == id) {
            part = 0;
            transmit();
        } else {
            send(id);
        }
    }

    // Tracks the phone has not confirmed go out whenever the app is open.
    function sendUnsent() as Void {
        var list = Tracks.all();
        for (var i = 0; i < list.size(); i++) {
            if (list[i]["sent"] != true && list[i]["rec"] != true) {
                send(list[i]["id"] as Number);
            }
        }
    }

    // Where a given track stands, for the screens.
    function statusOf(id as Number) as Number {
        if (trackId == id) { return status; }
        var e = Tracks.entry(id);
        if (e != null && e["sent"] == true) { return RECEIVED; }
        return WAITING;
    }

    private function next() as Void {
        if (queue.size() == 0) {
            trackId = null;
            status = 0;
            return;
        }
        var id = queue[0];
        queue.remove(id);
        var e = Tracks.entry(id);
        if (e == null) {
            next();
            return;
        }
        trackId = id;
        part = 0;
        parts = e["parts"] as Number;
        transmit();
    }

    private function transmit() as Void {
        var id = trackId as Number;
        var e = Tracks.entry(id);
        if (e == null) {
            next();
            return;
        }
        var bytes = Tracks.part(id, part);
        var data = bytes != null && bytes.size() > 0
            ? StringUtil.convertEncodedString(bytes, {
                :fromRepresentation => StringUtil.REPRESENTATION_BYTE_ARRAY,
                :toRepresentation => StringUtil.REPRESENTATION_STRING_BASE64
            }) as String
            : "";
        var message = {
            "k" => "part", "id" => id, "n" => part, "of" => parts,
            "pts" => e["n"], "end" => e["end"], "d" => data
        };
        sentAt = Time.now().value();
        retryAt = 0;
        if (status != WAITING) { status = SENDING; }
        Communications.transmit(message, null, new SendListener(self, id, part));
        WatchUi.requestUpdate();
    }

    function onTransmitted(id as Number, n as Number, ok as Boolean) as Void {
        if (!ok && trackId == id && part == n) {
            status = WAITING;
            retryAt = Time.now().value() + 10;
            WatchUi.requestUpdate();
        }
    }

    function onPhone(message as Communications.PhoneAppMessage) as Void {
        var d = message.data;
        if (!(d instanceof Dictionary) || trackId == null) { return; }
        var kind = d["k"];
        if (d["id"] != trackId) { return; }
        if ("have".equals(kind) || ("ack".equals(kind) && d["n"] == parts - 1 && part == parts - 1)) {
            done();
        } else if ("ack".equals(kind) && d["n"] == part) {
            part += 1;
            status = SENDING;
            transmit();
        }
    }

    private function done() as Void {
        var id = trackId as Number;
        Tracks.markSent(id, true);
        lastDone = id;
        status = RECEIVED;
        WatchUi.requestUpdate();
        trackId = null;
        next();
        if (trackId == null) { status = RECEIVED; }
    }

    // No answer within 30 s, or a failed send 10 s ago: the same part again.
    function onTick() as Void {
        if (trackId == null) { return; }
        var now = Time.now().value();
        if ((retryAt > 0 && now >= retryAt) || now - sentAt >= 30) {
            status = WAITING;
            transmit();
        }
    }
}

class SendListener extends Communications.ConnectionListener {
    private var sender as Sender;
    private var id as Number;
    private var n as Number;

    function initialize(s as Sender, trackId as Number, part as Number) {
        ConnectionListener.initialize();
        sender = s;
        id = trackId;
        n = part;
    }

    function onComplete() as Void {
        sender.onTransmitted(id, n, true);
    }

    function onError() as Void {
        sender.onTransmitted(id, n, false);
    }
}
