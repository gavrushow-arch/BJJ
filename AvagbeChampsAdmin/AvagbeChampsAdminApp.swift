import SwiftUI
import SwiftData

@main @MainActor struct AvagbeChampsAdminApp: App {
    @StateObject private var store = AdminStore()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(store).environment(\.locale,Locale(identifier:"ru_RU")).environment(\.timeZone,TimeZone(identifier:"Europe/Moscow")!) }
            .modelContainer(for: [SnapshotCache.self,PendingCommand.self])
    }
}

struct RootView: View {
    @EnvironmentObject private var store: AdminStore
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if store.session == nil { NavigationStack { LoginScreen() } }
            else {
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: store.online ? "network" : "wifi.slash")
                        Text(store.online ? "Подключено" : "Без сети: только просмотр")
                        Spacer()
                        if let date = store.lastSync { Text(date, style: .time) }
                    }.font(.caption).padding(8).background(store.online ? Color.green.opacity(0.12) : Color.orange.opacity(0.2))
                    if !store.compatible { Text("Обновите приложение: версия движка отличается от серверной").font(.caption).foregroundStyle(.red).padding() }
                    if store.pending != nil {
                        Button("Проверяем сохранение — повторить проверку") { Task { await store.retryPending() } }.padding(8).disabled(!store.online || store.busy)
                    }
                    TabView {
                        NavigationStack { TournamentScreen() }.tabItem { Label("Турнир",systemImage:"flag.checkered") }
                        NavigationStack { ParticipantsScreen() }.tabItem { Label("Участники",systemImage:"person.3") }
                        NavigationStack { CategoriesScreen() }.tabItem { Label("Категории",systemImage:"square.grid.2x2") }
                        NavigationStack { MatsScreen() }.tabItem { Label("Ковры",systemImage:"rectangle.split.3x1") }
                        NavigationStack { SettingsScreen() }.tabItem { Label("Настройки",systemImage:"gear") }
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) { if store.busy { ProgressView().padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)).padding() } }
        .alert("AvagbeChamps Admin",isPresented: Binding(get: { store.error != nil },set: { if !$0 { store.error = nil } })) { Button("Понятно") { store.error = nil } } message: { Text(store.error ?? "") }
        .task {
            store.attach(context)
            while !Task.isCancelled {
                if scenePhase == .active { await store.sync() }
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.sync() } } }
    }
}

