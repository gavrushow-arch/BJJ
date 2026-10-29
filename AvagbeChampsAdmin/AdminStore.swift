import Foundation
import SwiftUI
import SwiftData
import Network
import UIKit

@MainActor final class AdminStore: ObservableObject {
    @Published var endpoint: String = {
        let saved = UserDefaults.standard.string(forKey: "BJJ.endpoint")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? APIClient.defaultEndpoint : saved
    }()
    @Published var session = SessionKeychain.load()
    @Published var snapshot: J = .object([:])
    @Published var catalog: J = .object([:])
    @Published var lastSync: Date?
    @Published var online = false
    @Published var busy = false
    @Published var pending: PendingCommand?
    @Published var error: String?
    @Published var pairing: J?
    private var context: ModelContext?
    private let monitor = NWPathMonitor()
    private var syncing = false
    private var refreshing: Task<AdminSession, Error>?
    init() {
        monitor.pathUpdateHandler = { [weak self] path in Task { @MainActor in self?.online = path.status == .satisfied } }
        monitor.start(queue: DispatchQueue(label: "BJJ.connectivity"))
    }
    var active: J { rows("events").first { $0["status"].str != "Архив" } ?? .null }
    var compatible: Bool { snapshot["engineVersion"].str == SharedEngine.version }
    var canEdit: Bool { online && session != nil && compatible && !busy && pending == nil }
    func rows(_ type: String) -> [J] { snapshot[type].list }
    func person(_ id: String) -> String {
        guard let p = rows("participants").first(where: { $0.id == id }) else { return "Ожидает победителя" }
        return p["name"].str + (p["club"].str.isEmpty ? "" : " [\(p["club"].str)]")
    }
    func mat(_ id: String) -> String { rows("mats").first { $0.id == id }?["name"].str ?? "Не назначен" }
    func attach(_ context: ModelContext) {
        guard self.context == nil else { return }; self.context = context
        if session != nil, let cache = try? context.fetch(FetchDescriptor<SnapshotCache>()).first {
            snapshot = (try? JSONDecoder().decode(J.self, from: cache.payload)) ?? .object([:])
            catalog = (try? JSONDecoder().decode(J.self, from: cache.catalog)) ?? .object([:]); lastSync = cache.storedAt
        }
        pending = try? context.fetch(FetchDescriptor<PendingCommand>()).first
        if let pending, pending.endpoint.isEmpty { pending.endpoint = endpoint; try? context.save() }
    }
    func saveEndpoint() { UserDefaults.standard.set(endpoint, forKey: "BJJ.endpoint") }
    @discardableResult func changeEndpoint(_ value: String) async -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do { _ = try APIClient.validatedURL(value) } catch { self.error = error.localizedDescription; return false }
        if value == endpoint { saveEndpoint(); return true }
        guard pending == nil else { error = "Сначала проверьте сохранение предыдущей операции на текущем сервере"; return false }
        guard !busy && !syncing else { error = "Дождитесь завершения синхронизации"; return false }
        busy = true
        // Revoke the old session on the old endpoint before switching destinations.
        await logout(); pairing = nil; endpoint = value; saveEndpoint(); busy = false
        return true
    }
    private func cache() throws {
        guard let context else { return }
        let entries = try context.fetch(FetchDescriptor<SnapshotCache>())
        let entry = entries.first ?? SnapshotCache(payload: Data(), catalog: Data())
        if entries.isEmpty { context.insert(entry) }
        entry.payload = try snapshot.data(); entry.catalog = try catalog.data(); entry.storedAt = Date(); lastSync = entry.storedAt
        try context.save()
    }
    func beginPairing() async {
        guard online else { error = "Для входа нужен интернет"; return }; busy = true; defer { busy = false }
        endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if let pending, !pending.endpoint.isEmpty, pending.endpoint != endpoint { error = "Неподтверждённая операция относится к другому адресу. Верните прежний адрес для проверки сохранения."; return }
        do { saveEndpoint(); pairing = try await APIClient(endpoint: endpoint).post(["action":.string("auth.begin"),"deviceName":.string(UIDevice.current.name)])["result"] }
        catch { self.error = error.localizedDescription }
    }
    func completePairing() async {
        guard let pairing, online else { return }; busy = true
        do {
            let reply = try await APIClient(endpoint: endpoint).post(["action":.string("auth.poll"),"challengeId":pairing["challengeId"],"pollSecret":pairing["pollSecret"]])
            if reply["result"]["pending"].flag { error = "Подтвердите устройство кнопкой в Telegram" }
            else { try acceptSession(reply["result"]); self.pairing = nil }
        } catch { self.error = error.localizedDescription }
        busy = false
        if session != nil { await sync(full: true) }
    }
    private func acceptSession(_ result: J) throws {
        let s = try JSONDecoder().decode(AdminSession.self, from: result.data()); try SessionKeychain.save(s); session = s
    }
    private func authenticated(_ input: [String:J]) async throws -> J {
        guard let current = session else { throw APIError("UNAUTHORIZED", "Войдите через Telegram") }
        if current.expiresAt < Date().timeIntervalSince1970*1000 + 30000 {
            let task: Task<AdminSession, Error>
            if let existing = refreshing { task = existing }
            else {
                let client = APIClient(endpoint: endpoint)
                task = Task {
                    let reply = try await client.post(["action":.string("auth.refresh"),"refreshToken":.string(current.refreshToken)])
                    return try JSONDecoder().decode(AdminSession.self, from: reply["result"].data())
                }
                refreshing = task
            }
            do { let renewed = try await task.value; guard session?.deviceId == current.deviceId else { throw APIError("UNAUTHORIZED", "Сессия закрыта") }; try SessionKeychain.save(renewed); session = renewed; refreshing = nil }
            catch { refreshing = nil; throw error }
        }
        var req = input; req["accessToken"] = .string(session?.accessToken ?? "")
        return try await APIClient(endpoint: endpoint).post(req)
    }
    func sync(full: Bool = false) async {
        guard session != nil, online, !syncing, !busy else { return }; syncing = true; defer { syncing = false }
        do {
            let reply = try await authenticated(["action":.string("sync"),"cursor":.n(full ? -1 : snapshot["revision"].int)])
            let r = reply["result"]
            if r["snapshot"] != .null { snapshot = r["snapshot"] }
            else {
                for change in r["changes"].list {
                    let type = change["type"].str, id = change["entityId"].str
                    var list = snapshot[type].list; list.removeAll { $0.id == id }
                    if !change["deleted"].flag { list.append(change["record"]) }
                    snapshot[type] = .array(list)
                }
                snapshot["revision"] = r["cursor"]; snapshot["engineVersion"] = r["engineVersion"]
                if r["next"] != .null { snapshot["next"] = r["next"] }
            }
            catalog = r["catalog"]; try cache()
        } catch { handle(error) }
    }
    @discardableResult func perform(_ action: String, _ payload: [String:J] = [:]) async -> Bool {
        guard canEdit, let context else { error = pending == nil ? "Нужны интернет и совместимая версия приложения" : "Сначала проверьте сохранение предыдущей операции"; return false }
        var p = payload
        if action != "event.create" { if p["eventId"] == nil { p["eventId"] = active["id"] }; if p["expectedVersion"] == nil { p["expectedVersion"] = active["version"] } }
        let id = UUID().uuidString
        do {
            let request: J = .object(["action":.string(action),"payload":.object(p),"operationId":.string(id),"engineVersion":.string(SharedEngine.version)])
            let command = PendingCommand(id: id, payload: try request.data(), ownerUserId:session?.userId ?? "", endpoint:endpoint); context.insert(command); try context.save(); pending = command
            return await retryPending()
        } catch { handle(error); return false }
    }
    @discardableResult func retryPending() async -> Bool {
        guard online, !busy, let command = pending, let context else { return false }
        guard command.endpoint.isEmpty || command.endpoint == endpoint else { error = "Для проверки сохранения верните прежний адрес сервера"; return false }
        guard command.ownerUserId == session?.userId else { error = "Неподтверждённая операция другого администратора. Войдите исходным аккаунтом."; return false }; busy = true
        var success = false
        do {
            let input = try JSONDecoder().decode(J.self, from: command.payload)
            _ = try await authenticated(input.dict)
            context.delete(command); try context.save(); pending = nil; success = true
        } catch let error as APIError {
            if !["HTTP","FORMAT","UNAUTHORIZED","FORBIDDEN","AUTH_EXPIRED"].contains(error.code) { context.delete(command); try? context.save(); pending = nil }
            handle(error)
        } catch { self.error = "Проверяем сохранение. Ответ не получен; повтор будет отправлен с тем же номером операции." }
        busy = false
        if success || pending == nil { await sync() }
        return success
    }
    private func handle(_ problem: Error) {
        if let e = problem as? APIError, ["UNAUTHORIZED","FORBIDDEN","AUTH_EXPIRED"].contains(e.code) {
            session = nil; SessionKeychain.clear(); snapshot = .object([:]); error = "Сессия недействительна. Подтвердите вход заново."
        } else { error = problem.localizedDescription }
    }
    func revoke(_ id: String) async { do { _ = try await authenticated(["action":.string("devices.revoke"),"deviceId":.string(id)]); if id == session?.deviceId { await logout() } } catch { handle(error) } }
    func devices() async -> [J] { do { return try await authenticated(["action":.string("devices.list")])["result"].list } catch { handle(error); return [] } }
    func logout() async {
        if online { _ = try? await authenticated(["action":.string("auth.logout")]) }
        SessionKeychain.clear(); session = nil; snapshot = .object([:]); catalog = .object([:]); lastSync = nil
        if let context { try? context.delete(model: SnapshotCache.self); try? context.save() }
    }
}
