import Toybox.Application;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.WatchUi;

// Geotag on the watch: records a GPS track (one point a second) and hands it
// to the Geotag iPhone app over Bluetooth, part by part, until the phone
// confirms every part.
class GeotagApp extends Application.AppBase {
    var gps as Gps;
    var recorder as Recorder;
    var sender as Sender;

    function initialize() {
        AppBase.initialize();
        gps = new Gps();
        recorder = new Recorder();
        sender = new Sender();
    }

    function onStart(state as Dictionary?) as Void {
        Tracks.recover();
        gps.start();
        Communications.registerForPhoneAppMessages(sender.method(:onPhone));
        sender.sendUnsent();
    }

    function onStop(state as Dictionary?) as Void {
        recorder.onAppStop();
        gps.stop();
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var view = new ReadyView();
        return [view, new ReadyDelegate()];
    }
}

function app() as GeotagApp {
    return Application.getApp() as GeotagApp;
}
