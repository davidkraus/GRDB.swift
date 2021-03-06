import XCTest
#if GRDBCIPHER
    @testable import GRDBCipher
#elseif GRDBCUSTOMSQLITE
    @testable import GRDBCustomSQLite
#else
    #if SWIFT_PACKAGE
        import CSQLite
    #else
        import SQLite3
    #endif
    @testable import GRDB
#endif

private struct Name: DatabaseValueConvertible {
    var rawValue: String
    
    var databaseValue: DatabaseValue {
        return rawValue.databaseValue
    }
    
    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Name? {
        guard let rawValue = String.fromDatabaseValue(dbValue) else {
            return nil
        }
        return Name(rawValue: rawValue)
    }
}

class ValueObservationDatabaseValueConvertibleTests: GRDBTestCase {
    func testAll() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { try $0.execute("CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)") }
        
        var results: [[Name]] = []
        let notificationExpectation = expectation(description: "notification")
        notificationExpectation.assertForOverFulfill = true
        notificationExpectation.expectedFulfillmentCount = 4
        
        var observation = ValueObservation.trackingAll(SQLRequest<Name>("SELECT name FROM t ORDER BY id"))
        observation.extent = .databaseLifetime
        _ = try observation.start(in: dbQueue) { names in
            results.append(names)
            notificationExpectation.fulfill()
        }
        
        try dbQueue.inDatabase { db in
            try db.execute("INSERT INTO t (id, name) VALUES (1, 'foo')") // +1
            try db.execute("UPDATE t SET name = 'foo' WHERE id = 1")     // =
            try db.inTransaction {                                       // +1
                try db.execute("INSERT INTO t (id, name) VALUES (2, 'bar')")
                try db.execute("INSERT INTO t (id, name) VALUES (3, 'baz')")
                try db.execute("DELETE FROM t WHERE id = 3")
                return .commit
            }
            try db.execute("DELETE FROM t WHERE id = 1")                 // -1
        }
        
        waitForExpectations(timeout: 1, handler: nil)
        XCTAssertEqual(results.map { $0.map { $0.rawValue }}, [
            [],
            ["foo"],
            ["foo", "bar"],
            ["bar"]])
    }
    
    func testOne() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { try $0.execute("CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)") }
        
        var results: [Name?] = []
        let notificationExpectation = expectation(description: "notification")
        notificationExpectation.assertForOverFulfill = true
        notificationExpectation.expectedFulfillmentCount = 7
        
        var observation = ValueObservation.trackingOne(SQLRequest<Name>("SELECT name FROM t ORDER BY id DESC"))
        observation.extent = .databaseLifetime
        _ = try observation.start(in: dbQueue) { name in
            results.append(name)
            notificationExpectation.fulfill()
        }
        
        try dbQueue.inDatabase { db in
            try db.execute("INSERT INTO t (id, name) VALUES (1, 'foo')")
            try db.execute("UPDATE t SET name = 'foo' WHERE id = 1")
            try db.inTransaction {
                try db.execute("INSERT INTO t (id, name) VALUES (2, 'bar')")
                try db.execute("INSERT INTO t (id, name) VALUES (3, 'baz')")
                try db.execute("DELETE FROM t WHERE id = 3")
                return .commit
            }
            try db.execute("DELETE FROM t")
            try db.execute("INSERT INTO t (id, name) VALUES (1, 'baz')")
            try db.execute("UPDATE t SET name = NULL")
            try db.execute("DELETE FROM t")
            try db.execute("INSERT INTO t (id, name) VALUES (1, NULL)")
            try db.execute("UPDATE t SET name = 'qux'")
        }

        waitForExpectations(timeout: 1, handler: nil)
        XCTAssertEqual(results.map { $0.map { $0.rawValue }}, [
            nil,
            "foo",
            "bar",
            nil,
            "baz",
            nil,
            "qux"])
    }
    
    func testAllOptional() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write { try $0.execute("CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)") }
        
        var results: [[Name?]] = []
        let notificationExpectation = expectation(description: "notification")
        notificationExpectation.assertForOverFulfill = true
        notificationExpectation.expectedFulfillmentCount = 4
        
        var observation = ValueObservation.trackingAll(SQLRequest<Name?>("SELECT name FROM t ORDER BY id"))
        observation.extent = .databaseLifetime
        _ = try observation.start(in: dbQueue) { names in
            results.append(names)
            notificationExpectation.fulfill()
        }
        
        try dbQueue.inDatabase { db in
            try db.execute("INSERT INTO t (id, name) VALUES (1, 'foo')") // +1
            try db.execute("UPDATE t SET name = 'foo' WHERE id = 1")     // =
            try db.inTransaction {                                       // +1
                try db.execute("INSERT INTO t (id, name) VALUES (2, NULL)")
                try db.execute("INSERT INTO t (id, name) VALUES (3, 'baz')")
                try db.execute("DELETE FROM t WHERE id = 3")
                return .commit
            }
            try db.execute("DELETE FROM t WHERE id = 1")                 // -1
        }
        
        waitForExpectations(timeout: 1, handler: nil)
        XCTAssertEqual(results.map { $0.map { $0?.rawValue }}, [
            [],
            ["foo"],
            ["foo", nil],
            [nil]])
    }
    
    func testViewOptimization() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.write {
            try $0.execute("""
                CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT);
                CREATE VIEW v AS SELECT * FROM t
                """)
        }
        
        var results: [[Name]] = []
        let notificationExpectation = expectation(description: "notification")
        notificationExpectation.assertForOverFulfill = true
        notificationExpectation.expectedFulfillmentCount = 4
        
        // Test that view v is included in the request region
        let request = SQLRequest<Name>("SELECT name FROM v ORDER BY id")
        try dbQueue.inDatabase { db in
            let region = try request.databaseRegion(db)
            XCTAssertEqual(region.description, "t(id,name),v(id,name)")
        }
        
        // Test that view v is not included in the observed region.
        // This optimization helps observation of views that feed from a
        // single table.
        var observation = ValueObservation.trackingAll(request)
        observation.extent = .databaseLifetime
        let transactionObserver = try observation.start(in: dbQueue) { names in
            results.append(names)
            notificationExpectation.fulfill()
        }
        let valueObserver = transactionObserver as! ValueObserver<DatabaseValuesReducer<SQLRequest<Name>>>
        XCTAssertEqual(valueObserver.region.description, "t(id,name)") // view is not tracked
        
        // Test view observation
        try dbQueue.inDatabase { db in
            try db.execute("INSERT INTO t (id, name) VALUES (1, 'foo')") // +1
            try db.execute("UPDATE t SET name = 'foo' WHERE id = 1")     // =
            try db.inTransaction {                                       // +1
                try db.execute("INSERT INTO t (id, name) VALUES (2, 'bar')")
                try db.execute("INSERT INTO t (id, name) VALUES (3, 'baz')")
                try db.execute("DELETE FROM t WHERE id = 3")
                return .commit
            }
            try db.execute("DELETE FROM t WHERE id = 1")                 // -1
        }
        
        waitForExpectations(timeout: 1, handler: nil)
        XCTAssertEqual(results.map { $0.map { $0.rawValue }}, [
            [],
            ["foo"],
            ["foo", "bar"],
            ["bar"]])
    }
}
