import SwiftUI

struct BoutLabel: View {
    @EnvironmentObject private var store: AdminStore
    let match: J
    private func name(_ side: String) -> String {
        if !match[side].str.isEmpty { return store.person(match[side].str) }
        if let source = store.rows("matches").first(where: { $0.id == match[side == "a" ? "sourceA" : "sourceB"].str }) { return "Победитель № \(source["publicNumber"].int)" }
        return "Проход без боя"
    }
    var body: some View {
        VStack(alignment:.leading,spacing:5) {
            Text(match["publicNumber"] == .null ? "Проход без боя" : "Схватка № \(match["publicNumber"].int)").font(.headline)
            Text(name("a")+" — "+name("b"))
            Text(match["status"].str).font(.caption).foregroundStyle(.secondary)
            if !match["winner"].str.isEmpty { Text("Победитель: "+store.person(match["winner"].str)).font(.caption).foregroundStyle(.green) }
            if let slot = store.rows("schedulePublished").first(where: { $0["matchId"].str == match.id }) {
                Text(store.mat(slot["matId"].str)+" · ориентировочно "+dateText(slot["startAt"])).font(.caption)
            }
        }.padding(.vertical,4)
    }
}

struct GroupResultsScreen: View {
    @EnvironmentObject private var store: AdminStore
    let group: J
    @State private var standings: J = .null
    @State private var tie: J?
    var matches: [J] { store.rows("matches").filter { $0["groupId"].str == group.id }.sorted { $0["round"].int == $1["round"].int ? $0["number"].int < $1["number"].int : $0["round"].int < $1["round"].int } }
    var activeGroup: Bool { group["eventId"] == store.active["id"] && store.active["status"].str == "Сетки сформированы" }
    var body: some View {
        List {
            Text(categoryTitle(group)).font(.headline)
            if group["system"].str == "Олимпийская", !matches.isEmpty {
                Section("Сетка") {
                    ScrollView(.horizontal) {
                        HStack(alignment:.center,spacing:20) {
                            ForEach(Array(Set(matches.map { $0["round"].int })).sorted(),id:\.self) { round in
                                VStack(spacing:18) {
                                    Text("Раунд \(round)").font(.headline)
                                    ForEach(matches.filter { $0["round"].int == round }) { match in
                                        NavigationLink { MatchScreen(match:match) } label: { BoutLabel(match:match).frame(width:240,alignment:.leading).padding().background(Color.blue.opacity(0.08),in:RoundedRectangle(cornerRadius:12)) }
                                    }
                                }
                            }
                        }.padding(.vertical,8)
                    }
                }
            }
            Section("Места") {
                if standings["withoutResults"].flag { Text("Турнир завершён без подведения итогов") }
                ForEach(standings["rows"].list) { row in Text((row["place"].int > 0 ? "\(row["place"].int). " : "— ")+store.person(row.id)+(group["system"].str == "Круговая" ? " · побед: \(row["wins"].int)" : "")) }
                if activeGroup { ForEach(standings["ties"].list.indices,id:\.self) { i in Button("Разрешить равенство мест") { tie = standings["ties"].list[i] }.disabled(!store.canEdit) } }
            }
            Section("Схватки по раундам") { ForEach(matches) { match in NavigationLink { MatchScreen(match:match) } label: { BoutLabel(match:match) } } }
            if activeGroup { NavigationLink("Изменить порядок схваток") { QueueOrderScreen(group:group,event:store.active) } }
        }.navigationTitle(group["system"].str)
        .task(id:store.snapshot["revision"].int) { do { standings = try SharedEngine.run("standings",snapshot:store.snapshot,payload:group) } catch { store.error = error.localizedDescription } }
        .sheet(item:$tie) { value in NavigationStack { TieOrderScreen(group:group,tie:value,event:store.active) } }
    }
}

