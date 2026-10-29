import SwiftUI

struct CategoriesScreen: View {
    @EnvironmentObject private var store: AdminStore
    @State private var groups: [J] = []
    @State private var problem: String?
    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(.red) }
            ForEach(groups.indices,id:\.self) { index in let g = groups[index]
                NavigationLink { CategoryScreen(group:g) } label: {
                    VStack(alignment:.leading) { Text(categoryTitle(g)); Text("\(g["system"].str) · \(g["participantIds"].list.count) участников").font(.caption) }
                }
            }
            if store.active["status"].str == "Регистрация" {
                Section("Общие настройки") {
                    NavigationLink("Объединить веса / пояса") { MergeScreen(event:store.active) }
                    NavigationLink("Шаблоны и общие параметры") { EventSettingsScreen(event:store.active) }
                }
            }
        }.navigationTitle("Категории")
        .task(id:store.snapshot["revision"].int) { do { groups = try SharedEngine.run("categories",snapshot:store.snapshot).list; problem = nil } catch { problem = error.localizedDescription } }
    }
}

struct CategoryScreen: View {
    @EnvironmentObject private var store: AdminStore
    let group: J
    @State private var cfg: J = .null
    var body: some View {
        List {
            Text(categoryTitle(group)).font(.headline)
            if store.active != .null {
                let base: [String:J] = ["eventId":store.active["id"],"expectedVersion":store.active["version"],"key":.string(categoryKey(group))]
                if store.active["status"].str == "Регистрация" {
                    Section("Система") {
                        ForEach(["По умолчанию","Круговая","Олимпийская"],id:\.self) { value in
                            Button(value) { var p = base; p["system"] = value == "По умолчанию" ? .null : .string(value); Task { await store.perform("category.configure",p) } }.disabled(!store.canEdit)
                        }
                    }
                }
                Section("Параметры") {
                    Text("Система: "+cfg["system"].str)
                    if !cfg["conflicts"].list.isEmpty { Text("Разрешите конфликты: "+cfg["conflicts"].list.map(\.str).joined(separator:", ")).foregroundStyle(.orange) }
                    ForEach(["durationSec","restSec","gapSec"],id:\.self) { field in
                        NavigationLink("\(field == "durationSec" ? "Длительность" : field == "restSec" ? "Отдых" : "Интервал"): \(cfg[field].int/60) мин") {
                            NumberSettingScreen(title:field == "durationSec" ? "Длительность" : field == "restSec" ? "Отдых" : "Интервал",action:"category.configure",payload:base,field:field,initial:Double(cfg[field].int)/60,resettable:true)
                        }
                    }
                    NavigationLink("Ковёр: "+store.mat(cfg["matId"].str)) { MatAssignmentScreen(payload:base) }
                }
            }
            if !group.id.isEmpty { NavigationLink("Сетка, схватки и места") { GroupResultsScreen(group:group) } }
        }.navigationTitle("Категория")
        .task(id:store.snapshot["revision"].int) { do { cfg = try SharedEngine.run("category",snapshot:store.snapshot,payload:group) } catch { store.error = error.localizedDescription } }
    }
}

struct NumberSettingScreen: View {
    @EnvironmentObject private var store: AdminStore
    @Environment(\.dismiss) private var dismiss
    let title: String; let action: String; @State private var payload: [String:J]; let field: String; let resettable: Bool
    @State private var value: Double
    init(title: String,action: String,payload: [String:J],field: String,initial: Double,resettable: Bool = false) {
        self.title = title; self.action = action; _payload = State(initialValue:payload); self.field = field; self.resettable = resettable; _value = State(initialValue:initial)
    }
    var body: some View {
        Form {
            Stepper(value:$value,in:(field == "durationSec" || ["young","child","adult","black"].contains(field) ? 0.5 : field == "seconds" ? -1440 : 0)...(field == "seconds" ? 1440 : field == "restSec" ? 120 : 60),step:0.5) { Text("\(value.formatted()) мин") }
            Button("Сохранить") { save(.number(value*60)) }.disabled(!store.canEdit)
            if resettable { Button("Использовать шаблон турнира") { save(.null) }.disabled(!store.canEdit) }
        }.navigationTitle(title)
    }
    private func save(_ value: J) { var p = payload; p[field] = value; Task { if await store.perform(action,p) { dismiss() } } }
}

struct MatAssignmentScreen: View {
    @EnvironmentObject private var store: AdminStore
    @Environment(\.dismiss) private var dismiss
    @State var payload: [String:J]
    var body: some View {
        List {
            ForEach(store.rows("mats").filter { $0["eventId"] == store.active["id"] }) { mat in Button(mat["name"].str) { var p = payload; p["matId"] = mat["id"]; Task { if await store.perform("category.configure",p) { dismiss() } } }.disabled(!store.canEdit) }
        }.navigationTitle("Выбрать ковёр")
    }
}

