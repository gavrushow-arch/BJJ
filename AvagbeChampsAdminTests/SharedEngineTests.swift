import XCTest
import SwiftUI
import UIKit
@testable import AvagbeChampsAdmin

final class SharedEngineTests: XCTestCase {
    func testSavedEndpointFallsBackAndPreservesValidCustomAddress() {
        for saved in [nil, "", "   ", "https://script.google.com/macros/s/…/exec", "not a URL", APIClient.defaultEndpoint+"?key=old"] as [String?] {
            XCTAssertEqual(APIClient.configuredEndpoint(saved),APIClient.defaultEndpoint)
        }
        let custom = "https://script.google.com/macros/s/AKfycb1234567890customDeployment/exec"
        XCTAssertEqual(APIClient.configuredEndpoint(" \n"+custom+"\n "),custom)
    }
    func testDefaultEndpointAndValidation() throws {
        XCTAssertEqual(try APIClient.validatedURL(APIClient.defaultEndpoint).host,"script.google.com")
        XCTAssertTrue(APIClient.defaultEndpoint.hasSuffix("/exec"))
        XCTAssertThrowsError(try APIClient.validatedURL(APIClient.defaultEndpoint+"?key=secret"))
        XCTAssertThrowsError(try APIClient.validatedURL("http://script.google.com/macros/s/test/exec"))
        XCTAssertThrowsError(try APIClient.validatedURL("https://example.com/macros/s/test/exec"))
    }
    func testJSONRoundTripAndCanonicalCategoryKey() throws {
        let value: J = .object(["belt":.string("Серый/Белый"),"age":.string("7–9"),"weight":.string("До 24 кг")])
        XCTAssertEqual(try JSONDecoder().decode(J.self,from:value.data()),value)
        XCTAssertEqual(categoryKey(value),"[\"7–9\",\"До 24 кг\",\"Серый/Белый\"]")
    }
    func testSharedEngineCategoriesAndSeededDraw() throws {
        let e: J = .object(["id":.string("e1"),"title":.string("Тест"),"status":.string("Регистрация"),"version":.n(1),"system":.string("Олимпийская"),"belts":.bool(true),"mergeWeights":.object([:]),"mergeBelts":.array([]),"ties":.object([:])])
        let people: [J] = (0..<5).map { .object(["id":.string("p\($0)"),"eventId":.string("e1"),"name":.string("Спортсмен \($0)"),"age":.string("Взрослые (18+)"),"weight":.string("До 58 кг"),"belt":.string("Белый"),"status":.string("Зарегистрирован")]) }
        let snapshot: J = .object(["schema":.n(2),"next":.n(20),"events":.array([e]),"participants":.array(people)])
        let categories = try SharedEngine.run("categories",snapshot:snapshot)
        XCTAssertEqual(categories.list.count,1); XCTAssertEqual(categories.list[0]["fightCount"].int,4)
        let payload: J = .object(["eventId":.string("e1"),"expectedVersion":.n(1),"seed":.string("shared-seed")])
        let a = try SharedEngine.run("draw",snapshot:snapshot,payload:payload)
        let b = try SharedEngine.run("draw",snapshot:snapshot,payload:payload)
        XCTAssertEqual(a["matches"],b["matches"])
        XCTAssertEqual(a["engineVersion"].str,SharedEngine.version)
    }
}