struct MatchScreen: View {
    @EnvironmentObject private var store: AdminStore
    let match: J
    @State private var winner: String?
    @State private var clear = false
    @State private var times = false
    @State private var confirmationMatch: J = .null
    var current: J { store.rows("matches").first { $0.id == match.id } ?? match }
    var editable: Bool { store.canEdit && current["eventId"] == store.active["id"] && store.active["status"].str == "Сетки сформированы" }
    var body: some View {
        List {
            BoutLabel(match:current)
            Section("Фактическое время") {
                LabeledContent("Начало",value:dateText(current["actualStart"]))
                LabeledContent("Окончание",value:dateText(current["actualEnd"]))
                if current["status"].str == "Готова" { Button("Начать схватку") { let m = current; Task { await store.perform("match.start",["matchId":m["id"],"expectedRev":m["rev"]]) } }.disabled(!editable) }
                if !current["actualStart"].str.isEmpty || !current["winner"].str.isEmpty { Button("Скорректировать время") { times = true }.disabled(!editable) }
            }
            if ["Готова","Идёт","Завершена"].contains(current["status"].str) {
                Section("Выбрать победителя") {
                    ForEach([current["a"].str,current["b"].str].filter { !$0.isEmpty },id:\.self) { id in Button(store.person(id)) { confirmationMatch = current; winner = id }.disabled(!editable) }
                    if !current["winner"].str.isEmpty { Button("Сбросить результат",role:.destructive) { confirmationMatch = current; clear = true }.disabled(!editable) }
                }
            }
        }.navigationTitle("Схватка № \(current["publicNumber"].int)")
        .confirmationDialog("Подтвердить победителя?",isPresented:Binding(get:{ winner != nil },set:{ if !$0 { winner = nil } })) {
            Button("Подтвердить") { let id = winner ?? "", m = confirmationMatch; winner = nil; Task { await store.perform("match.result",["matchId":m["id"],"expectedRev":m["rev"],"winnerId":.string(id)]) } }
        } message: { Text(store.person(winner ?? "")) }
        .confirmationDialog("Сбросить результат?",isPresented:$clear) { Button("Да, сбросить",role:.destructive) { let m = confirmationMatch; Task { await store.perform("match.clear",["matchId":m["id"],"expectedRev":m["rev"]]) } } }
        .sheet(isPresented:$times) { NavigationStack { MatchTimeScreen(match:current) } }
    }
}

struct MatchTimeScreen: View {
    @EnvironmentObject private var store: AdminStore
    @Environment(\.dismiss) private var dismiss
    @State private var match: J
    @State private var start: Date
    @State private var end: Date
    init(match: J) { _match = State(initialValue:match); let f = ISO8601DateFormatter.withFraction; let end = f.date(from:match["actualEnd"].str) ?? ISO8601DateFormatter().date(from:match["actualEnd"].str) ?? Date(); _end = State(initialValue:end); _start = State(initialValue:f.date(from:match["actualStart"].str) ?? ISO8601DateFormatter().date(from:match["actualStart"].str) ?? end.addingTimeInterval(-300)) }
    var body: some View {
        Form {
            DatePicker("Начало",selection:$start)
            if !match["winner"].str.isEmpty { DatePicker("Окончание",selection:$end) }
            Button("Сохранить") { var p: [String:J] = ["matchId":match["id"],"expectedRev":match["rev"],"actualStart":.string(ISO8601DateFormatter().string(from:start))]; if !match["winner"].str.isEmpty { p["actualEnd"] = .string(ISO8601DateFormatter().string(from:end)) }; Task { if await store.perform("match.times",p) { dismiss() } } }.disabled(!store.canEdit || (!match["winner"].str.isEmpty && end < start))
        }.navigationTitle("Фактическое время")
    }
}

struct MatsScreen: View {
    @EnvironmentObject private var store: AdminStore
    @State private var editor = false
    @State private var mat: J?
    @State private var preview = false
    var body: some View {
        List {
            Section("Ковры") {
                ForEach(store.rows("mats").filter { $0["eventId"] == store.active["id"] }) { mat in
                    NavigationLink { MatScreen(mat:mat) } label: { VStack(alignment:.leading) { Text(mat["name"].str); Text("Схваток в опубликованном расписании: \(store.rows("schedulePublished").filter { $0["matId"].str == mat.id }.count)").font(.caption) } }
                    Button("Переименовать "+mat["name"].str) { self.mat = mat; editor = true }.font(.caption).disabled(!store.canEdit)
                }
                if store.rows("mats").filter({ $0["eventId"] == store.active["id"] }).count < 3 { Button("Добавить ковёр") { mat = nil; editor = true }.disabled(!store.canEdit || store.active == .null) }
            }
            if store.active != .null {
                NavigationLink("Время начала турнира") { StartTimeScreen(event:store.active) }
                NavigationLink("Порядок категорий") { QueueOrderScreen(group:nil,event:store.active) }
                Button("Рассчитать предпросмотр на устройстве") { preview = true }.disabled(!store.canEdit || store.active["status"].str != "Сетки сформированы")
                NavigationLink("Сохранённый черновик") { ScheduleScreen(draft:true) }
                NavigationLink("Опубликованное расписание") { ScheduleScreen(draft:false) }
                NavigationLink("Шаблоны и интервалы") { EventSettingsScreen(event:store.active) }
            }
        }.navigationTitle("Ковры и расписание")
        .sheet(isPresented:$editor) { NavigationStack { MatEditor(mat:mat,event:store.active) } }
        .sheet(isPresented:$preview) { NavigationStack { ScheduleLocalPreview(snapshot:store.snapshot) } }
    }
}

