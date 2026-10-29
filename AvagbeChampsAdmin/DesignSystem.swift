import SwiftUI

/// Semantic surfaces keep the console readable in light, dark and increased contrast modes.
enum AdminTheme {
    static let accent = Color.indigo
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
}

extension View {
    func adminList() -> some View {
        self.listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .background(AdminTheme.canvas).navigationBarTitleDisplayMode(.inline)
    }
    func adminCard() -> some View {
        self.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(AdminTheme.surface, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct StatusBadge: View {
    let title: String
    var color: Color = .secondary
    var icon = "circle.fill"
    var body: some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 6)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .combine)
    }
}

struct MatchStatus: View {
    let status: String
    var body: some View {
        StatusBadge(title: status, color: color, icon: icon)
    }
    private var color: Color {
        switch status {
        case "Идёт": return .orange
        case "Завершена", "Завершено", "Зарегистрирован": return .green
        case "Готова", "Регистрация", "Сетки сформированы": return AdminTheme.accent
        default: return .secondary
        }
    }
    private var icon: String {
        switch status {
        case "Идёт": return "play.circle.fill"
        case "Завершена", "Завершено", "Зарегистрирован": return "checkmark.circle.fill"
        case "Готова": return "clock"
        default: return "circle.dotted"
        }
    }
}

struct ActionRow: View {
    let title: String
    let detail: String
    let icon: String
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(AdminTheme.accent)
                .frame(width: 44, height: 44)
                .background(AdminTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 5).accessibilityElement(children: .combine)
    }
}

struct MetricTile: View {
    let value: String
    let title: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).foregroundStyle(AdminTheme.accent).font(.title3).frame(height: 28)
            Text(value).font(.largeTitle.bold()).monospacedDigit()
            Text(title).font(.subheadline).foregroundStyle(.secondary)
        }.adminCard().accessibilityElement(children: .combine)
    }
}

struct AthleteRow: View {
    let person: J
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(person["name"].str.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined())
                .font(.subheadline.bold()).foregroundStyle(AdminTheme.accent)
                .frame(width: 44, height: 44)
                .background(AdminTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(person["name"].str).font(.headline).foregroundStyle(.primary)
                Text(person["club"].str.isEmpty ? "Без клуба" : person["club"].str)
                    .font(.subheadline).foregroundStyle(.secondary)
                Text([person["age"].str, person["weight"].str, person["belt"].str]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 7).accessibilityElement(children: .combine)
    }
}

struct ConnectionBanner: View {
    @EnvironmentObject private var store: AdminStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { connection; Spacer(); timestamp }
                VStack(alignment: .leading, spacing: 4) { connection; timestamp }
            }
            if !store.compatible && store.lastSync != nil {
                Label("Для работы требуется обновление приложения", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            if store.pending != nil {
                Button { Task { await store.retryPending() } } label: {
                    Label("Проверяем сохранение · повторить", systemImage: "arrow.clockwise")
                        .frame(minHeight: 44)
                }.disabled(!store.online || store.busy)
            }
        }.font(.caption).padding(.horizontal, 20).padding(.vertical, 8)
            .background(.bar)
    }
    private var connection: some View {
        Label(store.online ? (store.lastSync == nil ? "Загружаем данные" : "На связи") : "Без сети · только просмотр",
              systemImage: store.online ? "checkmark.icloud" : "wifi.slash")
            .foregroundStyle(store.online ? Color.secondary : Color.orange)
    }
    @ViewBuilder private var timestamp: some View {
        if let date = store.lastSync {
            Text("Данные: \(date.formatted(date: .abbreviated, time: .shortened))")
                .foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