struct LoginScreen: View {
    @EnvironmentObject private var store: AdminStore
    @Environment(\.openURL) private var openURL
    var body: some View {
        Form {
            Section("Только для администраторов") { Text("Участники и родители используют @AvagbeChampsbot. Вход подтверждается действующим администратором в Telegram.") }
            Section("Адрес Apps Script") {
                TextField("https://script.google.com/macros/s/…/exec",text:$store.endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("Подключить устройство") { Task { await store.beginPairing() } }.disabled(!store.online || store.busy)
            }
            if let pairing = store.pairing {
                Section("Подтверждение") {
                    Button("Открыть Telegram") { if let url = URL(string:"https://t.me/AvagbeChampsbot?start=bind_"+pairing["challengeId"].str) { openURL(url) } }
                    Text("Нажмите «Подтвердить устройство» в боте, затем вернитесь сюда. Запрос действует 5 минут.")
                    Button("Я подтвердил — войти") { Task { await store.completePairing() } }.disabled(store.busy || !store.online)
                }
            }
        }.navigationTitle("AvagbeChamps Admin")
    }
}

struct TournamentScreen: View {
    @EnvironmentObject private var store: AdminStore
    @State private var create = false
    @State private var draw = false
    @State private var confirmation: String?
    @State private var confirmationEvent: J = .null
    var body: some View {
        List {
            let e = store.active
            if e != .null {
                Section(e["title"].str) {
                    LabeledContent("Статус",value:e["status"].str)
                    LabeledContent("Участники",value:String(store.rows("participants").filter { $0["eventId"].str == e.id && $0["status"].str == "Зарегистрирован" }.count))
                    LabeledContent("Начало",value:dateText(e["startAt"]))
                    if e["finishMode"].str == "withoutResults" { Text("Завершён без подведения итогов").foregroundStyle(.secondary) }
                }
                if ["Регистрация","Сетки сформированы"].contains(e["status"].str) {
                    Section("Жеребьёвка") {
                        Button(e["status"].str == "Регистрация" ? "Предпросмотр и жеребьёвка" : "Предпросмотр переформирования") { draw = true }.disabled(!store.canEdit)
                        Text("Переформирование возможно только до начала схваток и внесения результатов.").font(.caption)
                    }
                    Section("Завершение") {
                        Button("Завершить с итогами") { confirmationEvent = e; confirmation = "event.finish" }.disabled(!store.canEdit || e["status"].str != "Сетки сформированы")
                        Button("Завершить без подведения итогов",role:.destructive) { confirmationEvent = e; confirmation = "event.finishWithoutResults" }.disabled(!store.canEdit)
                    }
                } else if e["status"].str == "Завершено" {
                    Button("Архивировать") { confirmationEvent = e; confirmation = "event.archive" }.disabled(!store.canEdit)
                }
            } else { Button("Создать соревнование") { create = true }.disabled(!store.canEdit) }
            Section("Архив") {
                ForEach(store.rows("events").filter { $0["status"].str == "Архив" }.reversed()) { event in NavigationLink(event["title"].str) { ArchiveScreen(event:event) } }
            }
        }.navigationTitle("Турнир")
        .refreshable { await store.sync() }
        .sheet(isPresented:$create) { NavigationStack { CreateEventScreen() } }
        .sheet(isPresented:$draw) { NavigationStack { DrawPreviewScreen(snapshot:store.snapshot,catalog:store.catalog) } }
        .confirmationDialog("Подтвердить действие?",isPresented: Binding(get: { confirmation != nil },set: { if !$0 { confirmation = nil } })) {
            Button("Подтвердить",role:confirmation == "event.finishWithoutResults" ? .destructive : nil) { let action = confirmation ?? "", event = confirmationEvent; confirmation = nil; Task { await store.perform(action,["eventId":event["id"],"expectedVersion":event["version"]]) } }
        } message: { Text(confirmation == "event.finishWithoutResults" ? "Внесённые результаты сохранятся, будущие схватки будут отменены, итоговые места не присваиваются." : "Изменение будет сохранено для всех администраторов и зрителей.") }
    }
}

struct CreateEventScreen: View {
    @EnvironmentObject private var store: AdminStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var date = Date()
    @State private var system = "Олимпийская"
    @State private var belts = true
    var body: some View {
        Form {
            TextField("Название",text:$title); DatePicker("Дата",selection:$date,displayedComponents:.date)
            Picker("Система по умолчанию",selection:$system) { Text("Олимпийская").tag("Олимпийская"); Text("Круговая").tag("Круговая") }
            Toggle("Учитывать пояса",isOn:$belts)
        }.navigationTitle("Новый турнир").toolbar {
            ToolbarItem(placement:.cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement:.confirmationAction) { Button("Создать") { let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy"; Task { if await store.perform("event.create",["title":.string(title),"date":.string(f.string(from:date)),"system":.string(system),"belts":.bool(belts)]) { dismiss() } } }.disabled(!store.canEdit || title.count < 2) }
        }
    }
}

struct DrawPreviewScreen: View {
    @EnvironmentObject private var store: AdminStore
    @Environment(\.dismiss) private var dismiss
    @State private var source: J
    let catalog: J
    @State private var seed = UUID().uuidString
    @State private var preview: J?
    @State private var problem: String?
    init(snapshot: J,catalog: J) { _source = State(initialValue:snapshot); self.catalog = catalog }
    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(.red) }
            if let preview {
                ForEach(preview["groups"].list.filter { $0["eventId"] == store.active["id"] }) { group in
                    Section(categoryTitle(group)) {
                        Text("\(group["system"].str) · \(group["count"].int) участников · \(group["fightCount"].int) схваток")
                        Text("Круговая: \(group["roundRobinCount"].int), олимпийская: \(group["knockoutCount"].int)").font(.caption)
                        Text("\(group["durationSec"].int/60) мин; оценка без отдыха: \(group["estimatedMinutes"].int) мин; \(store.mat(group["matId"].str))").font(.caption)
                        ForEach(preview["matches"].list.filter { $0["groupId"].str == group.id }) { match in
                            Text("№ \(match["publicNumber"].int) · \(store.person(match["a"].str)) — \(store.person(match["b"].str))\n\(match["status"].str)").font(.caption)
                        }
                    }
                }
                Button("Подтвердить жеребьёвку") { let event = source["events"].list.first { $0["status"].str != "Архив" } ?? .null
                    Task { if await store.perform("draw.commit",["eventId":event["id"],"expectedVersion":event["version"],"seed":.string(seed)]) { dismiss() } }
                }.disabled(!store.canEdit)
                Text("Сохранится именно эта жеребьёвка. Если состав или настройки изменились, потребуется новый предпросмотр.").font(.caption)
            } else if problem == nil { ProgressView("Рассчитываем на устройстве…") }
        }.navigationTitle("Предпросмотр сеток").toolbar { Button("Закрыть") { dismiss() } }
        .task {
            let s = source, c = catalog, randomSeed = seed
            do { preview = try await Task.detached { let e = s["events"].list.first { $0["status"].str != "Архив" } ?? .null; return try SharedEngine.run("draw",snapshot:s,payload:.object(["eventId":e["id"],"expectedVersion":e["version"],"seed":.string(randomSeed)]),catalog:c) }.value }
            catch { problem = error.localizedDescription }
        }
    }
}