struct MatEditor: View {
    @EnvironmentObject private var store: AdminStore
    @Environment(\.dismiss) private var dismiss
    @State private var mat: J?; @State private var event: J
    @State private var name: String
    init(mat: J?,event: J) { _mat = State(initialValue:mat); _event = State(initialValue:event); _name = State(initialValue:mat?["name"].str ?? "") }
    var body: some View {
        Form {
            TextField("Название ковра",text:$name)
            Button("Сохранить") { var mats = store.rows("mats").filter { $0["eventId"] == event["id"] }; if let mat { mats = mats.map { $0.id == mat.id ? .object(["id":mat["id"],"name":.string(name)]) : $0 } } else { mats.append(.object(["name":.string(name)])) }; Task { if await store.perform("mats.save",["eventId":event["id"],"expectedVersion":event["version"],"mats":.array(mats)]) { dismiss() } } }.disabled(!store.canEdit || name.isEmpty)
            if let mat { Button("Удалить ковёр",role:.destructive) { let mats = store.rows("mats").filter { $0["eventId"] == event["id"] && $0.id != mat.id }; Task { if await store.perform("mats.save",["eventId":event["id"],"expectedVersion":event["version"],"mats":.array(mats)]) { dismiss() } } }.disabled(!store.canEdit) }
        }.navigationTitle("Ковёр")
    }
}

struct StartTimeScreen: View {
    @EnvironmentObject private var store: AdminStore
    @Environment(\.dismiss) private var dismiss
    @State private var event: J
    @State private var start: Date
    init(event: J) { _event = State(initialValue:event); _start = State(initialValue:ISO8601DateFormatter.withFraction.date(from:event["startAt"].str) ?? ISO8601DateFormatter().date(from:event["startAt"].str) ?? Date()) }
    var body: some View { Form { DatePicker("Начало, Москва",selection:$start); Button("Сохранить и пересчитать") { Task { if await store.perform("event.start",["eventId":event["id"],"expectedVersion":event["version"],"startAt":.string(ISO8601DateFormatter().string(from:start))]) { dismiss() } } }.disabled(!store.canEdit) }.navigationTitle("Начало турнира") }
}

struct MatScreen: View {
    @EnvironmentObject private var store: AdminStore
    let mat: J
    var body: some View {
        List {
            NavigationLink("Сдвинуть будущие схватки") { NumberSettingScreen(title:"Сдвиг ковра",action:"mat.shift",payload:["matId":mat["id"],"expectedVersion":store.active["version"]],field:"seconds",initial:0) }
            ForEach(store.rows("schedulePublished").filter { $0["matId"].str == mat.id }.sorted { $0["startAt"].str < $1["startAt"].str }) { slot in
                if let match = store.rows("matches").first(where:{ $0.id == slot["matchId"].str }) { NavigationLink { MatchScreen(match:match) } label: { BoutLabel(match:match) } }
            }
        }.navigationTitle(mat["name"].str)
    }
}

struct ScheduleScreen: View {
    @EnvironmentObject private var store: AdminStore
    let draft: Bool
    @State private var confirm = false
    @State private var confirmationEvent: J = .null
    var body: some View {
        List {
            Text("Обновлено: "+dateText(store.active[draft ? "scheduleDraftAt" : "schedulePublishedAt"]))
            ForEach(store.rows(draft ? "scheduleDraft" : "schedulePublished").filter { $0["eventId"] == store.active["id"] }.sorted { $0["startAt"].str < $1["startAt"].str }) { slot in
                VStack(alignment:.leading) { Text("\(store.mat(slot["matId"].str)) · № \(slot["number"].int)").font(.headline); Text(dateText(slot["startAt"])+" — "+dateText(slot["endAt"])); if let match = store.rows("matches").first(where:{ $0.id == slot["matchId"].str }) { Text(store.person(match["a"].str)+" — "+store.person(match["b"].str)).font(.caption) } }
            }
            if draft { Button("Опубликовать для участников и родителей") { confirmationEvent = store.active; confirm = true }.disabled(!store.canEdit || store.active["scheduleDraftAt"].str.isEmpty) }
        }.navigationTitle(draft ? "Черновик расписания" : "Расписание")
        .confirmationDialog("Опубликовать расписание?",isPresented:$confirm) { Button("Опубликовать") { let event = confirmationEvent; Task { await store.perform("schedule.publish",["eventId":event["id"],"expectedVersion":event["version"],"expectedDraftAt":event["scheduleDraftAt"]]) } } }
    }
}

