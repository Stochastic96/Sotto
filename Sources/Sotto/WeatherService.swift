import Foundation

/// Free, no-key weather via Open-Meteo (open-meteo.com, CC-BY 4.0).
///
/// Two calls, both keyless: Open-Meteo's geocoding endpoint turns a city name into
/// coordinates, then the forecast endpoint returns current conditions + today's
/// high/low. Network only — no key, no sign-up. Inference stays on-device; this just
/// fetches facts, exactly like the existing Wikipedia/geocode tools.
enum WeatherService {

    static func summary(city: String) async -> String? {
        guard let place = await geocode(city) else { return nil }
        guard let url = URL(string:
            "https://api.open-meteo.com/v1/forecast?latitude=\(place.lat)&longitude=\(place.lon)" +
            "&current=temperature_2m,weather_code,wind_speed_10m" +
            "&daily=temperature_2m_max,temperature_2m_min&timezone=auto"),
            let (data, _) = try? await URLSession.shared.data(from: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let current = json["current"] as? [String: Any],
            let temp = current["temperature_2m"] as? Double
        else { return nil }

        let code = (current["weather_code"] as? Int) ?? Int((current["weather_code"] as? Double) ?? -1)
        let desc = describe(code)

        var highLow = ""
        if let daily = json["daily"] as? [String: Any],
           let mx = (daily["temperature_2m_max"] as? [Double])?.first,
           let mn = (daily["temperature_2m_min"] as? [Double])?.first {
            highLow = ", high \(Int(mx.rounded()))° low \(Int(mn.rounded()))°"
        }
        var wind = ""
        if let w = current["wind_speed_10m"] as? Double { wind = ", wind \(Int(w.rounded())) km/h" }

        return "\(place.name): \(Int(temp.rounded()))°C, \(desc)\(highLow)\(wind)."
    }

    private static func geocode(_ city: String) async -> (lat: Double, lon: Double, name: String)? {
        let q = city.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? city
        guard let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(q)&count=1&language=en&format=json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let lat = first["latitude"] as? Double,
              let lon = first["longitude"] as? Double else { return nil }
        return (lat, lon, (first["name"] as? String) ?? city)
    }

    /// WMO weather interpretation codes → short spoken text.
    private static func describe(_ code: Int) -> String {
        switch code {
        case 0:            return "clear sky"
        case 1:            return "mainly clear"
        case 2:            return "partly cloudy"
        case 3:            return "overcast"
        case 45, 48:       return "foggy"
        case 51, 53, 55:   return "drizzle"
        case 56, 57:       return "freezing drizzle"
        case 61, 63, 65:   return "rain"
        case 66, 67:       return "freezing rain"
        case 71, 73, 75:   return "snow"
        case 77:           return "snow grains"
        case 80, 81, 82:   return "rain showers"
        case 85, 86:       return "snow showers"
        case 95:           return "thunderstorm"
        case 96, 99:       return "thunderstorm with hail"
        default:           return "unsettled conditions"
        }
    }
}
