import SwiftUI

struct BoutLabel: View {
    @EnvironmentObject private var store: AdminStore
    @Environment(\.dynamicTypeSize) private var typeSize
    let match: J
    private func name(_ side: String) -> String {
        if let person = store.rows("participants").first(where: { $0.id == match[side].str }) { return person["name"].str }
        if let source = store.rows("matches").first(where: { $0.id == match[side == "a" ? "sourceA" : "sourceB"].str }) { return "Победитель № \(source["publicNumber"].int)" }
        return "Проход без боя"
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            if typeSize.isAccessibilitySize || match["status"].str.count > 18 {
                VStack(alignment: .leading, spacing: 8) { number; MatchStatus(status: match["status"].str) }
            } else {
                HStack { number; Spacer(minLength: 8); MatchStatus(status: match["status"].str) }
            }
            competitor("a")
            competitor("b")
            if let slot = store.rows("schedulePublished").first(where: { $0["matchId"].str == match.id }) {
                Label(store.mat(slot["matId"].str)+" · ≈ "+dateText(slot["startAt"]), systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical,8)
    }
    private var number: some View {
        Text(match["publicNumber"] == .null ? "Проход без боя" : "Схватка № \(match["publicNumber"].int)")
            .font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
    }
    private func competitor(_ side: String) -> some View {
        let won = !match["winner"].str.isEmpty && match["winner"] == match[side]
        return HStack(alignment: .top, spacing: 10) {
            if !typeSize.isAccessibilitySize { Image(systemName: won ? "checkmark.circle.fill" : "person.circle")
                .foregroundStyle(won ? Color.green : Color.secondary).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name(side)).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                if let person = store.rows("participants").first(where: { $0.id == match[side].str }), !person["club"].str.isEmpty {
                    Text(person["club"].str).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if won { Text("Победитель").font(.caption.weight(.semibold)).foregroundStyle(.green) }
            }
        }
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
                                        NavigationLink { MatchScreen(match:match) } label: { BoutLabel(match:match).frame(width:260,alignment:.leading).padding().background(AdminTheme.canvas,in:RoundedRectangle(cornerRadius:18)) }.buttonStyle(.plain)
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
        }.adminList().navigationTitle(group["system"].str)
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
                if current["status"].str == "Готова" { Button { let m = current; Task { await store.perform("match.start",["matchId":m["id"],"expectedRev":m["rev"]]) } } label: { Label("Начать схватку", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 32) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!editable) }
                if !current["actualStart"].str.isEmpty || !current["winner"].str.isEmpty { Button("Скорректировать время") { times = true }.disabled(!editable) }
            }
            if ["Готова","Идёт","Завершена"].contains(current["status"].str) {
                Section {
                    ForEach([current["a"].str,current["b"].str].filter { !$0.isEmpty },id:\.self) { id in
                        Button { confirmationMatch = current; winner = id } label: {
                            HStack(alignment: .center, spacing: 14) {
                                Image(systemName: "trophy").font(.title2).foregroundStyle(AdminTheme.accent)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(store.rows("participants").first { $0.id == id }?["name"].str ?? store.person(id)).font(.headline)
                                    if let person = store.rows("participants").first(where: { $0.id == id }), !person["club"].str.isEmpty {
                                        Text(person["club"].str).font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Text("Выбрать победителем").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.frame(minHeight: 56).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!editable)
                    }
                    if !current["winner"].str.isEmpty { Button("Сбросить результат",role:.destructive) { confirmationMatch = current; clear = true }.disabled(!editable) }
                } header: { Text("Результат схватки") } footer: { Text("После выбора спортсмена потребуется подтверждение.") }
            }
        }.adminList().navigationTitle("Схватка № \(current["publicNumber"].int)")
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
        }.adminList().navigationTitle("Фактическое время")
    }
}

