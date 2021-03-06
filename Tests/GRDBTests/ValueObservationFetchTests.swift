import XCTest
#if GRDBCIPHER
    import GRDBCipher
#elseif GRDBCUSTOMSQLITE
    import GRDBCustomSQLite
#else
    #if SWIFT_PACKAGE
        import CSQLite
    #else
        import SQLite3
    #endif
    import GRDB
#endif

class ValueObservationFetchTests: GRDBTestCase {
    func testRegionsAPI() {
        // single region
        _ = ValueObservation.tracking(DatabaseRegion(), fetch: { _ in })
        _ = ValueObservation.tracking(DatabaseRegion(), fetchDistinct: { _ in 0 })
        // variadic
        _ = ValueObservation.tracking(DatabaseRegion(), DatabaseRegion(), fetch: { _ in })
        _ = ValueObservation.tracking(DatabaseRegion(), DatabaseRegion(), fetchDistinct: { _ in 0 })
        // array
        _ = ValueObservation.tracking([DatabaseRegion()], fetch: { _ in })
    }
    
    func testFetch() throws {
        func test(_ dbWriter: DatabaseWriter) throws {
            try dbWriter.write { try $0.execute("CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            var counts: [Int] = []
            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.assertForOverFulfill = true
            notificationExpectation.expectedFulfillmentCount = 4
            
            var observation = ValueObservation.tracking(DatabaseRegion.fullDatabase, fetch: {
                try Int.fetchOne($0, "SELECT COUNT(*) FROM t")!
            })
            observation.extent = .databaseLifetime
            _ = try observation.start(in: dbWriter) { count in
                counts.append(count)
                notificationExpectation.fulfill()
            }
            
            try dbWriter.writeWithoutTransaction { db in
                try db.execute("INSERT INTO t DEFAULT VALUES")
                try db.execute("UPDATE t SET id = id")
                try db.execute("INSERT INTO t DEFAULT VALUES")
            }
            
            waitForExpectations(timeout: 1, handler: nil)
            XCTAssertEqual(counts, [0, 1, 1, 2])
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
    
    // Test for a deprecated API
    func testFetchDistinct() throws {
        func test(_ dbWriter: DatabaseWriter) throws {
            try dbWriter.write { try $0.execute("CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            var counts: [Int] = []
            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.assertForOverFulfill = true
            notificationExpectation.expectedFulfillmentCount = 3
            
            var observation = ValueObservation.tracking(DatabaseRegion.fullDatabase, fetchDistinct: {
                try Int.fetchOne($0, "SELECT COUNT(*) FROM t")!
            })
            observation.extent = .databaseLifetime
            _ = try observation.start(in: dbWriter) { count in
                counts.append(count)
                notificationExpectation.fulfill()
            }
            
            try dbWriter.writeWithoutTransaction { db in
                try db.execute("INSERT INTO t DEFAULT VALUES")
                try db.execute("UPDATE t SET id = id")
                try db.execute("INSERT INTO t DEFAULT VALUES")
            }
            
            waitForExpectations(timeout: 1, handler: nil)
            XCTAssertEqual(counts, [0, 1, 2])
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }

    func testDistinctUntilChanged() throws {
        func test(_ dbWriter: DatabaseWriter) throws {
            try dbWriter.write { try $0.execute("CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT)") }
            
            var counts: [Int] = []
            let notificationExpectation = expectation(description: "notification")
            notificationExpectation.assertForOverFulfill = true
            notificationExpectation.expectedFulfillmentCount = 3
            
            var observation = ValueObservation.tracking(DatabaseRegion.fullDatabase, fetch: {
                try Int.fetchOne($0, "SELECT COUNT(*) FROM t")!
            }).distinctUntilChanged()
            observation.extent = .databaseLifetime
            _ = try observation.start(in: dbWriter) { count in
                counts.append(count)
                notificationExpectation.fulfill()
            }
            
            try dbWriter.writeWithoutTransaction { db in
                try db.execute("INSERT INTO t DEFAULT VALUES")
                try db.execute("UPDATE t SET id = id")
                try db.execute("INSERT INTO t DEFAULT VALUES")
            }
            
            waitForExpectations(timeout: 1, handler: nil)
            XCTAssertEqual(counts, [0, 1, 2])
        }
        
        try test(makeDatabaseQueue())
        try test(makeDatabasePool())
    }
}