struct MergeScreen: View {
    @EnvironmentObject private var store: AdminStore
    @State var event: J
    @State private var kind = "weight"
    @State private var age = ""
    @State private var selected: Set<String> = []
    @State private var reset = false
    var ages: [String] { Array(Set(store.catalog["categories"].list.map { $0["age"].str })).sorted() }
    var choices: [String] { kind == "weight" ? store.catalog["categories"].list.filter { $0["age"].str == age }.map { $0["weight"].str } : Array(Set(store.catalog["childBelts"].list.map(\.str)+store.catalog["adultBelts"].list.map(\.str))).sorted() }
    var body: some View {
        Form {
            Picker("Объединить",selection:$kind) { Text("Веса").tag("weight"); Text("Пояса").tag("belt") }
            if kind == "weight" { Picker("Возраст",selection:$age) { Text("Выбрать").tag(""); ForEach(ages,id:\.self) { Text($0).tag($0) } } }
            Section("Выберите минимум два значения") { ForEach(choices,id:\.self) { value in Button { if selected.contains(value) { selected.remove(value) } else { selected.insert(value) } } label: { HStack { Text(value); Spacer(); if selected.contains(value) { Image(systemName:"checkmark") } } } } }
            Button("Сохранить объединение") { Task { if await store.perform("category.merge",["eventId":event["id"],"expectedVersion":event["version"],"kind":.string(kind),"age":.string(age),"values":.array(selected.sorted().map(J.string))]) { selected = [] } } }.disabled(!store.canEdit || selected.count < 2)
            Section { Text("Веса объединяются внутри возраста. При разных системах, длительностях или коврах потребуется выбрать итоговые настройки категории.").font(.caption); Button("Сбросить все объединения",role:.destructive) { reset = true }.disabled(!store.canEdit) }
        }.navigationTitle("Объединения")
        .onChange(of:kind) { _, _ in selected = [] }.onChange(of:age) { _, _ in selected = [] }
        .confirmationDialog("Сбросить объединения поясов и весов?",isPresented:$reset) { Button("Сбросить",role:.destructive) { Task { await store.perform("category.reset",["eventId":event["id"],"expectedVersion":event["version"]]) } } }
    }
}

struct EventSettingsScreen: View {
    @EnvironmentObject private var store: AdminStore
    let event: J
    var body: some View {
        List {
            let base: [String:J] = ["eventId":event["id"],"expectedVersion":event["version"]]
            if event["status"].str == "Регистрация" {
                Section("По умолчанию") {
                    ForEach(["Олимпийская","Круговая"],id:\.self) { value in Button(value) { var p = base; p["system"] = .string(value); Task { await store.perform("event.system",p) } }.disabled(!store.canEdit) }
                    Button(event["belts"].flag ? "Отключить деление по поясам" : "Включить деление по поясам") { var p = base; p["enabled"] = .bool(!event["belts"].flag); Task { await store.perform("event.belts",p) } }.disabled(!store.canEdit)
                }
            }
            Section("Шаблоны длительности") {
                ForEach(["young","child","adult","black"],id:\.self) { field in
                    NavigationLink("\(field == "young" ? "4–6 лет" : field == "child" ? "7–17 лет" : field == "adult" ? "Взрослые" : "Чёрные пояса"): \(event["templates"][field].int/60) мин") { NumberSettingScreen(title:"Длительность",action:"event.templates",payload:base,field:field,initial:Double(event["templates"][field].int)/60) }
                }
                NavigationLink("Минимальный отдых") { NumberSettingScreen(title:"Отдых",action:"event.templates",payload:base,field:"restSec",initial:Double(event["restSec"].int)/60) }
                NavigationLink("Интервал между схватками") { NumberSettingScreen(title:"Интервал",action:"event.templates",payload:base,field:"gapSec",initial:Double(event["gapSec"].int)/60) }
            }
            NavigationLink("Переименовать клуб") { ClubsScreen() }
        }.navigationTitle("Параметры турнира")
    }
}

struct ClubsScreen: View {
    @EnvironmentObject private var store: AdminStore
    var body: some View { List { ForEach(store.rows("clubs")) { club in NavigationLink(club["name"].str) { ClubRenameScreen(club:club,event:store.active) } } }.navigationTitle("Клубы") }
}
struct ClubRenameScreen: View {
    @EnvironmentObject private var store: AdminStore
    @Environment(\.dismiss) private var dismiss
    @State private var club: J; @State private var event: J
    @State private var name: String
    init(club: J,event: J) { _club = State(initialValue:club); _event = State(initialValue:event); _name = State(initialValue:club["name"].str) }
    var body: some View { Form { TextField("Название",text:$name); Text("Архивные заявки не изменятся.").font(.caption); Button("Переименовать") { Task { if await store.perform("club.rename",["eventId":event["id"],"expectedVersion":event["version"],"clubId":club["id"],"name":.string(name)]) { dismiss() } } }.disabled(!store.canEdit || name.isEmpty) }.navigationTitle("Клуб") }
}