struct MatsScreen: View {
    @EnvironmentObject private var store: AdminStore
    @State private var editor = false
    @State private var mat: J?
    @State private var preview = false
    private var mats: [J] { store.rows("mats").filter { $0["eventId"] == store.active["id"] } }
    var body: some View {
        List {
            if store.active == .null {
                ContentUnavailableView("Нет активного турнира", systemImage: "flag.checkered", description: Text("Создайте соревнование на вкладке «Турнир»."))
            }
            Section("Ковры") {
                ForEach(mats) { mat in
                    NavigationLink { MatScreen(mat:mat) } label: { MatSummary(mat: mat) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button { self.mat = mat; editor = true } label: { Label("Изменить", systemImage: "pencil") }.tint(AdminTheme.accent).disabled(!store.canEdit)
                        }
                }
                if mats.isEmpty && store.active != .null { Text("Добавьте до трёх ковров и назначьте им категории.").foregroundStyle(.secondary) }
                if mats.count < 3 && store.active != .null { Button { mat = nil; editor = true } label: { Label("Добавить ковёр", systemImage: "plus.circle") }.disabled(!store.canEdit) }
            }
            if store.active != .null {
                Section("Подготовка") {
                NavigationLink("Время начала турнира") { StartTimeScreen(event:store.active) }
                NavigationLink("Порядок категорий") { QueueOrderScreen(group:nil,event:store.active) }
                NavigationLink("Шаблоны и интервалы") { EventSettingsScreen(event:store.active) }
                }
                Section("Расписание") {
                    Button { preview = true } label: { Label("Рассчитать расписание", systemImage: "calendar.badge.clock").frame(maxWidth: .infinity, minHeight: 32) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!store.canEdit || store.active["status"].str != "Сетки сформированы")
                    NavigationLink { ScheduleScreen(draft:true) } label: { ActionRow(title: "Черновик", detail: "Проверить перед публикацией", icon: "doc.text") }
                    NavigationLink { ScheduleScreen(draft:false) } label: { ActionRow(title: "Опубликовано", detail: "Расписание участников и родителей", icon: "globe") }
                }
            }
        }.adminList().navigationTitle("Ковры")
        .refreshable { await store.sync() }
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
        }.adminList().navigationTitle("Ковёр")
    }
}

struct StartTimeScreen: View {
    @EnvironmentObject private var store: AdminStore
    @Environment(\.dismiss) private var dismiss
    @State private var event: J
    @State private var start: Date
    init(event: J) { _event = State(initialValue:event); _start = State(initialValue:ISO8601DateFormatter.withFraction.date(from:event["startAt"].str) ?? ISO8601DateFormatter().date(from:event["startAt"].str) ?? Date()) }
    var body: some View { Form { DatePicker("Начало, Москва",selection:$start); Button("Сохранить и пересчитать") { Task { if await store.perform("event.start",["eventId":event["id"],"expectedVersion":event["version"],"startAt":.string(ISO8601DateFormatter().string(from:start))]) { dismiss() } } }.disabled(!store.canEdit) }.adminList().navigationTitle("Начало турнира") }
}

struct MatScreen: View {
    @EnvironmentObject private var store: AdminStore
    let mat: J
    @State private var filter = "Впереди"
    @State private var edit = false
    private var current: J { store.rows("mats").first { $0.id == mat.id } ?? mat }
    private var matches: [J] {
        store.rows("schedulePublished").filter { $0["matId"].str == mat.id }.sorted { $0["startAt"].str < $1["startAt"].str }
            .compactMap { slot in store.rows("matches").first { $0.id == slot["matchId"].str } }
            .filter { filter == "Все" || ["Готова", "Идёт", "Ожидает участников"].contains($0["status"].str) }
    }
    var body: some View {
        List {
            Section { MatSummary(mat: current) }
            Picker("Показать схватки", selection: $filter) { Text("Впереди").tag("Впереди"); Text("Все").tag("Все") }.pickerStyle(.segmented)
            Section("Управление") {
            NavigationLink("Сдвинуть будущие схватки") { NumberSettingScreen(title:"Сдвиг ковра",action:"mat.shift",payload:["matId":mat["id"],"expectedVersion":store.active["version"]],field:"seconds",initial:0) }
            Button("Изменить ковёр") { edit = true }.disabled(!store.canEdit)
            }
            Section("Очередь схваток") {
                if matches.isEmpty { Text("Нет схваток для показа. Проверьте опубликованное расписание или выберите «Все».").foregroundStyle(.secondary) }
                ForEach(matches) { match in NavigationLink { MatchScreen(match:match) } label: { BoutLabel(match:match) } }
            }
        }.adminList().navigationTitle(current["name"].str)
        .sheet(isPresented: $edit) { NavigationStack { MatEditor(mat: current, event: store.active) } }
    }
}

