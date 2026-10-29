import XCTest
@testable import AvagbeChampsAdmin

final class SharedEngineTests: XCTestCase {
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
