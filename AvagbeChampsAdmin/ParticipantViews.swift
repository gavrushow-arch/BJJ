import SwiftUI

struct ParticipantsScreen: View {
    @EnvironmentObject private var store: AdminStore
    @State private var query = ""
    @State private var editor = false
    @State private var selected: J?
    private var roster: [J] { store.rows("participants").filter { $0["eventId"] == store.active["id"] && $0["status"].str == "Зарегистрирован" } }
    private var filtered: [J] { roster.filter { query.isEmpty || ($0["name"].str+" "+$0["club"].str+" "+$0["age"].str).localizedCaseInsensitiveContains(query) }.sorted { $0["name"].str.localizedStandardCompare($1["name"].str) == .orderedAscending } }
    var body: some View {
        List {
            if !roster.isEmpty {
                Section("\(filtered.count) из \(roster.count) участников") {
                    ForEach(filtered) { p in
                        NavigationLink { AthleteScreen(person:p) } label: { AthleteRow(person: p) }
                    }
                }
            }
        }.adminList().navigationTitle("Участники").searchable(text:$query,prompt:"ФИО, клуб или возраст")
        .overlay { if filtered.isEmpty {
            ContentUnavailableView(query.isEmpty ? "Участников пока нет" : "Ничего не найдено", systemImage: query.isEmpty ? "person.2" : "magnifyingglass", description: Text(query.isEmpty ? "Заявки из бота появятся здесь. Добавить спортсмена можно кнопкой «+»." : "Попробуйте другую фамилию, клуб или возрастную группу."))
        } }
        .toolbar { Button { selected = nil; editor = true } label: { Label("Добавить участника",systemImage:"plus") }.disabled(!store.canEdit || store.active["status"].str != "Регистрация") }
        .sheet(isPresented:$editor) { NavigationStack { ParticipantEditor(person:selected,event:store.active) } }
        .refreshable { await store.sync() }
    }
}

struct AthleteScreen: View {
    @EnvironmentObject private var store: AdminStore
    let person: J
    @State private var editor = false
    @State private var cancel = false
    var current: J { store.rows("participants").first { $0.id == person.id } ?? person }
    var body: some View {
        List {
            Section {
                AthleteRow(person: current)
                MatchStatus(status: current["status"].str)
            }
            if let group = store.rows("groups").first(where: { $0["participantIds"].list.contains(.string(person.id)) }) { NavigationLink("Категория и результаты") { GroupResultsScreen(group:group) } }
            Section("Схватки") {
                ForEach(store.rows("matches").filter { $0["a"].str == person.id || $0["b"].str == person.id }) { m in NavigationLink { MatchScreen(match:m) } label: { BoutLabel(match:m) } }
            }
            if current["eventId"] == store.active["id"], store.active["status"].str == "Регистрация" {
                Button("Редактировать") { editor = true }.disabled(!store.canEdit)
                Button("Отменить регистрацию",role:.destructive) { cancel = true }.disabled(!store.canEdit)
            }
        }.adminList().navigationTitle("Спортсмен")
        .sheet(isPresented:$editor) { NavigationStack { ParticipantEditor(person:current,event:store.active) } }
        .confirmationDialog("Отменить регистрацию?",isPresented:$cancel) {
            Button("Да, отменить",role:.destructive) { Task { await store.perform("participant.cancel",["participantId":.string(person.id)]) } }
        }
    }
}

struct ParticipantEditor: View {
    @EnvironmentObject private var store: AdminStore
    @Environment(\.dismiss) private var dismiss
    @State private var person: J?
    @State private var event: J
    @State private var name: String
    @State private var club: String
    @State private var age: String
    @State private var weight: String
    @State private var belt: String
    @State private var duplicate = false
    init(person: J?,event: J) {
        _person = State(initialValue:person); _event = State(initialValue:event)
        _name = State(initialValue:person?["name"].str ?? ""); _club = State(initialValue:person?["club"].str ?? "")
        _age = State(initialValue:person?["age"].str ?? ""); _weight = State(initialValue:person?["weight"].str ?? ""); _belt = State(initialValue:person?["belt"].str ?? "")
    }
    var ages: [String] { Array(Set(store.catalog["categories"].list.map { $0["age"].str })).sorted() }
    var weights: [String] { store.catalog["categories"].list.filter { $0["age"].str == age }.map { $0["weight"].str } }
    var belts: [String] { store.catalog[age == "Взрослые (18+)" ? "adultBelts" : "childBelts"].list.map(\.str) }
    var body: some View {
        Form {
            Section("Спортсмен") { TextField("Фамилия Имя Отчество",text:$name).textContentType(.name).textInputAutocapitalization(.words) }
            Section("Клуб") {
                TextField("Без клуба / новое название",text:$club)
                Menu("Выбрать из ранее использованных") {
                    Button("Без клуба") { club = "" }
                    ForEach(store.rows("clubs").filter { club.isEmpty || $0["name"].str.localizedCaseInsensitiveContains(club) }) { c in Button(c["name"].str) { club = c["name"].str } }
                }
            }
            Section("Категория") {
                Picker("Возраст",selection:$age) { Text("Выберите").tag(""); ForEach(ages,id:\.self) { Text($0).tag($0) } }
                Picker("Вес",selection:$weight) { Text("Выберите").tag(""); ForEach(weights,id:\.self) { Text($0).tag($0) } }.disabled(age.isEmpty)
                if event["belts"].flag { Picker("Пояс",selection:$belt) { Text("Выберите").tag(""); ForEach(belts,id:\.self) { Text($0).tag($0) } }.disabled(age.isEmpty) }
            }
            Section { Toggle("Совпадение ФИО",isOn:$duplicate) } footer: { Text("Включите, если регистрируете другого спортсмена с таким же ФИО.") }
        }.adminList().navigationTitle(person == nil ? "Новый участник" : "Изменить участника")
        .onChange(of: age) { _, _ in weight = ""; belt = "" }
        .toolbar {
            ToolbarItem(placement:.cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement:.confirmationAction) { Button("Сохранить") {
                var payload: [String:J] = ["eventId":event["id"],"expectedVersion":event["version"],"person":.object(["name":.string(name),"club":.string(club),"age":.string(age),"weight":.string(weight),"belt":.string(belt)]),"allowDuplicate":.bool(duplicate)]
                if let person { payload["participantId"] = person["id"]; payload["expectedRev"] = person["rev"]; payload["userId"] = person["userId"] }
                Task { if await store.perform("participant.save",payload) { dismiss() } }
            }.disabled(!store.canEdit || name.split(separator:" ").count < 2 || weight.isEmpty || (event["belts"].flag && belt.isEmpty)) }
        }
    }
}