// Native screenshots use synthetic athletes only. They are attached to the XCTest
// result for visual review at phone/tablet sizes, in dark mode and with large text.
extension SharedEngineTests {
    @MainActor func testInterfaceReviewGallery() async throws {
        let store = AdminStore()
        store.session = AdminSession(deviceId: "ui-fixture", userId: "ui-fixture", accessToken: "", refreshToken: "", expiresAt: 0)
        store.online = true
        store.lastSync = ISO8601DateFormatter().date(from: "2026-10-29T08:00:00Z")
        let data = #"""
        {"engineVersion":"2.0.0","schema":2,"revision":1,"next":100,
         "events":[{"id":"e1","title":"Клубный турнир Avagbe Champs","status":"Сетки сформированы","version":1,"startAt":"2026-10-29T08:00:00Z","system":"Круговая","belts":true}],
         "participants":[
          {"id":"p1","eventId":"e1","name":"Александр Сергеев","club":"Avagbe Team","age":"Взрослые (18+)","weight":"До 76 кг","belt":"Синий","status":"Зарегистрирован"},
          {"id":"p2","eventId":"e1","name":"Михаил Волков","club":"Север","age":"Взрослые (18+)","weight":"До 76 кг","belt":"Синий","status":"Зарегистрирован"},
          {"id":"p3","eventId":"e1","name":"Артём Александров-Воскресенский","club":"Школа бразильского джиу-джитсу","age":"Взрослые (18+)","weight":"До 76 кг","belt":"Синий","status":"Зарегистрирован"}],
         "groups":[{"id":"g1","eventId":"e1","age":"Взрослые (18+)","weight":"До 76 кг","belt":"Синий","system":"Круговая","participantIds":["p1","p2","p3"]}],
         "mats":[{"id":"t1","eventId":"e1","name":"Ковёр № 1"},{"id":"t2","eventId":"e1","name":"Ковёр № 2"}],
         "matches":[
          {"id":"m1","eventId":"e1","groupId":"g1","publicNumber":1,"number":1,"round":1,"a":"p1","b":"p2","winner":"p1","status":"Завершена","rev":1},
          {"id":"m2","eventId":"e1","groupId":"g1","publicNumber":2,"number":2,"round":2,"a":"p1","b":"p3","status":"Идёт","rev":1,"actualStart":"2026-10-29T08:10:00Z"},
          {"id":"m3","eventId":"e1","groupId":"g1","publicNumber":3,"number":3,"round":3,"a":"p2","b":"p3","status":"Готова","rev":1}],
         "schedulePublished":[
          {"id":"s1","eventId":"e1","matchId":"m1","matId":"t1","number":1,"startAt":"2026-10-29T08:00:00Z","endAt":"2026-10-29T08:05:00Z"},
          {"id":"s2","eventId":"e1","matchId":"m2","matId":"t1","number":2,"startAt":"2026-10-29T08:10:00Z","endAt":"2026-10-29T08:15:00Z"},
          {"id":"s3","eventId":"e1","matchId":"m3","matId":"t1","number":3,"startAt":"2026-10-29T08:20:00Z","endAt":"2026-10-29T08:25:00Z"}]}
        """#
        store.snapshot = try JSONDecoder().decode(J.self, from: Data(data.utf8))
        let screens: [(String, AnyView)] = [
            ("overview", AnyView(TournamentScreen())),
            ("participants", AnyView(ParticipantsScreen())),
            ("categories", AnyView(CategoriesScreen())),
            ("mats", AnyView(MatsScreen())),
            ("bout", AnyView(MatchScreen(match: store.rows("matches")[1]))),
            ("login", AnyView(LoginScreen()))
        ]
        for (name, screen) in screens {
            for mode in ["light", "dark", "large"] {
                try await capture(screen, store: store, name: name+"-"+mode, size: CGSize(width: 393, height: 852), dark: mode == "dark", large: mode == "large")
            }
        }
        try await capture(AnyView(TournamentScreen()), store: store, name: "overview-ipad", size: CGSize(width: 1024, height: 1366))
        try await capture(AnyView(MatchScreen(match: store.rows("matches")[1])), store: store, name: "bout-small-phone", size: CGSize(width: 320, height: 568))
    }

    @MainActor private func capture(_ screen: AnyView, store: AdminStore, name: String, size: CGSize, dark: Bool = false, large: Bool = false) async throws {
        let view = NavigationStack { screen }
            .environmentObject(store).tint(AdminTheme.accent)
            .environment(\.locale, Locale(identifier: "ru_RU"))
            .environment(\.timeZone, TimeZone(identifier: "Europe/Moscow")!)
            .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
            .environment(\.colorScheme, dark ? .dark : .light)
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
