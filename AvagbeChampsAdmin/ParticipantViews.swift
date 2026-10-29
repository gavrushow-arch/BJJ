import SwiftUI

struct ParticipantsScreen: View {
    @EnvironmentObject private var store: AdminStore
    @State private var query = ""
    @State private var editor = false
    @State private var selected: J?
    var body: some View {
        List {
            ForEach(store.rows("participants").filter { p in p["eventId"] == store.active["id"] && p["status"].str == "Зарегистрирован" && (query.isEmpty || (p["name"].str+" "+p["club"].str+" "+p["age"].str).localizedCaseInsensitiveContains(query)) }) { p in
                NavigationLink { AthleteScreen(person:p) } label: { VStack(alignment:.leading) { Text(p["name"].str); Text([p["club"].str,p["age"].str,p["weight"].str,p["belt"].str].filter { !$0.isEmpty }.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary) } }
            }
        }.navigationTitle("Участники").searchable(text:$query,prompt:"ФИО, клуб или возраст")
        .toolbar { Button { selected = nil; editor = true } label: { Image(systemName:"plus") }.disabled(!store.canEdit || store.active["status"].str != "Регистрация") }
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
                Text(current["name"].str).font(.headline)
                Text("Клуб: "+(current["club"].str.isEmpty ? "Без клуба" : current["club"].str))
                Text(current["age"].str+" / "+current["weight"].str+" / "+current["belt"].str)
                Text(current["status"].str)
            }
            if let group = store.rows("groups").first(where: { $0["participantIds"].list.contains(.string(person.id)) }) { NavigationLink("Категория и результаты") { GroupResultsScreen(group:group) } }
            Section("Схватки") {
                ForEach(store.rows("matches").filter { $0["a"].str == person.id || $0["b"].str == person.id }) { m in NavigationLink { MatchScreen(match:m) } label: { BoutLabel(match:m) } }
            }
            if current["eventId"] == store.active["id"], store.active["status"].str == "Регистрация" {
                Button("Редактировать") { editor = true }.disabled(!store.canEdit)
                Button("Отменить регистрацию",role:.destructive) { cancel = true }.disabled(!store.canEdit)
            }
        }.navigationTitle("Спортсмен")
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
            TextField("ФИО",text:$name)
            Section("Клуб") {
                TextField("Без клуба / новое название",text:$club)
                Menu("Выбрать из ранее использованных") {
                    Button("Без клуба") { club = "" }
                    ForEach(store.rows("clubs").filter { club.isEmpty || $0["name"].str.localizedCaseInsensitiveContains(club) }) { c in Button(c["name"].str) { club = c["name"].str } }
                }
            }
            Picker("Возраст",selection:$age) { Text("Выберите").tag(""); ForEach(ages,id:\.self) { Text($0).tag($0) } }
            Picker("Вес",selection:$weight) { Text("Выберите").tag(""); ForEach(weights,id:\.self) { Text($0).tag($0) } }
            if event["belts"].flag { Picker("Пояс",selection:$belt) { Text("Выберите").tag(""); ForEach(belts,id:\.self) { Text($0).tag($0) } } }
            Toggle("Другой спортсмен с таким же ФИО",isOn:$duplicate)
            Text("Включайте только при намеренной регистрации разных людей с одинаковым ФИО.").font(.caption)
        }.navigationTitle(person == nil ? "Добавить участника" : "Изменить участника")
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
