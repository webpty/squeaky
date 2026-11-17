import GeotagCore
import GeotagUI
import SwiftUI

/// What Geotag asks of a GPS tracks service, for anyone who wants to run
/// their own (0.29.30, David, 17 November 2026: "assuming that someone else
/// might want to do the same as us").
struct ServiceFormat: View {
    var body: some View {
        List {
            Section {
                Text(Words.t("Geotag reads its GPS tracks from a web service of your own. Any service that answers as below will do."))
            }
            ForEach(Self.parts, id: \.call) { part in
                Section {
                    Text(Words.t(part.text))
                    if let example = part.example {
                        Text(example).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(part.call.contains("/v1/") ? part.call : Words.t(part.call)).textCase(nil)
                }
            }
        }
        .navigationTitle(Words.t("GPS tracks service"))
        .navigationBarTitleDisplayMode(.inline)
    }

    struct Part {
        let call: String
        let text: String
        let example: String?
    }

    static let parts = [
        Part(call: "Address and key",
             text: "An https address, and a key sent with every request in the Authorization header, after the word Bearer. An answer outside 200 to 299 is an error; a JSON body with an error field gives the reason Geotag shows.",
             example: "Authorization: Bearer <key>"),
        Part(call: "GET /v1/status",
             text: "Checks the key. Answers its role (owner or reader), how many tracks there are, and whether Strava is connected. Only an owner key may add tracks.",
             example: #"{"role":"owner","tracks":66,"strava":{"connected":true,"since":"2026-06-01"}}"#),
        Part(call: "GET /v1/tracks",
             text: "Every track, each with id, source (strava or file), name, start and end (seconds since 1970, UTC), pointCount and bounds; when known, fileName, sport, timeZone, distance in metres and place.",
             example: #"{"tracks":[{"id":"…","source":"strava","name":"Afternoon Hike","start":1794909600,"end":1794920000,"pointCount":10400,"bounds":{"minLat":36.7,"maxLat":36.8,"minLon":-5.2,"maxLon":-5.1},"timeZone":"Europe/Madrid","distance":8400,"place":"Ronda, Andalusia"}]}"#),
        Part(call: "GET /v1/tracks/<id>/points",
             text: "The track's points as four lists of the same length: t (seconds since 1970, UTC), lat, lon, and alt (null where unknown).",
             example: #"{"t":[1794909600,1794909601],"lat":[36.74,36.74],"lon":[-5.16,-5.16],"alt":[720.4,null]}"#),
        Part(call: "POST /v1/tracks",
             text: "Owner key only. Adds a track from a GPX or FIT file: name, fileName and points, as above. Answers whether it was added, and the track. A track starting within 60 seconds of one already there should not be added again.",
             example: #"{"added":true,"track":{…}}"#),
        Part(call: "GET /v1/maps",
             text: "Optional. The pictures of the tracks: light and dark tile addresses with {z}, {x} and {y}, the credit the maps require, and a key if the tiles need one.",
             example: #"{"light":"https://…/{z}/{x}/{y}.png","dark":"https://…/{z}/{x}/{y}.png","credit":"…","key":null}"#),
        Part(call: "POST /v1/sync",
             text: "Optional. Fetches new tracks now; Refresh asks for it.",
             example: #"{"result":"…"}"#),
    ]
}