struct ScheduleLocalPreview: View {
    @EnvironmentObject private var store: AdminStore
    @Environment(\.dismiss) private var dismiss
    @State private var source: J
    @State private var slots: [J] = []
    @State private var problem: String?
    init(snapshot: J) { _source = State(initialValue:snapshot) }
    var body: some View {
        List {
            if let problem { Text(problem).foregroundStyle(.red) }
            ForEach(slots) { slot in VStack(alignment:.leading) { Text("\(store.mat(slot["matId"].str)) · № \(slot["number"].int)"); Text(dateText(slot["startAt"])).font(.caption) } }
            if problem == nil && !slots.isEmpty {
                Text("Категории идут целиком. Время ориентировочное; паузы включают отдых спортсменов.").font(.caption)
                Button("Сохранить проверенный черновик в облаке") { let event = source["events"].list.first { $0["status"].str != "Архив" } ?? .null; Task { if await store.perform("schedule.preview",["eventId":event["id"],"expectedVersion":event["version"]]) { dismiss() } } }.disabled(!store.canEdit)
            }
        }.navigationTitle("Локальный расчёт").toolbar { Button("Закрыть") { dismiss() } }
        .task { let snapshot = source; do { slots = try await Task.detached { try SharedEngine.run("schedule",snapshot:snapshot).list }.value } catch { problem = error.localizedDescription } }
    }
}

struct QueueOrderScreen: View {
    @EnvironmentObject private var store: AdminStore
    let group: J?; @State var event: J
    @State private var ids: [String] = []
    var body: some View {
        List {
            Text("Переместите строки, затем сохраните. Порядок раундов, зависимости и проведённые схватки защищены проверками.").font(.caption)
            ForEach(ids,id:\.self) { id in
                if group == nil, let row = store.rows("groups").first(where:{ $0.id == id }) { Text(categoryTitle(row)) }
                else if let row = store.rows("matches").first(where:{ $0.id == id }) { BoutLabel(match:row) }
            }.onMove { from,to in ids.move(fromOffsets:from,toOffset:to) }
            Button("Сохранить порядок") { var payload: [String:J] = ["eventId":event["id"],"expectedVersion":event["version"],"ids":.array(ids.map(J.string))]; if let group { payload["groupId"] = group["id"] }; Task { await store.perform(group == nil ? "category.order" : "match.order",payload) } }.disabled(!store.canEdit)
        }.navigationTitle("Порядок").toolbar { EditButton().disabled(!store.canEdit) }
        .task {
            if let group {
                let cfg = store.rows("categoryConfigs").first { $0["eventId"] == event["id"] && $0["key"].str == categoryKey(group) }
                ids = cfg?["matchOrder"].list.map(\.str) ?? []
                if ids.isEmpty { ids = store.rows("matches").filter { $0["groupId"].str == group.id && $0["status"].str != "Проход без боя" }.sorted { $0["round"].int == $1["round"].int ? $0["number"].int < $1["number"].int : $0["round"].int < $1["round"].int }.map(\.id) }
            } else { ids = event["categoryOrder"].list.map(\.str); if ids.isEmpty { ids = store.rows("groups").filter { $0["eventId"] == event["id"] }.map(\.id) } }
        }
    }
}

struct TieOrderScreen: View {
    @EnvironmentObject private var store: AdminStore
    @Environment(\.dismiss) private var dismiss
    let group: J; let tie: J; @State private var event: J
    @State private var ids: [String]
    init(group: J,tie: J,event: J) { self.group = group; self.tie = tie; _event = State(initialValue:event); _ids = State(initialValue:tie["ids"].list.map(\.str)) }
    var body: some View {
        List {
            Text("Установите порядок мест начиная с \(tie["start"].int)")
            ForEach(ids,id:\.self) { Text(store.person($0)) }.onMove { from,to in ids.move(fromOffsets:from,toOffset:to) }
            Button("Сохранить места") { Task { if await store.perform("tie.resolve",["eventId":event["id"],"expectedVersion":event["version"],"groupId":group["id"],"key":tie["key"],"ids":.array(ids.map(J.string))]) { dismiss() } } }.disabled(!store.canEdit)
        }.navigationTitle("Равенство мест").toolbar { EditButton() }.environment(\.editMode,.constant(.active))
    }
}