struct ArchiveScreen: View {
    @EnvironmentObject private var store: AdminStore
    let event: J
    var body: some View {
        List {
            Text(event["finishMode"].str == "withoutResults" ? "Без подведения итогов" : "Результаты сохранены")
            ForEach(store.rows("groups").filter { $0["eventId"].str == event.id }) { g in NavigationLink(categoryTitle(g)) { GroupResultsScreen(group:g) } }
            Section("Участники") { ForEach(store.rows("participants").filter { $0["eventId"].str == event.id }) { p in Text(store.person(p.id)) } }
        }.navigationTitle(event["title"].str)
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var store: AdminStore
    @State private var devices: [J] = []
    @State private var editEndpoint = false
    var body: some View {
        List {
            Section("Google Apps Script") {
                Text(store.endpoint).font(.caption).textSelection(.enabled)
                Button("Изменить адрес скрипта") { editEndpoint = true }.disabled(store.busy || store.pending != nil)
                Text("При смене адреса потребуется заново подтвердить вход через Telegram.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Синхронизация") {
                Text("Движок \(SharedEngine.version)")
                if let last = store.lastSync { Text("Последняя загрузка: \(last.formatted())") }
                Button("Обновить все данные") { Task { await store.sync(full:true) } }.disabled(!store.online || store.busy)
            }
            Section("Устройства моего аккаунта") { ForEach(devices) { d in HStack { Text(d["name"].str); Spacer(); if d["revoked"].flag { Text("Отключено").foregroundStyle(.secondary) } else { Button("Отозвать",role:.destructive) { Task { await store.revoke(d.id); devices = await store.devices() } }.disabled(!store.online) } } } }
            Section { Button("Выйти",role:.destructive) { Task { await store.logout() } }.disabled(store.busy) }
        }.navigationTitle("Настройки").task { if store.online { devices = await store.devices() } }
        .sheet(isPresented:$editEndpoint) { NavigationStack { EndpointSettingsScreen() } }
    }
}

struct EndpointSettingsScreen: View {
    @EnvironmentObject private var store: AdminStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var loaded = false
    var body: some View {
        Form {
            Section("Адрес опубликованного скрипта") {
                TextField("https://script.google.com/macros/s/…/exec",text:$address,axis:.vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("Вернуть адрес по умолчанию") { address = APIClient.defaultEndpoint }
                Text("Используйте HTTPS-адрес /exec без ?key и других параметров. Токен Telegram вводить не нужно.").font(.caption)
            }
            Section {
                Button("Сохранить адрес") { Task { if await store.changeEndpoint(address) { dismiss() } } }
                    .disabled(store.busy || store.pending != nil || address.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            } footer: { Text("Если адрес изменится, текущая сессия будет закрыта и локальная копия очищена. Данные турнира в Google сохранятся.") }
        }.navigationTitle("Адрес скрипта")
        .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Отмена") { dismiss() } } }
        .task { if !loaded { address = store.endpoint; loaded = true } }
    }
}
