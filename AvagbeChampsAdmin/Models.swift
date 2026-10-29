import Foundation
import SwiftData
import JavaScriptCore

enum J: Codable, Equatable, Sendable, Identifiable {
    case object([String:J]), array([J]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([J].self) { self = .array(v) }
        else { self = .object(try c.decode([String:J].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .object(let v): try c.encode(v); case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v); case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v); case .null: try c.encodeNil() }
    }
    var dict: [String:J] { if case .object(let v) = self { return v }; return [:] }
    var list: [J] { if case .array(let v) = self { return v }; return [] }
    var str: String { if case .string(let v) = self { return v }; return "" }
    var int: Int { if case .number(let v) = self { return Int(v) }; return 0 }
    var flag: Bool { if case .bool(let v) = self { return v }; return false }
    var id: String { self["id"].str }
    subscript(_ key: String) -> J { get { dict[key] ?? .null } set { var v = dict; v[key] = newValue; self = .object(v) } }
    static func n(_ n: Int) -> J { .number(Double(n)) }
    func data() throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.withoutEscapingSlashes]; return try e.encode(self) }
    var foundation: Any { (try? JSONSerialization.jsonObject(with: data(), options: .fragmentsAllowed)) ?? NSNull() }
}

struct AdminSession: Codable { var deviceId: String; var userId: String; var accessToken: String; var refreshToken: String; var expiresAt: Double }

@Model final class SnapshotCache {
    @Attribute(.unique) var id: String
    var payload: Data
    var catalog: Data
    var storedAt: Date
    init(payload: Data, catalog: Data) { id = "current"; self.payload = payload; self.catalog = catalog; storedAt = Date() }
}
@Model final class PendingCommand {
    @Attribute(.unique) var id: String
    var payload: Data
    var createdAt: Date
    var ownerUserId: String
    var endpoint: String = ""
    init(id: String, payload: Data, ownerUserId: String, endpoint: String = "") { self.id = id; self.payload = payload; self.ownerUserId = ownerUserId; self.endpoint = endpoint; createdAt = Date() }
}

struct SharedEngine {
    static let version = "2.0.0"
    static func run(_ operation: String, snapshot: J, payload: J = .object([:]), catalog: J = .object([:])) throws -> J {
        guard let url = Bundle.main.url(forResource: "SharedEngine", withExtension: "js"), let context = JSContext() else { throw APIError("ENGINE", "Ресурс общего движка отсутствует") }
        var failure: String?
        context.exceptionHandler = { _, value in failure = value?.toString() }
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        let script = """
        (function(operation,snapshot,payload,catalog) {
          var db=Object.assign(BJJ.empty(),snapshot); BJJ2.migrate(db);
          var e=BJJ.active(db),result;
          if(operation==='categories') result=e?(e.status==='Регистрация'?(BJJ.roster(db,e).length?BJJ.preview(db,e):[]):db.groups.filter(function(g){return g.eventId===e.id;})):[];
          else if(operation==='category') result=BJJ2.category(db,e,payload);
          else if(operation==='standings') result=BJJ.standings(db,payload);
          else if(operation==='schedule') result=BJJ2.buildSchedule(db,e,Date.now());
          else if(operation==='draw') { BJJ2.command(db,'draw.commit',payload,catalog);result=BJJ2.snapshot(db); }
          else throw new Error('Неизвестный расчёт');
          return JSON.stringify(result);
        })
        """
        let fn = context.evaluateScript(script)
        let result = fn?.call(withArguments: [operation, snapshot.foundation, payload.foundation, catalog.foundation])?.toString()
        if let failure { throw APIError("ENGINE", failure) }
        guard let result, let bytes = result.data(using: .utf8) else { throw APIError("ENGINE", "Нет результата расчёта") }
        return try JSONDecoder().decode(J.self, from: bytes)
    }
}

func categoryTitle(_ g: J) -> String { [g["age"].str, g["weight"].str, g["belt"].str].filter { !$0.isEmpty }.joined(separator: " / ") }
func categoryKey(_ g: J) -> String {
    if !g["key"].str.isEmpty { return g["key"].str }
    let array: J = .array([g["age"],g["weight"],g["belt"]])
    return String(data: (try? array.data()) ?? Data(), encoding: .utf8) ?? ""
}
func dateText(_ value: J) -> String {
    guard let date = ISO8601DateFormatter().date(from: value.str) ?? ISO8601DateFormatter.withFraction.date(from: value.str) else { return "—" }
    let f = DateFormatter(); f.locale = Locale(identifier:"ru_RU"); f.timeZone = TimeZone(identifier:"Europe/Moscow"); f.dateFormat = "dd.MM HH:mm"; return f.string(from:date)+" МСК"
}
extension ISO8601DateFormatter { static var withFraction: ISO8601DateFormatter { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return f } }
