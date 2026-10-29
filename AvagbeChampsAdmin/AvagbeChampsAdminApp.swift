import SwiftUI
import SwiftData

@main @MainActor struct AvagbeChampsAdminApp: App {
    @StateObject private var store = AdminStore()
    var body: some Scene {
        WindowGroup { RootView().environmentObject(store).tint(AdminTheme.accent).environment(\.locale,Locale(identifier:"ru_RU")).environment(\.timeZone,TimeZone(identifier:"Europe/Moscow")!) }
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
                    ConnectionBanner()
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
        .overlay(alignment: .top) { if store.busy { ProgressView("Обрабатываем…").font(.subheadline).padding().background(.regularMaterial,in:Capsule()).padding(.top,44).accessibilityLabel("Операция выполняется") } }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "figure.martial.arts").font(.system(size: 42, weight: .medium))
                        .foregroundStyle(AdminTheme.accent).padding(22)
                        .background(AdminTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 26))
                        .accessibilityHidden(true)
                    Text("AVAGBE CHAMPS").font(.caption.weight(.bold)).tracking(3).foregroundStyle(.secondary)
                    Text("Турнир под\nвашим контролем").font(.largeTitle.bold())
                    Text("Участники, сетки и ковры — в одном пульте администратора.")
                        .font(.title3).foregroundStyle(.secondary)
                }.padding(.top, 28)
                VStack(alignment: .leading, spacing: 18) {
                    Label("Вход через Telegram", systemImage: "lock.shield").font(.headline)
                    if let pairing = store.pairing {
                        Text("1. Откройте бота и нажмите «Подтвердить устройство».\n2. Вернитесь сюда, чтобы завершить вход.")
                            .foregroundStyle(.secondary)
                        Button { if let url = URL(string:"https://t.me/AvagbeChampsbot?start=bind_"+pairing["challengeId"].str) { openURL(url) } } label: {
                            Label("Открыть Telegram", systemImage: "paperplane.fill").frame(maxWidth: .infinity, minHeight: 32)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                        Button("Я подтвердил — войти") { Task { await store.completePairing() } }
                            .buttonStyle(.bordered).controlSize(.large).disabled(store.busy || !store.online)
                        Text("Запрос действует 5 минут.").font(.caption).foregroundStyle(.secondary)
                        Button("Создать новый запрос") { Task { await store.beginPairing() } }
                            .frame(minHeight: 44).disabled(store.busy || !store.online)
                    } else {
                        Text("Подключение уже настроено. Подтвердите устройство аккаунтом администратора в @AvagbeChampsbot.")
                            .foregroundStyle(.secondary)
                        Button { Task { await store.beginPairing() } } label: {
                            Label("Подключить устройство", systemImage: "arrow.right").frame(maxWidth: .infinity, minHeight: 32)
                        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!store.online || store.busy)
                    }
                    if !store.online { Label("Для входа нужен интернет", systemImage: "wifi.slash").font(.subheadline).foregroundStyle(.secondary) }
                }.adminCard()
                NavigationLink { EndpointSettingsScreen() } label: { Label("Настройки подключения", systemImage: "gearshape") }.disabled(store.busy).frame(minHeight: 44)
                Text("Только для администраторов · Версия \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: 560).padding(24).frame(maxWidth: .infinity)
        }.background(AdminTheme.canvas).navigationBarTitleDisplayMode(.inline)
    }
}

