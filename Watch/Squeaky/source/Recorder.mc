import Toybox.Activity;
import Toybox.ActivityMonitor;
import Toybox.ActivityRecording;
import Toybox.Lang;
import Toybox.Position;
import Toybox.Time;

// Records the track: a Garmin hike underneath (kept only for "Save Geotrac &
// Garmin") and Squeaky's own points, 14 bytes each, saved to storage as it goes.
class Recorder {
    static const IDLE = 0;
    static const RECORDING = 1;
    static const PAUSED = 2;

    var state as Number = IDLE;
    var trackId as Number = 0;
    var points as Number = 0;
    // How the last track ended: true saved, false discarded.
    var saved as Boolean = false;
    private var session as ActivityRecording.Session?;
    private var buffer as ByteArray = []b;
    private var inBuffer as Number = 0;
    private var part as Number = 0;
    private var lastT as Number = 0;
    private var lastFlush as Number = 0;
    private var stepsPrev as Number = 0;
    private var stepsTotal as Number = 0;

    function initialize() {}

    function start() as Void {
        session = ActivityRecording.createSession({
            :name => "Hike",
            :sport => Activity.SPORT_HIKING,
            :subSport => Activity.SUB_SPORT_GENERIC
        });
        (session as ActivityRecording.Session).start();
        trackId = Time.now().value();
        points = 0;
        part = 0;
        inBuffer = 0;
        lastT = 0;
        lastFlush = trackId;
        buffer = new [Tracks.PER_PART * Tracks.POINT]b;
        stepsPrev = daySteps();
        stepsTotal = 0;
        Tracks.begin(trackId);
        state = RECORDING;
    }

    function onPosition(i as Position.Info) as Void {
        if (state != RECORDING) { return; }
        var where = i.position;
        if (where == null || i.accuracy < Position.QUALITY_POOR) { return; }
        var t = i.when != null ? (i.when as Time.Moment).value() : Time.now().value();
        if (t == lastT) { return; }
        lastT = t;

        var d = where.toDegrees();
        var off = inBuffer * Tracks.POINT;
        buffer.encodeNumber(t, Lang.NUMBER_FORMAT_SINT32, { :offset => off, :endianness => Lang.ENDIAN_BIG });
        buffer.encodeNumber((d[0] * 10000000.0d).toNumber(), Lang.NUMBER_FORMAT_SINT32, { :offset => off + 4, :endianness => Lang.ENDIAN_BIG });
        buffer.encodeNumber((d[1] * 10000000.0d).toNumber(), Lang.NUMBER_FORMAT_SINT32, { :offset => off + 8, :endianness => Lang.ENDIAN_BIG });
        var alt = Tracks.NO_ALTITUDE;
        if (i.altitude != null) {
            alt = (i.altitude as Float).toNumber();
            if (alt < -32000) { alt = -32000; }
            if (alt > 32000) { alt = 32000; }
        }
        buffer.encodeNumber(alt, Lang.NUMBER_FORMAT_SINT16, { :offset => off + 12, :endianness => Lang.ENDIAN_BIG });
        inBuffer += 1;
        points += 1;

        if (inBuffer == Tracks.PER_PART) {
            flush(t);
            part += 1;
            buffer = new [Tracks.PER_PART * Tracks.POINT]b;
            inBuffer = 0;
        } else if (t - lastFlush >= 60) {
            flush(t);
        }
    }

    // Writes the part being filled, so a crash or flat battery loses at most a minute.
    private function flush(t as Number) as Void {
        if (inBuffer > 0) {
            Tracks.savePart(trackId, part, buffer.slice(0, inBuffer * Tracks.POINT));
        }
        Tracks.update(trackId, points, part + (inBuffer > 0 ? 1 : 0), lastT > 0 ? lastT : t);
        lastFlush = t;
    }

    function pause() as Void {
        if (state != RECORDING) { return; }
        if (session != null) { (session as ActivityRecording.Session).stop(); }
        flush(Time.now().value());
        state = PAUSED;
    }

    function resume() as Void {
        if (state != PAUSED) { return; }
        if (session != null) { (session as ActivityRecording.Session).start(); }
        state = RECORDING;
    }

    // Ends the track; with Garmin, the hike is saved to the watch's activities too.
    function save(withGarmin as Boolean) as Void {
        flush(Time.now().value());
        if (session != null) {
            var s = session as ActivityRecording.Session;
            if (s.isRecording()) { s.stop(); }
            if (withGarmin) { s.save(); } else { s.discard(); }
        }
        session = null;
        state = IDLE;
        saved = true;
        if (points == 0) {
            Tracks.remove(trackId);
        } else {
            Tracks.finish(trackId);
        }
    }

    function discard() as Void {
        if (session != null) {
            var s = session as ActivityRecording.Session;
            if (s.isRecording()) { s.stop(); }
            s.discard();
        }
        session = null;
        state = IDLE;
        saved = false;
        Tracks.remove(trackId);
    }

    // The app is closing mid-track: keep every point; the track is offered next time.
    function onAppStop() as Void {
        if (state != IDLE) {
            flush(Time.now().value());
        }
    }

    static function daySteps() as Number {
        var s = ActivityMonitor.getInfo().steps;
        return s != null ? s : 0;
    }

    // Steps since Start, carried across midnight when the day's count restarts.
    function steps() as Number {
        var now = daySteps();
        stepsTotal += now >= stepsPrev ? now - stepsPrev : now;
        stepsPrev = now;
        return stepsTotal;
    }
}
