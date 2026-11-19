import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;

// One advertising device, as told apart by the watch.
class Seen {
    var result as BluetoothLowEnergy.ScanResult;
    var label as String;
    var name as String?;
    var rssi as Number;
    var loggedRssi as Number;
    var maker as String;
    var data as String;
    var services as String;
    var raw as String;
    var appearance as Number;
    var first as String;
    var last as Number;
    var gone as Boolean = false;
    var times as Number = 1;
    var rssiLoggedAt as Number = 0;

    function initialize(r as BluetoothLowEnergy.ScanResult, l as String) {
        result = r;
        label = l;
        name = r.getDeviceName();
        rssi = r.getRssi();
        loggedRssi = rssi;
        maker = ScanModel.makerText(r);
        data = ScanModel.dataText(r);
        services = ScanModel.servicesText(r);
        raw = ScanModel.hex(r.getRawData());
        appearance = r.getAppearance();
        first = ScanModel.clock();
        last = Time.now().value();
    }
}

class ScanModel {
    static const GONE_AFTER = 30;
    static const MAX_DEVICES = 80;
    // A device's signal goes in the log at most once a minute.
    static const RSSI_EVERY = 60;

    var list as Array<Seen> = [];
    var selected as Number = 0;
    var marker as Number = 0;
    var markerUntil as Number = 0;
    var scanning as Boolean = false;
    var scanStatus as Number = 0;
    var full as Boolean = false;
    private var next as Number = 1;

    function initialize() {}

    static function clock() as String {
        var c = System.getClockTime();
        return c.hour.format("%02d") + ":" + c.min.format("%02d") + ":" + c.sec.format("%02d");
    }

    function log(line as String) as Void {
        System.println(clock() + " " + line);
    }

    static function hex(bytes as ByteArray?) as String {
        if (bytes == null) { return ""; }
        var s = "";
        for (var i = 0; i < bytes.size(); i++) {
            s += bytes[i].format("%02X");
        }
        return s;
    }

    static function makerName(id as Number) as String? {
        var names = {
            76 => "Apple", 425 => "Canon", 135 => "Garmin", 117 => "Samsung",
            6 => "Microsoft", 224 => "Google", 301 => "Sony", 921 => "Nikon"
        };
        return names.get(id) as String?;
    }

    // "Canon 01A9", one per manufacturer entry.
    static function makerText(r as BluetoothLowEnergy.ScanResult) as String {
        var s = "";
        var it = r.getManufacturerSpecificDataIterator();
        for (var e = it.next(); e != null; e = it.next()) {
            var id = (e as Dictionary)[:companyId] as Number;
            var n = makerName(id);
            if (!s.equals("")) { s += ", "; }
            s += (n != null ? n + " " : "") + id.format("%04X");
        }
        return s;
    }

    // Manufacturer data as "01A9:hex", one per entry.
    static function dataText(r as BluetoothLowEnergy.ScanResult) as String {
        var s = "";
        var it = r.getManufacturerSpecificDataIterator();
        for (var e = it.next(); e != null; e = it.next()) {
            var d = e as Dictionary;
            if (!s.equals("")) { s += " "; }
            s += (d[:companyId] as Number).format("%04X") + ":" + hex(d[:data] as ByteArray?);
        }
        return s;
    }

    static function servicesText(r as BluetoothLowEnergy.ScanResult) as String {
        var s = "";
        var it = r.getServiceUuids();
        for (var u = it.next(); u != null; u = it.next()) {
            var t = (u as BluetoothLowEnergy.Uuid).toString();
            var tail = "-0000-1000-8000-00805f9b34fb";
            var low = t.toLower();
            if (low.length() == 36 && low.substring(0, 4).equals("0000") && low.substring(8, 36).equals(tail)) {
                t = low.substring(4, 8).toUpper();
            }
            if (!s.equals("")) { s += " "; }
            s += t;
        }
        return s;
    }