struct TournamentScreen: View {
    @EnvironmentObject private var store: AdminStore
    @State private var create = false
    @State private var draw = false
    @State private var confirmation: String?
    @State private var confirmationEvent: J = .null
    @Environment(\.dynamicTypeSize) private var typeSize
    private var event: J { store.active }
    private var participants: [J] { store.rows("participants").filter { $0["eventId"] == event["id"] && $0["status"].str == "Зарегистрирован" } }
    private var bouts: [J] { store.rows("matches").filter { $0["eventId"] == event["id"] && $0["status"].str != "Проход без боя" } }
    private var completed: Int { bouts.filter { !$0["winner"].str.isEmpty }.count }
    var body: some View {
        List {
            let e = store.active
            if e != .null {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        MatchStatus(status: e["status"].str)
                        Text(e["title"].str).font(.title.bold()).fixedSize(horizontal: false, vertical: true)
                        Label(e["startAt"].str.isEmpty ? "Время начала не задано" : dateText(e["startAt"]), systemImage: "calendar")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if e["finishMode"].str == "withoutResults" { Label("Завершён без подведения итогов", systemImage: "info.circle").font(.subheadline) }
                        if !bouts.isEmpty {
                            Divider()
                            HStack { Text("Проведено схваток"); Spacer(); Text("\(completed) / \(bouts.count)").monospacedDigit().bold() }.font(.subheadline)
                            ProgressView(value: Double(completed), total: Double(bouts.count)).tint(AdminTheme.accent)
                                .accessibilityLabel("Проведено \(completed) из \(bouts.count) схваток")
                        }
                    }.padding(.vertical, 8)
                }
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                        MetricTile(value: String(participants.count), title: "Участников", icon: "person.2")
                        MetricTile(value: String(store.rows("mats").filter { $0["eventId"] == e["id"] }.count), title: "Ковров", icon: "square.stack.3d.up")
                    }
                }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                Section("Управление турниром") {
                    NavigationLink { ParticipantsScreen() } label: { ActionRow(title: "Участники", detail: "Заявки, клубы и поиск спортсмена", icon: "person.2") }
                    NavigationLink { CategoriesScreen() } label: { ActionRow(title: "Категории и сетки", detail: "Состав, системы и результаты", icon: "square.grid.2x2") }
                    NavigationLink { MatsScreen() } label: { ActionRow(title: "Ковры и расписание", detail: "Очередь схваток и время выступлений", icon: "clock") }
                }
                if ["Регистрация","Сетки сформированы"].contains(e["status"].str) {
                    Section("Жеребьёвка") {
                        Button { draw = true } label: { Label(e["status"].str == "Регистрация" ? "Предпросмотр и жеребьёвка" : "Предпросмотр переформирования", systemImage: "shuffle").frame(maxWidth: .infinity, minHeight: 32) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!store.canEdit)
                        Text("Переформирование возможно только до начала схваток и внесения результатов.").font(.caption)
                    }
                    Section("Завершение") {
                        Button("Завершить с итогами") { confirmationEvent = e; confirmation = "event.finish" }.disabled(!store.canEdit || e["status"].str != "Сетки сформированы")
                        Button("Завершить без подведения итогов",role:.destructive) { confirmationEvent = e; confirmation = "event.finishWithoutResults" }.disabled(!store.canEdit)
                    }
                } else if e["status"].str == "Завершено" {
                    Button("Архивировать") { confirmationEvent = e; confirmation = "event.archive" }.disabled(!store.canEdit)
                }
            } else {
                ContentUnavailableView {
                    Label("Новый турнир начинается здесь", systemImage: "flag.checkered")
                } description: { Text("Создайте соревнование, откройте регистрацию и подготовьте категории.") } actions: {
                    Button("Создать соревнование") { create = true }.buttonStyle(.borderedProminent).disabled(!store.canEdit)
                }.listRowBackground(Color.clear)
            }
            if !store.rows("events").filter({ $0["status"].str == "Архив" }).isEmpty { Section("Архив") {
                ForEach(store.rows("events").filter { $0["status"].str == "Архив" }.reversed()) { event in NavigationLink(event["title"].str) { ArchiveScreen(event:event) } }
            } }
        }.adminList().navigationTitle("Обзор турнира")
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
        }.adminList().navigationTitle("Новый турнир").toolbar {
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
        }.adminList().navigationTitle("Предпросмотр сеток").toolbar { Button("Закрыть") { dismiss() } }
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
        }.adminList().navigationTitle(event["title"].str)
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var store: AdminStore
    @State private var devices: [J] = []
    @State private var editEndpoint = false
    var body: some View {
        List {
            Section {
                ActionRow(title: "AvagbeChamps Admin", detail: "Версия \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") · пульт организатора", icon: "figure.martial.arts")
            }
            Section("Синхронизация") {
                Label(store.online ? "Подключение к сети доступно" : "Без сети · только просмотр", systemImage: store.online ? "checkmark.icloud" : "wifi.slash")
                if let last = store.lastSync { LabeledContent("Данные обновлены", value: last.formatted(date: .abbreviated, time: .shortened)) }
                Button { Task { await store.sync(full:true) } } label: { Label("Обновить все данные", systemImage: "arrow.clockwise") }.disabled(!store.online || store.busy)
            }
            Section("Подключение") {
                Button { editEndpoint = true } label: { ActionRow(title: "Google Apps Script", detail: "Адрес сервиса и настройки подключения", icon: "network") }.disabled(store.busy || store.pending != nil)
            }
            Section("Устройства моего аккаунта") {
                if devices.isEmpty { Text(store.online ? "Список устройств загружается или пока пуст." : "Подключитесь к интернету для просмотра устройств.").foregroundStyle(.secondary) }
                ForEach(devices) { d in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(d["name"].str, systemImage: "iphone").font(.headline)
                        if d["revoked"].flag { StatusBadge(title: "Отключено", icon: "lock") }
                        else { Button("Отозвать доступ",role:.destructive) { Task { await store.revoke(d.id); devices = await store.devices() } }.frame(minHeight: 44).disabled(!store.online) }
                    }.padding(.vertical, 4)
                }
            }
            Section { Button("Выйти",role:.destructive) { Task { await store.logout() } }.disabled(store.busy) }
        }.adminList().navigationTitle("Настройки").task { if store.online { devices = await store.devices() } }
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
        }.adminList().navigationTitle("Адрес скрипта")
        .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Отмена") { dismiss() } } }
        .task { if !loaded { address = store.endpoint; loaded = true } }
    }
}
