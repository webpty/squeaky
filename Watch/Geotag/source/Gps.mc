import Toybox.Attention;
import Toybox.Lang;
import Toybox.Position;
import Toybox.WatchUi;

// Location events once a second, with the most accurate setting the watch has.
class Gps {
    var quality as Number = Position.QUALITY_NOT_AVAILABLE;
    var info as Position.Info?;
    private var beeped as Boolean = false;

    function initialize() {}

    function start() as Void {
        var options = { :acquisitionType => Position.LOCATION_CONTINUOUS } as Dictionary;
        var best = bestConfiguration();
        if (best != null) {
            options[:configuration] = best;
        }
        Position.enableLocationEvents(options, method(:onPosition));
    }

    function stop() as Void {
        Position.enableLocationEvents(Position.LOCATION_DISABLE, null);
    }

    // All satellite systems on both frequencies, else the closest the watch offers.
    private function bestConfiguration() as Position.Configuration? {
        if (!(Position has :hasConfigurationSupport)) { return null; }
        var wanted = [
            Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1_L5,
            Position.CONFIGURATION_SAT_IQ_MAX_ACCURACY,
            Position.CONFIGURATION_GPS_GLONASS_GALILEO_BEIDOU_L1
        ];
        for (var i = 0; i < wanted.size(); i++) {
            if (Position.hasConfigurationSupport(wanted[i])) {
                return wanted[i];
            }
        }
        return null;
    }

    function onPosition(i as Position.Info) as Void {
        info = i;
        quality = i.accuracy;
        if (quality == Position.QUALITY_GOOD && !beeped) {
            beeped = true;
            if (Attention has :playTone) { Attention.playTone(Attention.TONE_SUCCESS); }
            if (Attention has :vibrate) { Attention.vibrate([new Attention.VibeProfile(60, 400)]); }
        }
        app().recorder.onPosition(i);
        WatchUi.requestUpdate();
    }

    // The loading bar: Garmin gives apps only the fix quality, not the satellite count.
    function percent() as Number {
        if (quality == Position.QUALITY_GOOD) { return 100; }
        if (quality == Position.QUALITY_USABLE) { return 66; }
        if (quality == Position.QUALITY_POOR) { return 33; }
        return 0;
    }

    function word() as String {
        if (quality == Position.QUALITY_GOOD) { return WatchUi.loadResource(Rez.Strings.Good) as String; }
        if (quality == Position.QUALITY_USABLE) { return WatchUi.loadResource(Rez.Strings.Usable) as String; }
        if (quality == Position.QUALITY_POOR) { return WatchUi.loadResource(Rez.Strings.Poor) as String; }
        return WatchUi.loadResource(Rez.Strings.Searching) as String;
    }
}
