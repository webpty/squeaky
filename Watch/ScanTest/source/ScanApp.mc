import Toybox.Application;
import Toybox.BluetoothLowEnergy;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;

// Phase 0: scans for Bluetooth LE advertisements, shows them live and writes
// every change to the app's log file (GARMIN/Apps/LOGS/GTSCAN.TXT).
class ScanApp extends Application.AppBase {
    var model as ScanModel;

    function initialize() {
        AppBase.initialize();
        model = new ScanModel();
    }

    function onStart(state as Dictionary?) as Void {
        var d = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        var s = System.getDeviceSettings();
        model.log("S start " + d.year + "-" + d.month.format("%02d") + "-" + d.day.format("%02d")
            + " fw " + s.firmwareVersion[0] + "." + s.firmwareVersion[1]
            + " ciq " + s.monkeyVersion[0] + "." + s.monkeyVersion[1] + "." + s.monkeyVersion[2]
            + " app 0.1.1");
        BluetoothLowEnergy.setDelegate(new ScanBle(model));
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_SCANNING);
    }

    function onStop(state as Dictionary?) as Void {
        BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
        model.log("S stop");
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var view = new ListView(model);
        return [view, new ListDelegate(model, view)];
    }
}

class ScanBle extends BluetoothLowEnergy.BleDelegate {
    var model as ScanModel;

    function initialize(m as ScanModel) {
        BleDelegate.initialize();
        model = m;
    }

    function onScanResults(results as BluetoothLowEnergy.Iterator) as Void {
        for (var r = results.next(); r != null; r = results.next()) {
            if (r instanceof BluetoothLowEnergy.ScanResult) {
                model.seen(r);
            }
        }
        WatchUi.requestUpdate();
    }

    function onScanStateChange(state as BluetoothLowEnergy.ScanState, status as BluetoothLowEnergy.Status) as Void {
        model.scanning = (state == BluetoothLowEnergy.SCAN_STATE_SCANNING);
        model.scanStatus = status;
        model.log("S scan state " + state + " status " + status);
        WatchUi.requestUpdate();
    }
}