struct MatSummary: View {
    @EnvironmentObject private var store: AdminStore
    let mat: J
    private var queue: [J] {
        store.rows("schedulePublished").filter { $0["matId"].str == mat.id }.sorted { $0["startAt"].str < $1["startAt"].str }
            .compactMap { slot in store.rows("matches").first { $0.id == slot["matchId"].str } }
    }
    private var next: J? { queue.first { $0["status"].str == "Идёт" } ?? queue.first { ["Готова", "Ожидает участников"].contains($0["status"].str) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(mat["name"].str, systemImage: "square.stack.3d.up").font(.title3.bold()).foregroundStyle(.primary)
            if let next {
                StatusBadge(title: next["status"].str == "Идёт" ? "Идёт · № \(next["publicNumber"].int)" : "Далее · № \(next["publicNumber"].int)", color: next["status"].str == "Идёт" ? .orange : AdminTheme.accent, icon: "play.circle")
                Text(store.person(next["a"].str)+" — "+store.person(next["b"].str)).font(.subheadline).foregroundStyle(.primary)
            } else { Text(queue.isEmpty ? "Расписание ещё не опубликовано" : "Очередь завершена").font(.subheadline).foregroundStyle(.secondary) }
            if !queue.isEmpty {
                let done = queue.filter { !$0["winner"].str.isEmpty }.count
                ProgressView(value: Double(done), total: Double(queue.count)).tint(AdminTheme.accent)
                Text("Проведено \(done) из \(queue.count) схваток").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 8)
    }
}

struct ScheduleScreen: View {
    @EnvironmentObject private var store: AdminStore
    let draft: Bool
    @State private var confirm = false
    @State private var confirmationEvent: J = .null
    @State private var selectedMat = ""
    private var slots: [J] { store.rows(draft ? "scheduleDraft" : "schedulePublished").filter { $0["eventId"] == store.active["id"] && (selectedMat.isEmpty || $0["matId"].str == selectedMat) }.sorted { $0["startAt"].str < $1["startAt"].str } }
    var body: some View {
        List {
            Section {
                StatusBadge(title: draft ? "Черновик · виден администраторам" : "Доступно участникам и родителям", color: draft ? .secondary : .green, icon: draft ? "doc.text" : "globe")
                Text("Обновлено: "+dateText(store.active[draft ? "scheduleDraftAt" : "schedulePublishedAt"])).font(.caption).foregroundStyle(.secondary)
                Picker("Ковёр", selection: $selectedMat) {
                    Text("Все ковры").tag("")
                    ForEach(store.rows("mats").filter { $0["eventId"] == store.active["id"] }) { Text($0["name"].str).tag($0.id) }
                }
            }
            if slots.isEmpty { ContentUnavailableView("Расписание пусто", systemImage: "calendar", description: Text("Назначьте категориям ковры, рассчитайте черновик и опубликуйте его.")) }
            ForEach(slots) { slot in
                VStack(alignment:.leading, spacing: 10) {
                    Label(dateText(slot["startAt"]), systemImage: "clock").font(.headline).monospacedDigit()
                    Text("\(store.mat(slot["matId"].str)) · № \(slot["number"].int) · ориентировочное время").font(.caption).foregroundStyle(.secondary)
                    if let match = store.rows("matches").first(where:{ $0.id == slot["matchId"].str }) {
                        NavigationLink { MatchScreen(match: match) } label: { Text(store.person(match["a"].str)+" — "+store.person(match["b"].str)).font(.subheadline).foregroundStyle(.primary) }
                    }
                }.padding(.vertical, 6)
            }
            if draft { Button("Опубликовать для участников и родителей") { confirmationEvent = store.active; confirm = true }.disabled(!store.canEdit || store.active["scheduleDraftAt"].str.isEmpty) }
        }.adminList().navigationTitle(draft ? "Черновик расписания" : "Расписание")
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
        }.adminList().navigationTitle("Локальный расчёт").toolbar { Button("Закрыть") { dismiss() } }
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
        }.adminList().navigationTitle("Порядок").toolbar { EditButton().disabled(!store.canEdit) }
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
        }.adminList().navigationTitle("Равенство мест").toolbar { EditButton() }.environment(\.editMode,.constant(.active))
    }
}