    function describe(d as Seen) as String {
        return d.rssi + "dBm name=" + (d.name != null ? d.name : "-")
            + " maker=" + (d.maker.equals("") ? "-" : d.maker)
            + " data=" + (d.data.equals("") ? "-" : d.data)
            + " svc=" + (d.services.equals("") ? "-" : d.services)
            + " app=" + d.appearance;
    }

    function seen(r as BluetoothLowEnergy.ScanResult) as Void {
        var d = null;
        for (var i = 0; i < list.size(); i++) {
            if (list[i].result.isSameDevice(r)) {
                d = list[i];
                break;
            }
        }

        if (d == null) {
            if (list.size() >= MAX_DEVICES) {
                dropOldestGone();
            }
            if (list.size() >= MAX_DEVICES) {
                if (!full) {
                    full = true;
                    log("S list full at " + MAX_DEVICES + " devices");
                }
                return;
            }
            d = new Seen(r, "D" + next);
            next += 1;
            list.add(d);
            log("+ " + d.label + " new " + describe(d));
            log("  " + d.label + " raw " + d.raw);
            return;
        }

        var name = r.getDeviceName();
        var maker = makerText(r);
        var data = dataText(r);
        var services = servicesText(r);
        var raw = hex(r.getRawData());
        d.result = r;
        d.rssi = r.getRssi();
        d.last = Time.now().value();
        if (name != null) { d.name = name; }

        if (d.gone) {
            d.gone = false;
            d.times += 1;
            d.loggedRssi = d.rssi;
            log("+ " + d.label + " back " + d.rssi + "dBm");
        } else if (d.last - d.rssiLoggedAt >= RSSI_EVERY
                && ((d.rssi - d.loggedRssi) >= 10 || (d.loggedRssi - d.rssi) >= 10)) {
            d.loggedRssi = d.rssi;
            d.rssiLoggedAt = d.last;
            log("r " + d.label + " " + d.rssi + "dBm");
        }

        if (!maker.equals(d.maker) || !data.equals(d.data) || !services.equals(d.services)) {
            d.maker = maker;
            d.data = data;
            d.services = services;
            log("~ " + d.label + " changed " + describe(d));
        }
        if (!raw.equals(d.raw)) {
            d.raw = raw;
            log("  " + d.label + " raw " + raw);
        }
    }

    // Makes room by forgetting the device gone longest.
    private function dropOldestGone() as Void {
        var oldest = -1;
        for (var i = 0; i < list.size(); i++) {
            if (list[i].gone && (oldest < 0 || list[i].last < list[oldest].last)) {
                oldest = i;
            }
        }
        if (oldest >= 0) {
            log("x " + list[oldest].label + " forgotten, list full");
            list.remove(list[oldest]);
        }
    }

    // Marks devices not heard for GONE_AFTER seconds.
    function tick() as Void {
        var now = Time.now().value();
        for (var i = 0; i < list.size(); i++) {
            var d = list[i];
            if (!d.gone && now - d.last >= GONE_AFTER) {
                d.gone = true;
                log("- " + d.label + " gone, last " + d.rssi + "dBm");
            }
        }
    }

    function mark() as Void {
        marker += 1;
        markerUntil = Time.now().value() + 2;
        log("M " + marker);
    }

    // Present devices by signal, strongest first, then gone ones by most recent.
    function sorted() as Array<Seen> {
        var out = list.slice(0, null);
        for (var i = 1; i < out.size(); i++) {
            var x = out[i];
            var j = i - 1;
            while (j >= 0 && before(x, out[j])) {
                out[j + 1] = out[j];
                j -= 1;
            }
            out[j + 1] = x;
        }
        return out;
    }

    private function before(a as Seen, b as Seen) as Boolean {
        if (a.gone != b.gone) { return !a.gone; }
        if (a.gone) { return a.last > b.last; }
        return a.rssi > b.rssi;
    }

    function presentCount() as Number {
        var n = 0;
        for (var i = 0; i < list.size(); i++) {
            if (!list[i].gone) { n += 1; }
        }
        return n;
    }
}
