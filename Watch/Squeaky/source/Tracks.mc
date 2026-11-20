import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;

// Tracks kept on the watch until the phone confirms them.
// Index "tracks": [{ "id" start seconds, "end", "n" points, "parts", "rec" still recording, "sent" }].
// Points: "p<id>_<k>", up to PER_PART points of 14 bytes, big-endian:
// time (s, int32), latitude and longitude (degrees x 10^7, int32), altitude (m, int16).
module Tracks {
    const POINT = 14;
    const PER_PART = 290;
    const NO_ALTITUDE = -32768;
    const KEEP_SENT = 20;

    function all() as Array<Dictionary> {
        var list = Storage.getValue("tracks");
        return list != null ? list as Array<Dictionary> : [] as Array<Dictionary>;
    }

    function put(list as Array<Dictionary>) as Void {
        Storage.setValue("tracks", list as Array<Application.PropertyValueType>);
    }

    function find(list as Array<Dictionary>, id as Number) as Number {
        for (var i = 0; i < list.size(); i++) {
            if (list[i]["id"] == id) { return i; }
        }
        return -1;
    }

    function entry(id as Number) as Dictionary? {
        var list = all();
        var i = find(list, id);
        return i >= 0 ? list[i] : null;
    }

    function begin(id as Number) as Void {
        var list = all();
        list.add({ "id" => id, "end" => id, "n" => 0, "parts" => 0, "rec" => true, "sent" => false });
        trim(list);
        put(list);
    }

    function update(id as Number, n as Number, parts as Number, end as Number) as Void {
        var list = all();
        var i = find(list, id);
        if (i < 0) { return; }
        list[i]["n"] = n;
        list[i]["parts"] = parts;
        list[i]["end"] = end;
        put(list);
    }

    function finish(id as Number) as Void {
        set(id, "rec", false);
    }

    function markSent(id as Number, sent as Boolean) as Void {
        set(id, "sent", sent);
    }

    function set(id as Number, key as String, value as Boolean) as Void {
        var list = all();
        var i = find(list, id);
        if (i < 0) { return; }
        list[i][key] = value;
        put(list);
    }

    function savePart(id as Number, k as Number, bytes as ByteArray) as Void {
        Storage.setValue("p" + id + "_" + k, bytes);
    }

    function part(id as Number, k as Number) as ByteArray? {
        return Storage.getValue("p" + id + "_" + k) as ByteArray?;
    }

    function remove(id as Number) as Void {
        var list = all();
        var i = find(list, id);
        if (i < 0) { return; }
        var parts = list[i]["parts"] as Number;
        for (var k = 0; k <= parts; k++) {
            Storage.deleteValue("p" + id + "_" + k);
        }
        list.remove(list[i]);
        put(list);
    }

    // A track still marked as recording when the app opens was cut off: it is kept as it is.
    function recover() as Void {
        var list = all();
        var changed = false;
        for (var i = 0; i < list.size(); i++) {
            if (list[i]["rec"] == true) {
                list[i]["rec"] = false;
                changed = true;
            }
        }
        if (changed) { put(list); }
        var j = 0;
        while (j < list.size()) {
            if ((list[j]["n"] as Number) == 0) {
                remove(list[j]["id"] as Number);
                list = all();
            } else {
                j += 1;
            }
        }
    }

    // Keeps the newest KEEP_SENT tracks the phone has; unsent ones are never dropped.
    function trim(list as Array<Dictionary>) as Void {
        var sent = 0;
        for (var i = list.size() - 1; i >= 0; i--) {
            if (list[i]["sent"] == true) {
                sent += 1;
                if (sent > KEEP_SENT) {
                    var id = list[i]["id"] as Number;
                    var parts = list[i]["parts"] as Number;
                    for (var k = 0; k <= parts; k++) {
                        Storage.deleteValue("p" + id + "_" + k);
                    }
                    list.remove(list[i]);
                }
            }
        }
    }

    function label(id as Number) as String {
        var d = Gregorian.info(new Time.Moment(id), Time.FORMAT_MEDIUM);
        return d.day + " " + d.month + " " + d.hour.format("%02d") + ":" + d.min.format("%02d");
    }

    function length(e as Dictionary) as String {
        var s = (e["end"] as Number) - (e["id"] as Number);
        if (s < 0) { s = 0; }
        var h = s / 3600;
        var m = (s % 3600) / 60;
        return h > 0 ? h + " h " + m + " min" : m + " min";
    }
}
